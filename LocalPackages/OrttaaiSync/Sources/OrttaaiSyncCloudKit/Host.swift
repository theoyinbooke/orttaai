// Host.swift
// OrttaaiSync
//
// Owns the CKSyncEngine for one iCloud account and carries events between it
// and the SyncCoordinator. It makes no decisions of its own: each event is
// translated, handed to the coordinator, and the commands that come back are
// applied to the engine.

import CloudKit
import Foundation
import OrttaaiSyncCore
import os

public actor CloudSyncEngineHost: CKSyncEngineDelegate {
    /// CloudKit takes up to 400 records or 2 MB per request; CKSyncEngine
    /// splits bigger batches, but small ones keep a failure cheap.
    static let maximumBatchRecords = 200
    static let maximumBatchBytes = 1_500_000

    private let container: CKContainer
    private let coordinator: SyncCoordinator
    private let logger = Logger(subsystem: "com.orttaai.sync", category: "engine")
    private var engine: CKSyncEngine?
    /// Zones whose fetch reported an error during the current fetch.
    private var fetchErrors: Set<String> = []
    /// One line per notable engine event, for the app's own diagnostics log
    /// (never any dictation text).
    private let diagnostics: (@Sendable (String) -> Void)?

    public init(container: CKContainer, coordinator: SyncCoordinator, diagnostics: (@Sendable (String) -> Void)? = nil) {
        self.container = container
        self.coordinator = coordinator
        self.diagnostics = diagnostics
    }

    /// The scope a store is kept under: container, environment and iCloud
    /// account. A different account gets its own store.
    public static func accountScope(container: CKContainer, environment: String) async throws -> String {
        let userRecordID = try await container.userRecordID()
        return "\(container.containerIdentifier ?? "default")|\(environment)|\(userRecordID.recordName)"
    }

    public var isRunning: Bool { engine != nil }

    /// Starts the engine from the saved state, unless sync is held for a
    /// reason only the person can resolve.
    public func start() async throws {
        guard engine == nil else { return }
        let commands = try await coordinator.start()
        let suspension = await coordinator.currentStatus.suspension
        switch suspension {
        case .accountChanged, .purged, .libraryDeleted:
            logger.notice("Sync not started: \(suspension.rawValue, privacy: .public)")
            return
        case .none, .quotaExceeded, .signedOut, .awaitingAccountCheck:
            break
        }

        var state: CKSyncEngine.State.Serialization?
        if let data = try await coordinator.savedEngineState() {
            state = try? JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: data)
            if state == nil { logger.error("Saved engine state was unreadable; starting fresh") }
        }
        var configuration = CKSyncEngine.Configuration(database: container.privateCloudDatabase, stateSerialization: state, delegate: self)
        configuration.automaticallySync = true
        let engine = CKSyncEngine(configuration)
        self.engine = engine
        apply(commands, to: engine)
        await retryQuarantine()
    }

    /// Records set aside because an older version couldn't read them get
    /// another try each launch; ones still unreadable go back.
    private func retryQuarantine() async {
        guard let entries = try? await coordinator.quarantinedForRetry(), !entries.isEmpty else { return }
        // Only entries that unarchive are retried; the rest stay as they are.
        let readable = entries.compactMap { entry in RecordCodec.unarchiveRecord(entry.archivedRecord).map { (entry.id, RecordCodec.decode($0)) } }
        guard !readable.isEmpty else { return }
        do {
            // Applied (or set aside again, as a new entry) first; the old
            // copies go only once that's saved.
            let commands = try await coordinator.replayQuarantined(readable.map(\.1))
            try await coordinator.removeQuarantined(readable.map(\.0))
            if let engine { apply(commands, to: engine) }
            diagnostics?("retried \(readable.count) quarantined records")
        } catch {
            logger.error("Retrying quarantined records failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Stops the engine. Events still in flight from it are ignored.
    public func stop() async {
        guard let engine else { return }
        self.engine = nil
        await engine.cancelOperations()
    }

    /// After committing local changes (rows plus outbox entries).
    public func noteLocalChanges(_ ids: [SyncRecordID]) async {
        guard let engine else { return }
        apply(await coordinator.noteLocalChanges(ids), to: engine)
    }

    /// A manual "Sync now".
    public func syncNow() async throws {
        guard let engine else { return }
        try await engine.fetchChanges()
        try await engine.sendChanges()
    }

    /// Runs one of the coordinator's person-chosen actions (restore, resume)
    /// and applies what it returns.
    public func perform(_ action: @Sendable (SyncCoordinator) async throws -> [EngineCommand]) async throws {
        let commands = try await action(coordinator)
        if engine == nil { try await start() }
        if let engine { apply(commands, to: engine) }
    }

    // MARK: CKSyncEngineDelegate

    public func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        // An engine that was stopped (account switched) may still deliver.
        guard syncEngine === engine else { return }

        switch event {
        case .willFetchChanges:
            fetchErrors = []
            return
        case .didFetchRecordZoneChanges(let finished):
            if let error = finished.error {
                fetchErrors.insert(finished.zoneID.zoneName)
                logger.error("Fetching \(finished.zoneID.zoneName, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
                diagnostics?("fetch \(finished.zoneID.zoneName) failed: CKError \(error.code.rawValue)")
            }
            return
        case .willFetchRecordZoneChanges, .willSendChanges, .didSendChanges:
            return
        default:
            break
        }

        guard let translated = translate(event) else { return }
        report(translated)
        let commands = await coordinator.handle(translated)
        guard syncEngine === engine else { return }
        apply(commands, to: syncEngine)

        if case .accountChange(.switchAccounts) = translated {
            await stop()
        }
    }

    public func nextRecordZoneChangeBatch(_ context: CKSyncEngine.SendChangesContext, syncEngine: CKSyncEngine) async -> CKSyncEngine.RecordZoneChangeBatch? {
        guard syncEngine === engine else { return nil }
        let pending = syncEngine.state.pendingRecordZoneChanges.filter { context.options.scope.contains($0) }

        var saves: [SyncRecordID] = []
        var strays: [CKSyncEngine.PendingRecordZoneChange] = []
        for change in pending {
            switch change {
            case .saveRecord(let recordID):
                if let id = RecordCodec.syncID(recordID) { saves.append(id) } else { strays.append(change) }
            case .deleteRecord:
                // v2 never deletes records; a deletion is a saved tombstone.
                strays.append(change)
            @unknown default:
                strays.append(change)
            }
        }
        if !strays.isEmpty { syncEngine.state.remove(pendingRecordZoneChanges: strays) }

        let batch = await coordinator.prepareBatch(pending: saves)
        if !batch.drop.isEmpty {
            syncEngine.state.remove(pendingRecordZoneChanges: batch.drop.map { .saveRecord(RecordCodec.recordID($0)) })
        }

        var records: [CKRecord] = []
        var bytes = 0
        for id in batch.send {
            guard let outgoing = await coordinator.outgoingRecord(for: id) else {
                // Not sendable now (held zone, failed check): the outbox keeps
                // it and it is queued again when that changes.
                syncEngine.state.remove(pendingRecordZoneChanges: [.saveRecord(RecordCodec.recordID(id))])
                continue
            }
            records.append(RecordCodec.record(for: outgoing))
            bytes += outgoing.envelope.payload?.count ?? 0
            if records.count >= Self.maximumBatchRecords || bytes >= Self.maximumBatchBytes { break }
        }
        guard !records.isEmpty else { return nil }
        return CKSyncEngine.RecordZoneChangeBatch(recordsToSave: records, recordIDsToDelete: [], atomicByZone: false)
    }

    public func nextFetchChangesOptions(_ context: CKSyncEngine.FetchChangesContext, syncEngine: CKSyncEngine) async -> CKSyncEngine.FetchChangesOptions {
        var options = context.options
        switch await coordinator.fetchScope {
        case .all:
            break
        case .zones(let zones):
            // A phone fetches the Library and its own dictations, never
            // another device's.
            options.scope = .zoneIDs(zones.map(RecordCodec.zoneID))
        }
        return options
    }

    private func report(_ event: SyncEvent) {
        guard let diagnostics else { return }
        switch event {
        case .accountChange(let change):
            diagnostics("account \(change)")
        case .fetchedDatabaseChanges(let modified, let deletions):
            if !modified.isEmpty || !deletions.isEmpty {
                diagnostics("zones changed: \(modified.count), deleted: \(deletions.map { "\($0.zone.zoneName) (\($0.reason.rawValue))" })")
            }
        case .fetchedRecordZoneChanges(let modifications, let deletions):
            diagnostics("fetched \(modifications.count) records, \(deletions.count) deletions")
        case .sentDatabaseChanges(let saved, let failed):
            diagnostics("zones saved: \(saved.map(\.zoneName))\(failed.isEmpty ? "" : ", failed: \(failed.map { "\($0.zone.zoneName) \($0.failure)" })")")
        case .sentRecordZoneChanges(let saved, let failed):
            var counts: [String: Int] = [:]
            for failure in failed { counts[Self.describe(failure.failure), default: 0] += 1 }
            diagnostics("sent \(saved.count) records\(failed.isEmpty ? "" : ", failed: \(counts)")")
        case .didFetchChanges:
            diagnostics("fetch finished")
        case .stateUpdate:
            break
        }
    }

    private static func describe(_ failure: SaveFailure) -> String {
        switch failure {
        case .serverRecordChanged: "serverRecordChanged"
        case .zoneNotFound: "zoneNotFound"
        case .unknownItem: "unknownItem"
        case .quotaExceeded: "quotaExceeded"
        case .transient: "transient"
        case .permanent(let reason): "permanent(\(reason))"
        }
    }

    // MARK: Commands

    private func apply(_ commands: [EngineCommand], to engine: CKSyncEngine) {
        for command in commands {
            switch command {
            case .addPendingSaves(let ids):
                engine.state.add(pendingRecordZoneChanges: ids.map { .saveRecord(RecordCodec.recordID($0)) })
            case .removePendingSaves(let ids):
                engine.state.remove(pendingRecordZoneChanges: ids.map { .saveRecord(RecordCodec.recordID($0)) })
            case .addPendingZoneSaves(let zones):
                engine.state.add(pendingDatabaseChanges: zones.map { .saveZone(CKRecordZone(zoneID: RecordCodec.zoneID($0))) })
            case .fetchNow:
                Task { try? await engine.fetchChanges() }
            }
        }
    }

    // MARK: Translation

    private func translate(_ event: CKSyncEngine.Event) -> SyncEvent? {
        switch event {
        case .stateUpdate(let update):
            guard let data = try? JSONEncoder().encode(update.stateSerialization) else {
                logger.error("Engine state could not be encoded")
                return nil
            }
            return .stateUpdate(data)

        case .accountChange(let change):
            switch change.changeType {
            case .signIn: return .accountChange(.signIn)
            case .signOut: return .accountChange(.signOut)
            case .switchAccounts: return .accountChange(.switchAccounts)
            @unknown default: return nil
            }

        case .fetchedDatabaseChanges(let changes):
            let modified = changes.modifications.compactMap { RecordCodec.zone($0.zoneID) }
            let deletions = changes.deletions.compactMap { deletion -> ZoneDeletion? in
                guard let zone = RecordCodec.zone(deletion.zoneID) else { return nil }
                let reason: ZoneDeletionReason
                switch deletion.reason {
                case .deleted: reason = .deleted
                case .purged: reason = .purged
                case .encryptedDataReset: reason = .encryptedDataReset
                @unknown default: reason = .deleted
                }
                return ZoneDeletion(zone: zone, reason: reason)
            }
            return .fetchedDatabaseChanges(modifiedZones: modified, deletions: deletions)

        case .fetchedRecordZoneChanges(let changes):
            let now = Date()
            let modifications = changes.modifications
                .filter { RecordCodec.zone($0.record.recordID.zoneID) != nil }
                .map { RecordCodec.decode($0.record, receivedAt: now) }
            let deletions = changes.deletions.compactMap { RecordCodec.syncID($0.recordID) }
            return .fetchedRecordZoneChanges(modifications: modifications, deletions: deletions)

        case .sentDatabaseChanges(let sent):
            let saved = sent.savedZones.compactMap { RecordCodec.zone($0.zoneID) }
            let failed = sent.failedZoneSaves.compactMap { failure -> FailedZoneSave? in
                guard let zone = RecordCodec.zone(failure.zone.zoneID) else { return nil }
                return FailedZoneSave(zone: zone, failure: Self.saveFailure(failure.error))
            }
            return .sentDatabaseChanges(savedZones: saved, failedZones: failed)

        case .sentRecordZoneChanges(let sent):
            let acks = sent.savedRecords.compactMap { record -> SendAck? in
                guard let id = RecordCodec.syncID(record.recordID), let revision = RecordCodec.revision(of: record) else { return nil }
                return SendAck(id: id, revision: revision, systemFields: RecordCodec.archiveSystemFields(record))
            }
            let failed = sent.failedRecordSaves.compactMap { failure -> FailedSave? in
                guard let id = RecordCodec.syncID(failure.record.recordID) else { return nil }
                return FailedSave(id: id, failure: Self.saveFailure(failure.error))
            }
            return .sentRecordZoneChanges(saved: acks, failed: failed)

        case .didFetchChanges:
            // Only a fetch where every zone succeeded counts as a catch-up.
            guard fetchErrors.isEmpty else { return nil }
            return .didFetchChanges

        default:
            return nil
        }
    }

    static func saveFailure(_ error: CKError) -> SaveFailure {
        switch error.code {
        case .serverRecordChanged:
            guard let serverRecord = error.serverRecord, case .record(let inbound) = RecordCodec.decode(serverRecord) else {
                return .serverRecordChanged(nil)
            }
            return .serverRecordChanged(inbound)
        case .zoneNotFound, .userDeletedZone:
            return .zoneNotFound
        case .unknownItem:
            return .unknownItem
        case .quotaExceeded:
            return .quotaExceeded
        case .networkFailure, .networkUnavailable, .zoneBusy, .serviceUnavailable, .requestRateLimited,
             .notAuthenticated, .operationCancelled, .accountTemporarilyUnavailable, .serverResponseLost:
            return .transient
        default:
            return .permanent("\(error.code.rawValue): \(error.localizedDescription)")
        }
    }
}
