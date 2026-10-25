// SyncStore.swift
// OrttaaiSync
//
// What each app's database provides to sync. Orttaai implements it over its
// GRDB database, Orttakey over its own; the tests use `InMemorySyncStore`.
// One store serves one iCloud account in one container and environment.
//
// Every local change commits its row and an outbox entry in one transaction
// (the app does this itself, numbering the change with its RevisionClock), so
// a crash can never leave a change that is saved but never sent.

import Foundation

/// A record ready to apply, with CloudKit's system fields for it.
public struct InboundRecord: Hashable, Sendable {
    public var envelope: SyncEnvelope
    /// `CKRecord.encodeSystemFields`, kept so the next save of this record
    /// carries the server's change tag.
    public var systemFields: Data?
    /// The whole record, fields included, so a record this version can't
    /// apply can be quarantined and tried again after an update.
    public var archivedRecord: Data?
    /// When iCloud last saved it (CloudKit's own clock).
    public var serverModifiedAt: Date?

    public init(envelope: SyncEnvelope, systemFields: Data?, archivedRecord: Data? = nil, serverModifiedAt: Date? = nil) {
        self.envelope = envelope
        self.systemFields = systemFields
        self.archivedRecord = archivedRecord
        self.serverModifiedAt = serverModifiedAt
    }
}

/// A record to send: the current local version.
public struct OutgoingRecord: Hashable, Sendable {
    public var envelope: SyncEnvelope
    public var systemFields: Data?

    public init(envelope: SyncEnvelope, systemFields: Data?) {
        self.envelope = envelope
        self.systemFields = systemFields
    }
}

/// A change waiting for the server to confirm it.
public struct OutboxEntry: Hashable, Sendable {
    public var id: SyncRecordID
    public var revision: Revision

    public init(id: SyncRecordID, revision: Revision) {
        self.id = id
        self.revision = revision
    }
}

/// The server saved this revision of this record.
public struct SendAck: Hashable, Sendable {
    public var id: SyncRecordID
    public var revision: Revision
    public var systemFields: Data?

    public init(id: SyncRecordID, revision: Revision, systemFields: Data?) {
        self.id = id
        self.revision = revision
        self.systemFields = systemFields
    }
}

/// A record that arrived but can't be applied by this version of the app.
public struct QuarantinedRecord: Hashable, Sendable {
    public var zoneName: String
    public var recordName: String
    public var recordType: String
    public var problem: EnvelopeProblem
    /// The record as CloudKit archived it, so it can be read again later.
    public var archivedRecord: Data?
    public var receivedAt: Date

    public init(zoneName: String, recordName: String, recordType: String, problem: EnvelopeProblem, archivedRecord: Data?, receivedAt: Date) {
        self.zoneName = zoneName
        self.recordName = recordName
        self.recordType = recordType
        self.problem = problem
        self.archivedRecord = archivedRecord
        self.receivedAt = receivedAt
    }
}

public struct InboundApplyResult: Equatable, Sendable {
    /// Records whose content changed locally (accepted remote versions).
    public var changed: [SyncRecordID]
    /// Records where the local version won and must be sent again.
    public var needsSend: [SyncRecordID]

    public init(changed: [SyncRecordID] = [], needsSend: [SyncRecordID] = []) {
        self.changed = changed
        self.needsSend = needsSend
    }
}

/// What this device knows about a zone on the server.
public enum ZoneState: String, Codable, Sendable {
    /// Never created or seen by this device. Only from here may the zone be
    /// created without asking.
    case notCreated
    /// Exists on the server.
    case created
    /// Deleted by another device; never recreated without the person.
    case deletedRemotely
    /// Removed with the rest of the app's iCloud data in Settings.
    case purged
    /// A save said it doesn't exist, with no deletion seen to explain it.
    case missing
}

/// Why sync is held, kept across launches.
public enum SyncSuspension: String, Codable, Sendable {
    case none
    /// Signed out of iCloud; resumes on sign-in.
    case signedOut
    /// Signed in again: held until the app confirms it's the same account,
    /// so nothing goes to someone else's iCloud unasked.
    case awaitingAccountCheck
    /// Another iCloud account signed in: the person chooses what happens.
    case accountChanged
    /// The app's data was deleted from iCloud in Settings.
    case purged
    /// Another device deleted the shared iCloud copy.
    case libraryDeleted
    /// iCloud storage is full; sending waits.
    case quotaExceeded
}

public protocol SyncStore: AnyObject, Sendable {
    // Sending
    func outboxEntries() throws -> [OutboxEntry]
    /// The current local version of a record, or nil if there's nothing to
    /// send for it any more.
    func outgoingRecord(for id: SyncRecordID) throws -> OutgoingRecord?
    /// Retires each outbox entry whose revision is the one acknowledged (a
    /// newer local revision stays pending) and stores the system fields.
    func acknowledge(_ acks: [SendAck]) throws
    /// A send that can't succeed without a change (too large, refused). Kept
    /// visible; the entry stays in the outbox.
    func markSendFailed(_ id: SyncRecordID, reason: String) throws

    // Receiving
    /// Applies a batch in one transaction, asking `decide` about each record
    /// against the row as it is inside that transaction, and raises the
    /// device's revision counter past every revision seen.
    func applyInbound(
        _ records: [InboundRecord],
        decide: (LocalRecordState?, SyncEnvelope) -> InboundDecision
    ) throws -> InboundApplyResult
    func quarantine(_ records: [QuarantinedRecord]) throws
    /// Quarantined records a newer app version might read, to try again.
    func quarantinedForRetry() throws -> [(id: Int64, archivedRecord: Data)]
    func removeQuarantined(_ ids: [Int64]) throws

    // System fields and zones
    func clearSystemFields(for ids: [SyncRecordID]) throws
    /// Forgets everything CloudKit told us about a zone (system fields), and
    /// keeps every local row and outbox entry.
    func clearCloudMetadata(in zone: SyncZone) throws
    /// Puts every record of a zone back in the outbox at its current revision,
    /// tombstones included, to rebuild the zone after a reset.
    func enqueueAllRecords(in zone: SyncZone) throws -> [SyncRecordID]
    func zoneStates() throws -> [SyncZone: ZoneState]
    func setZoneState(_ state: ZoneState, for zone: SyncZone) throws

    // Engine state
    func loadEngineState() throws -> Data?
    func saveEngineState(_ data: Data?) throws
    func loadSuspension() throws -> SyncSuspension
    func saveSuspension(_ suspension: SyncSuspension) throws
    func initialFetchCompleted() throws -> Bool
    func setInitialFetchCompleted() throws
}
