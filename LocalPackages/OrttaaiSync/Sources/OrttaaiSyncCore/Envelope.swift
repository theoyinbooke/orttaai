// Envelope.swift
// OrttaaiSync
//
// One record as both apps see it, before it becomes a CKRecord. Routing and
// ordering live in plain fields; everything the person said or wrote lives in
// `payload`, which goes to iCloud as an encrypted field.

import Foundation

/// Who made a dictation. Written once, when the dictation is created; a
/// device that edits it later never changes it.
public struct DictationOrigin: Codable, Hashable, Sendable {
    public var deviceID: String?
    public var kind: DeviceKind

    public init(deviceID: String?, kind: DeviceKind) {
        self.deviceID = deviceID
        self.kind = kind
    }
}

public struct SyncEnvelope: Hashable, Sendable {
    public static let currentSchemaVersion = 1
    /// CloudKit refuses records over 1 MB; staying well under leaves room for
    /// the plain fields and CloudKit's own.
    public static let maximumPayloadBytes = 900_000

    public var id: SyncRecordID
    public var schemaVersion: Int
    public var revision: Revision
    /// Revivable records (dictionary, snippets): which life of the record
    /// this is. Deleting keeps it; an explicit add after a delete raises it.
    /// An edit from a device that never saw the delete has the old
    /// generation, so it can't undo the delete. Always 0 for dictations.
    public var generation: Int64
    public var isDeleted: Bool
    public var deletedAt: Date?
    /// The JSON of the kind's payload type. Nil only for a deleted record.
    public var payload: Data?
    /// Dictations only.
    public var origin: DictationOrigin?
    /// Dictations only: when it was said, kept plain for diagnostics.
    public var createdAt: Date?

    public init(
        id: SyncRecordID,
        schemaVersion: Int = SyncEnvelope.currentSchemaVersion,
        revision: Revision,
        generation: Int64 = 0,
        isDeleted: Bool = false,
        deletedAt: Date? = nil,
        payload: Data?,
        origin: DictationOrigin? = nil,
        createdAt: Date? = nil
    ) {
        self.id = id
        self.schemaVersion = schemaVersion
        self.revision = revision
        self.generation = generation
        self.isDeleted = isDeleted
        self.deletedAt = deletedAt
        self.payload = payload
        self.origin = origin
        self.createdAt = createdAt
    }

    public var kind: RecordKind? { id.kind }

    /// Why this record can't be applied, or nil when it can.
    public var problem: EnvelopeProblem? {
        guard let kind, id.isWellFormed else { return .malformedID }
        guard schemaVersion >= 1 else { return .malformedID }
        guard schemaVersion <= Self.currentSchemaVersion else { return .unsupportedSchemaVersion(schemaVersion) }
        if isDeleted {
            if kind.deletionIsTerminal, payload != nil { return .deletedWithPayload }
        } else {
            guard let payload, !payload.isEmpty else { return .missingPayload }
            if payload.count > Self.maximumPayloadBytes { return .payloadTooLarge(payload.count) }
            // Checked here, so one unreadable record is set aside instead of
            // failing the whole batch it arrived in.
            if !Self.payloadDecodes(payload, as: kind) { return .undecodablePayload }
        }
        if kind == .dictation {
            guard let origin else { return .missingOrigin }
            // A dictation's zone is its origin device's.
            if SyncRecordID.dictationZone(originDeviceID: origin.deviceID) != id.zone { return .originZoneMismatch }
        }
        return nil
    }
}

extension SyncEnvelope {
    static func payloadDecodes(_ data: Data, as kind: RecordKind) -> Bool {
        func decodes<T: Decodable>(_ type: T.Type) -> Bool { (try? PayloadCoder.decode(type, from: data)) != nil }
        switch kind {
        case .dictation: return decodes(DictationPayload.self)
        case .dictionaryEntry: return decodes(DictionaryEntryPayload.self)
        case .snippet: return decodes(SnippetPayload.self)
        case .device: return decodes(DevicePayload.self)
        case .macSummary: return decodes(MacSummaryPayload.self)
        case .macPreferences: return decodes(MacPreferencesPayload.self)
        case .toneProfile, .chatConversation: return decodes(BlobPayload.self)
        case .learningSuggestion: return decodes(LearningSuggestionPayload.self)
        case .writingInsight: return decodes(WritingInsightPayload.self)
        }
    }
}

public enum EnvelopeProblem: Hashable, Sendable, CustomStringConvertible {
    case malformedID
    case unsupportedSchemaVersion(Int)
    case missingPayload
    case deletedWithPayload
    case payloadTooLarge(Int)
    case missingOrigin
    case originZoneMismatch
    case undecodablePayload
    case undecodableRecord

    public var description: String {
        switch self {
        case .malformedID: "malformed record name or zone"
        case .unsupportedSchemaVersion(let version): "schema version \(version) is newer than this app"
        case .missingPayload: "live record without a payload"
        case .deletedWithPayload: "deleted dictation still carrying text"
        case .payloadTooLarge(let bytes): "payload of \(bytes) bytes is over the limit"
        case .missingOrigin: "dictation without an origin"
        case .originZoneMismatch: "dictation in another device's zone"
        case .undecodablePayload: "payload could not be decoded"
        case .undecodableRecord: "record fields could not be read"
        }
    }

    /// Whether a newer app version might be able to read the record. Those
    /// stay in quarantine and are tried again after an update.
    public var mayResolveAfterUpdate: Bool {
        if case .unsupportedSchemaVersion = self { return true }
        return false
    }
}
