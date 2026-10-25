// InMemorySyncStore.swift
// OrttaaiSyncCoreTests
//
// The reference SyncStore: what Orttaai's and Orttakey's databases must do,
// written as plainly as possible. The simulator runs real coordinators on
// top of it.

import Foundation
@testable import OrttaaiSyncCore

final class InMemorySyncStore: SyncStore, @unchecked Sendable {
    struct Row: Equatable {
        var envelope: SyncEnvelope
        var systemFields: Data?
    }

    let deviceID: String
    let deviceKind: DeviceKind
    private let lock = NSRecursiveLock()

    private(set) var rows: [SyncRecordID: Row] = [:]
    private(set) var outbox: [SyncRecordID: Revision] = [:]
    private(set) var quarantined: [QuarantinedRecord] = []
    private(set) var failedSends: [SyncRecordID: String] = [:]
    private var zoneStateMap: [SyncZone: ZoneState] = [:]
    private var engineState: Data?
    private var suspension: SyncSuspension = .none
    private var initialFetch = false
    private(set) var clock: RevisionClock

    /// Makes the next `applyInbound` throw, as a full disk would.
    var failNextApply = false

    init(deviceID: String, kind: DeviceKind) {
        self.deviceID = deviceID
        self.deviceKind = kind
        self.clock = RevisionClock(counter: 0, deviceID: deviceID)
    }

    private func locked<T>(_ work: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try work()
    }

    // MARK: App changes (each one "transaction": row + outbox together)

    var ownZone: SyncZone { .dictations(originDeviceID: deviceID) }

    @discardableResult
    func createDictation(syncID: String = UUID().uuidString.lowercased(), text: String, at date: Date = Date()) -> SyncRecordID {
        locked {
            let id = SyncRecordID.dictation(syncID: syncID, zone: ownZone)
            let payload = DictationPayload(createdAt: date, text: text, rawText: text)
            let envelope = SyncEnvelope(
                id: id,
                revision: clock.next(at: date),
                payload: try! PayloadCoder.encode(payload),
                origin: DictationOrigin(deviceID: deviceID, kind: deviceKind),
                createdAt: date
            )
            rows[id] = Row(envelope: envelope, systemFields: nil)
            outbox[id] = envelope.revision
            return id
        }
    }

    /// Edits a word without re-adding it: same life of the record.
    func editWord(source: String, target: String) {
        locked {
            let id = SyncRecordID.dictionaryEntry(normalizedSource: SyncNormalization.normalizedKey(source))
            guard var row = rows[id], !row.envelope.isDeleted else { return }
            row.envelope.payload = try! PayloadCoder.encode(DictionaryEntryPayload(source: source, target: target, createdAt: Date()))
            row.envelope.revision = clock.next()
            rows[id] = row
            outbox[id] = row.envelope.revision
        }
    }

    /// Jumps this device's clock ahead, as a device that changed a lot offline.
    func advanceClock(by count: Int64) {
        locked { clock.observe(Revision(counter: clock.counter + count, modifiedAt: Date(), writerDeviceID: "x")) }
    }

    /// Imports a dictation this device holds from elsewhere (a v1 migration).
    func importDictation(_ envelope: SyncEnvelope) {
        locked {
            clock.observe(envelope.revision)
            rows[envelope.id] = Row(envelope: envelope, systemFields: nil)
            outbox[envelope.id] = envelope.revision
        }
    }

    func editDictation(_ id: SyncRecordID, text: String) {
        locked {
            guard var row = rows[id], !row.envelope.isDeleted, let data = row.envelope.payload,
                  var payload = try? PayloadCoder.decode(DictationPayload.self, from: data) else { return }
            payload.text = text
            row.envelope.payload = try! PayloadCoder.encode(payload)
            row.envelope.revision = clock.next()
            rows[id] = row
            outbox[id] = row.envelope.revision
        }
    }

    func deleteDictation(_ id: SyncRecordID) {
        locked {
            guard var row = rows[id], !row.envelope.isDeleted else { return }
            row.envelope.isDeleted = true
            row.envelope.deletedAt = Date()
            row.envelope.payload = nil
            row.envelope.revision = clock.next()
            rows[id] = row
            outbox[id] = row.envelope.revision
        }
    }

    @discardableResult
    func upsertWord(source: String, target: String) -> SyncRecordID {
        locked {
            let payload = DictionaryEntryPayload(source: source, target: target, createdAt: Date())
            let id = SyncRecordID.dictionaryEntry(normalizedSource: payload.normalizedSource)
            // Adding a deleted word again starts its next life.
            let existing = rows[id]?.envelope
            let generation = (existing?.generation ?? 0) + (existing?.isDeleted == true ? 1 : 0)
            let envelope = SyncEnvelope(id: id, revision: clock.next(), generation: generation, payload: try! PayloadCoder.encode(payload))
            rows[id] = Row(envelope: envelope, systemFields: rows[id]?.systemFields)
            outbox[id] = envelope.revision
            return id
        }
    }

    func deleteWord(source: String) {
        locked {
            let id = SyncRecordID.dictionaryEntry(normalizedSource: SyncNormalization.normalizedKey(source))
            guard var row = rows[id], !row.envelope.isDeleted else { return }
            row.envelope.isDeleted = true
            row.envelope.deletedAt = Date()
            row.envelope.payload = nil
            row.envelope.revision = clock.next()
            rows[id] = row
            outbox[id] = row.envelope.revision
        }
    }

    // MARK: Reading back

    func liveDictations() -> [SyncRecordID: String] {
        locked {
            var result: [SyncRecordID: String] = [:]
            for (id, row) in rows where id.kind == .dictation && !row.envelope.isDeleted {
                let payload = try! PayloadCoder.decode(DictationPayload.self, from: row.envelope.payload!)
                result[id] = payload.text
            }
            return result
        }
    }

    func deletedDictations() -> Set<SyncRecordID> {
        locked { Set(rows.filter { $0.key.kind == .dictation && $0.value.envelope.isDeleted }.keys) }
    }

    func dictionary() -> [SyncRecordID: String?] {
        locked {
            var result: [SyncRecordID: String?] = [:]
            for (id, row) in rows where id.kind == .dictionaryEntry {
                if row.envelope.isDeleted {
                    result[id] = .some(nil)
                } else {
                    let payload = try! PayloadCoder.decode(DictionaryEntryPayload.self, from: row.envelope.payload!)
                    result[id] = payload.target
                }
            }
            return result
        }
    }

    func row(_ id: SyncRecordID) -> Row? { locked { rows[id] } }
    func zoneState(_ zone: SyncZone) -> ZoneState { locked { zoneStateMap[zone] ?? .notCreated } }
    var currentSuspension: SyncSuspension { locked { suspension } }
    var savedEngineState: Data? { locked { engineState } }

    // MARK: SyncStore

    func outboxEntries() throws -> [OutboxEntry] {
        locked { outbox.map { OutboxEntry(id: $0.key, revision: $0.value) } }
    }

    func outgoingRecord(for id: SyncRecordID) throws -> OutgoingRecord? {
        locked {
            guard outbox[id] != nil, let row = rows[id] else { return nil }
            return OutgoingRecord(envelope: row.envelope, systemFields: row.systemFields)
        }
    }

    func acknowledge(_ acks: [SendAck]) throws {
        locked {
            for ack in acks {
                if rows[ack.id] != nil { rows[ack.id]?.systemFields = ack.systemFields }
                if outbox[ack.id] == ack.revision {
                    outbox[ack.id] = nil
                    failedSends[ack.id] = nil
                }
            }
        }
    }

    func markSendFailed(_ id: SyncRecordID, reason: String) throws {
        locked { failedSends[id] = reason }
    }

    func applyInbound(
        _ records: [InboundRecord],
        decide: (LocalRecordState?, SyncEnvelope) -> InboundDecision
    ) throws -> InboundApplyResult {
        try locked {
            if failNextApply {
                failNextApply = false
                throw NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "disk full"])
            }
            // Work on copies and commit at the end, as one transaction.
            var newRows = rows
            var newOutbox = outbox
            var newClock = clock
            var result = InboundApplyResult()
            for record in records {
                let id = record.envelope.id
                let local = newRows[id].map { LocalRecordState(revision: $0.envelope.revision, isDeleted: $0.envelope.isDeleted, generation: $0.envelope.generation) }
                newClock.observe(record.envelope.revision)
                switch decide(local, record.envelope) {
                case .acceptRemote:
                    newRows[id] = Row(envelope: record.envelope, systemFields: record.systemFields)
                    newOutbox[id] = nil
                    result.changed.append(id)
                case .keepLocal:
                    newRows[id]?.systemFields = record.systemFields
                    if let revision = newRows[id]?.envelope.revision { newOutbox[id] = revision }
                    result.needsSend.append(id)
                case .alreadyCurrent:
                    newRows[id]?.systemFields = record.systemFields
                    if newOutbox[id] == record.envelope.revision { newOutbox[id] = nil }
                }
            }
            rows = newRows
            outbox = newOutbox
            clock = newClock
            return result
        }
    }

    func quarantine(_ records: [QuarantinedRecord]) throws {
        locked { quarantined += records }
    }

    func quarantinedForRetry() throws -> [(id: Int64, archivedRecord: Data)] {
        locked {
            quarantined.enumerated().compactMap { index, record in
                guard record.problem.mayResolveAfterUpdate, let data = record.archivedRecord else { return nil }
                return (Int64(index), data)
            }
        }
    }

    func removeQuarantined(_ ids: [Int64]) throws {
        locked {
            let drop = Set(ids)
            quarantined = quarantined.enumerated().filter { !drop.contains(Int64($0.offset)) }.map(\.element)
        }
    }

    func clearSystemFields(for ids: [SyncRecordID]) throws {
        locked {
            for id in ids where rows[id] != nil { rows[id]?.systemFields = nil }
        }
    }

    func clearCloudMetadata(in zone: SyncZone) throws {
        locked {
            for id in rows.keys where id.zone == zone { rows[id]?.systemFields = nil }
        }
    }

    func enqueueAllRecords(in zone: SyncZone) throws -> [SyncRecordID] {
        locked {
            let ids = rows.keys.filter { $0.zone == zone }
            for id in ids { outbox[id] = rows[id]!.envelope.revision }
            return Array(ids)
        }
    }

    func zoneStates() throws -> [SyncZone: ZoneState] { locked { zoneStateMap } }
    func setZoneState(_ state: ZoneState, for zone: SyncZone) throws { locked { zoneStateMap[zone] = state } }
    func loadEngineState() throws -> Data? { locked { engineState } }
    func saveEngineState(_ data: Data?) throws { locked { engineState = data } }
    func loadSuspension() throws -> SyncSuspension { locked { suspension } }
    func saveSuspension(_ suspension: SyncSuspension) throws { locked { self.suspension = suspension } }
    func initialFetchCompleted() throws -> Bool { locked { initialFetch } }
    func setInitialFetchCompleted() throws { locked { initialFetch = true } }
}
