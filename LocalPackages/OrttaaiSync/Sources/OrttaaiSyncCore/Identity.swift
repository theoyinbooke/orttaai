// Identity.swift
// OrttaaiSync
//
// Where every record lives in iCloud: its zone, its type and its name. The
// names are part of the contract between the two apps, so they never change
// once shipped.

import Foundation

/// The kind of device a dictation was made on.
public enum DeviceKind: String, Codable, Sendable, CaseIterable {
    case mac
    case iphone
    case ipad
    /// A dictation from before sync v2 whose device was never recorded.
    case unknown
}

/// Which app is running the sync, and so which zones it reads.
public enum SyncPlatform: String, Codable, Sendable {
    /// Orttaai on the Mac: reads every zone.
    case mac
    /// Orttakey on iPhone or iPad: reads the Library and its own dictations.
    case mobile
}

/// A record zone in the private database.
public enum SyncZone: Hashable, Sendable, Codable, CustomStringConvertible {
    /// The dictionary, devices and the Macs' summaries. Every device reads it.
    case library
    /// Settings, chats, insights, suggestions and snippets. Macs only.
    case macOnly
    /// Dictations made on one device.
    case dictations(originDeviceID: String)
    /// Dictations from before sync v2 whose device was never recorded.
    case legacyDictations

    static let dictationsPrefix = "Dictations-"
    static let legacySuffix = "legacy"

    public var zoneName: String {
        switch self {
        case .library: "Library"
        case .macOnly: "MacOnly"
        case .dictations(let originDeviceID): Self.dictationsPrefix + originDeviceID
        case .legacyDictations: Self.dictationsPrefix + Self.legacySuffix
        }
    }

    public init?(zoneName: String) {
        switch zoneName {
        case "Library": self = .library
        case "MacOnly": self = .macOnly
        case Self.dictationsPrefix + Self.legacySuffix: self = .legacyDictations
        default:
            guard zoneName.hasPrefix(Self.dictationsPrefix) else { return nil }
            let deviceID = String(zoneName.dropFirst(Self.dictationsPrefix.count))
            guard DeviceID.isValid(deviceID) else { return nil }
            self = .dictations(originDeviceID: deviceID)
        }
    }

    public var isDictationZone: Bool {
        switch self {
        case .dictations, .legacyDictations: true
        case .library, .macOnly: false
        }
    }

    /// Whether this platform downloads the zone. A phone reads only the
    /// Library and its own dictations, never another device's details.
    public func isFetched(by platform: SyncPlatform, deviceID: String) -> Bool {
        switch (platform, self) {
        case (.mac, _): true
        case (.mobile, .library): true
        case (.mobile, .dictations(let origin)): origin == deviceID
        case (.mobile, .macOnly), (.mobile, .legacyDictations): false
        }
    }

    public var description: String { zoneName }
}

/// Device identifiers: lowercase UUIDs today; anything matching this shape is
/// accepted so a zone name can always be parsed back.
public enum DeviceID {
    public static func isValid(_ id: String) -> Bool {
        guard !id.isEmpty, id.count <= 64, id != SyncZone.legacySuffix else { return false }
        return id.unicodeScalars.allSatisfy { scalar in
            ("a"..."z").contains(scalar) || ("0"..."9").contains(scalar) || scalar == "-"
        }
    }

    /// A new identifier for this device.
    public static func make() -> String { UUID().uuidString.lowercased() }
}

/// The record types of sync v2. The v1 types ("OrttaaiTranscription" and so
/// on) stay in the schema for older Orttaai versions; v2 never writes them.
public enum RecordKind: String, Codable, Sendable, CaseIterable {
    case dictation = "Dictation"
    case dictionaryEntry = "DictionaryEntry"
    case snippet = "Snippet"
    case device = "Device"
    case macSummary = "MacSummary"
    case macPreferences = "MacPreferences"
    case toneProfile = "ToneProfile"
    case chatConversation = "ChatConversation"
    case learningSuggestion = "LearningSuggestion"
    case writingInsight = "WritingInsight"

    public var recordType: String { rawValue }

    var namePrefix: String {
        switch self {
        case .dictation: "dictation."
        case .dictionaryEntry: "dict."
        case .snippet: "snippet."
        case .device: "device."
        case .macSummary: "summary."
        case .macPreferences: "prefs."
        case .toneProfile: "tone."
        case .chatConversation: "chat."
        case .learningSuggestion: "suggestion."
        case .writingInsight: "insight."
        }
    }

    /// Whether a deletion is final (a deleted dictation is never revived;
    /// restoring one makes a new dictation) or a tombstone a later edit may
    /// lift (a dictionary word deleted and added again).
    public var deletionIsTerminal: Bool { self == .dictation }

    /// The zone records of this kind live in, apart from dictations, whose
    /// zone is their origin device's.
    var fixedZone: SyncZone? {
        switch self {
        case .dictation: nil
        case .dictionaryEntry, .device, .macSummary: .library
        case .snippet, .macPreferences, .toneProfile, .chatConversation, .learningSuggestion, .writingInsight: .macOnly
        }
    }

    public init?(recordName: String) {
        guard let kind = RecordKind.allCases.first(where: { recordName.hasPrefix($0.namePrefix) }) else { return nil }
        self = kind
    }
}

/// A record's address: its zone and name.
public struct SyncRecordID: Hashable, Sendable, Codable, CustomStringConvertible {
    public var zone: SyncZone
    public var recordName: String

    public init(zone: SyncZone, recordName: String) {
        self.zone = zone
        self.recordName = recordName
    }

    public var kind: RecordKind? { RecordKind(recordName: recordName) }

    public var description: String { "\(zone.zoneName)/\(recordName)" }

    // MARK: Builders

    public static func dictation(syncID: String, zone: SyncZone) -> SyncRecordID {
        SyncRecordID(zone: zone, recordName: RecordKind.dictation.namePrefix + syncID)
    }

    /// The zone for a dictation from this origin.
    public static func dictationZone(originDeviceID: String?) -> SyncZone {
        guard let originDeviceID, DeviceID.isValid(originDeviceID) else { return .legacyDictations }
        return .dictations(originDeviceID: originDeviceID)
    }

    /// Every device that adds the same word lands on the same record.
    public static func dictionaryEntry(normalizedSource: String) -> SyncRecordID {
        SyncRecordID(zone: .library, recordName: RecordKind.dictionaryEntry.namePrefix + SyncNormalization.digest(normalizedSource))
    }

    public static func snippet(normalizedTrigger: String) -> SyncRecordID {
        SyncRecordID(zone: .macOnly, recordName: RecordKind.snippet.namePrefix + SyncNormalization.digest(normalizedTrigger))
    }

    public static func device(_ deviceID: String) -> SyncRecordID {
        SyncRecordID(zone: .library, recordName: RecordKind.device.namePrefix + deviceID)
    }

    public static func macSummary(macDeviceID: String) -> SyncRecordID {
        SyncRecordID(zone: .library, recordName: RecordKind.macSummary.namePrefix + macDeviceID)
    }

    public static let macPreferences = SyncRecordID(zone: .macOnly, recordName: RecordKind.macPreferences.namePrefix + "mac")
    public static let toneProfile = SyncRecordID(zone: .macOnly, recordName: RecordKind.toneProfile.namePrefix + "mac")

    public static func chatConversation(_ conversationID: String) -> SyncRecordID {
        SyncRecordID(zone: .macOnly, recordName: RecordKind.chatConversation.namePrefix + conversationID)
    }

    public static func learningSuggestion(syncID: String) -> SyncRecordID {
        SyncRecordID(zone: .macOnly, recordName: RecordKind.learningSuggestion.namePrefix + syncID)
    }

    public static func writingInsight(syncID: String) -> SyncRecordID {
        SyncRecordID(zone: .macOnly, recordName: RecordKind.writingInsight.namePrefix + syncID)
    }

    /// The part of the name after the kind's prefix: a dictation's syncID, a
    /// device's ID and so on.
    public var localKey: String {
        guard let kind else { return recordName }
        return String(recordName.dropFirst(kind.namePrefix.count))
    }

    /// Whether this record is allowed in this zone: a dictation only in a
    /// dictation zone, everything else only in its own zone.
    public var isWellFormed: Bool {
        guard let kind, !localKey.isEmpty, recordName.utf8.count <= 255 else { return false }
        if let fixedZone = kind.fixedZone { return zone == fixedZone }
        return zone.isDictationZone
    }
}
