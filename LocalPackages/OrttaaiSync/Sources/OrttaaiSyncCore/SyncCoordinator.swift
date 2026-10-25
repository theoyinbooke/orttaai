// SyncCoordinator.swift
// OrttaaiSync
//
// Every sync decision, in one place and with no CloudKit in it. The CloudKit
// host turns CKSyncEngine's events into `SyncEvent`s, hands them here and
// carries out the `EngineCommand`s that come back; the tests drive the same
// coordinator against a simulated iCloud.

import Foundation
import os

// MARK: Events in

public enum SaveFailure: Hashable, Sendable {
    /// The server holds a newer version; here it is, if it could be read.
    case serverRecordChanged(InboundRecord?)
    case zoneNotFound
    case unknownItem
    case quotaExceeded
    /// Network, throttling, busy: CKSyncEngine tries again on its own.
    case transient
    /// Won't succeed as it is (too large, refused).
    case permanent(String)
}

public enum ZoneDeletionReason: String, Hashable, Sendable {
    case deleted
    case purged
    case encryptedDataReset
}

public enum AccountChange: Hashable, Sendable {
    case signIn
    case signOut
    case switchAccounts
}

public struct ZoneDeletion: Hashable, Sendable {
    public var zone: SyncZone
    public var reason: ZoneDeletionReason

    public init(zone: SyncZone, reason: ZoneDeletionReason) {
        self.zone = zone
        self.reason = reason
    }
}

public enum FetchedRecord: Hashable, Sendable {
    case record(InboundRecord)
    case unreadable(QuarantinedRecord)
}

public struct FailedSave: Hashable, Sendable {
    public var id: SyncRecordID
    public var failure: SaveFailure

    public init(id: SyncRecordID, failure: SaveFailure) {
        self.id = id
        self.failure = failure
    }
}

public struct FailedZoneSave: Hashable, Sendable {
    public var zone: SyncZone
    public var failure: SaveFailure

    public init(zone: SyncZone, failure: SaveFailure) {
        self.zone = zone
        self.failure = failure
    }
}

public enum SyncEvent: Sendable {
    case stateUpdate(Data)
    case accountChange(AccountChange)
    case fetchedDatabaseChanges(modifiedZones: [SyncZone], deletions: [ZoneDeletion])
    case fetchedRecordZoneChanges(modifications: [FetchedRecord], deletions: [SyncRecordID])
    case sentDatabaseChanges(savedZones: [SyncZone], failedZones: [FailedZoneSave])
    case sentRecordZoneChanges(saved: [SendAck], failed: [FailedSave])
    /// A fetch finished without error.
    case didFetchChanges
}

// MARK: Commands out

public enum EngineCommand: Hashable, Sendable {
    case addPendingSaves([SyncRecordID])
    case removePendingSaves([SyncRecordID])
    case addPendingZoneSaves([SyncZone])
    /// Fetch database changes now: a zone went missing and a deletion event
    /// may explain it.
    case fetchNow
}

public enum FetchScope: Hashable, Sendable {
    case all
    case zones(Set<SyncZone>)
}

/// What the app shows about sync.
public struct SyncStatus: Equatable, Sendable {
    public var suspension: SyncSuspension
    public var missingZones: [SyncZone]
    public var lastError: String?
    /// The last fetch that finished, or nil before the first one.
    public var lastFetchedAt: Date?
    public var lastSentAt: Date?

    public init(
        suspension: SyncSuspension = .none,
        missingZones: [SyncZone] = [],
        lastError: String? = nil,
        lastFetchedAt: Date? = nil,
        lastSentAt: Date? = nil
    ) {
        self.suspension = suspension
        self.missingZones = missingZones
        self.lastError = lastError
        self.lastFetchedAt = lastFetchedAt
        self.lastSentAt = lastSentAt
    }
}

/// What the coordinator tells the app besides commands: records that changed
/// (to refresh views and analytics) and status.
public protocol SyncCoordinatorObserver: AnyObject, Sendable {
    func syncDidApplyRemoteChanges(_ ids: [SyncRecordID])
    func syncStatusDidChange(_ status: SyncStatus)
    func syncDidFinishFetch()
}

public actor SyncCoordinator {
    public let platform: SyncPlatform
    public let deviceID: String
    private let store: SyncStore
    private weak var observer: SyncCoordinatorObserver?
    private let logger = Logger(subsystem: "com.orttaai.sync", category: "coordinator")

    private var status = SyncStatus()
    private var zoneStates: [SyncZone: ZoneState] = [:]
    private var initialFetchDone = false
    /// Set when applying fetched data failed: later checkpoints must not be
    /// saved, so the next launch fetches that data again.
    private var checkpointsBlocked = false

    public init(store: SyncStore, platform: SyncPlatform, deviceID: String, observer: SyncCoordinatorObserver?) {
        self.store = store
        self.platform = platform
        self.deviceID = deviceID
        self.observer = observer
    }

    /// The device's own dictation zone.
    public var ownDictationZone: SyncZone { .dictations(originDeviceID: deviceID) }

    /// Zones this device creates when it starts syncing.
    var homeZones: [SyncZone] {
        switch platform {
        case .mac: [.library, .macOnly, ownDictationZone]
        case .mobile: [.library, ownDictationZone]
        }
    }

    public var currentStatus: SyncStatus { status }

    /// Whether the engine should run at all.
    public var isActive: Bool {
        switch status.suspension {
        case .none, .quotaExceeded: true
        case .signedOut, .awaitingAccountCheck, .accountChanged, .purged, .libraryDeleted: false
        }
    }

    // MARK: Starting

    /// Loads what was saved and returns what to queue on the new engine.
    public func start() throws -> [EngineCommand] {
        status.suspension = try store.loadSuspension()
        zoneStates = try store.zoneStates()
        initialFetchDone = try store.initialFetchCompleted()
        refreshMissingZones()
        publishStatus()
        guard isActive else { return [] }
        return try queueEverythingPending()
    }

    /// The engine state saved by the last run, to start the engine from.
    public func savedEngineState() throws -> Data? {
        try store.loadEngineState()
    }

    private func queueEverythingPending() throws -> [EngineCommand] {
        var commands: [EngineCommand] = []
        let zonesToCreate = homeZones.filter { zoneState($0) == .notCreated }
        if !zonesToCreate.isEmpty { commands.append(.addPendingZoneSaves(zonesToCreate)) }
        // Nothing is sent before the first fetch has finished: a device that
        // starts from scratch must first learn what iCloud already holds.
        guard initialFetchDone else { return commands }
        let entries = try store.outboxEntries().map(\.id).filter(isSendable)
        let foreignZones = Set(entries.map(\.zone)).filter { zoneState($0) == .notCreated && !homeZones.contains($0) }
        if !foreignZones.isEmpty { commands.append(.addPendingZoneSaves(Array(foreignZones))) }
        if !entries.isEmpty { commands.append(.addPendingSaves(entries)) }
        return commands
    }

    // MARK: Local changes

    /// Call after committing local changes (rows plus outbox entries).
    public func noteLocalChanges(_ ids: [SyncRecordID]) -> [EngineCommand] {
        guard isActive, initialFetchDone else { return [] }
        let sendable = ids.filter(isSendable)
        guard !sendable.isEmpty else { return [] }
        var commands: [EngineCommand] = []
        let newZones = Set(sendable.map(\.zone)).filter { zoneState($0) == .notCreated }
        if !newZones.isEmpty { commands.append(.addPendingZoneSaves(Array(newZones))) }
        commands.append(.addPendingSaves(sendable))
        return commands
    }

    // MARK: Fetching

    public var fetchScope: FetchScope {
        switch platform {
        case .mac: .all
        case .mobile: .zones([.library, ownDictationZone])
        }
    }

    // MARK: Sending

    /// Splits the engine's pending saves into those to send now and those to
    /// drop (no outbox entry any more).
    public func prepareBatch(pending: [SyncRecordID]) -> (send: [SyncRecordID], drop: [SyncRecordID]) {
        guard isActive, status.suspension != .quotaExceeded else { return ([], []) }
        let outbox: Set<SyncRecordID>
        do {
            outbox = Set(try store.outboxEntries().map(\.id))
        } catch {
            note(error: "Reading the outbox failed: \(error.localizedDescription)")
            return ([], [])
        }
        var send: [SyncRecordID] = []
        var drop: [SyncRecordID] = []
        for id in pending {
            if !outbox.contains(id) || !id.isWellFormed || !id.zone.isFetched(by: platform, deviceID: deviceID) && platform == .mobile {
                drop.append(id)
            } else if isSendable(id) {
                send.append(id)
            }
        }
        return (send, drop)
    }

    /// The record to send for a pending change, built at send time so it is
    /// always the newest local version.
    public func outgoingRecord(for id: SyncRecordID) -> OutgoingRecord? {
        guard isSendable(id) else { return nil }
        do {
            guard let record = try store.outgoingRecord(for: id) else { return nil }
            if let problem = record.envelope.problem {
                try store.markSendFailed(id, reason: problem.description)
                note(error: "Not sending \(id): \(problem)")
                return nil
            }
            return record
        } catch {
            note(error: "Building \(id) failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// Whether a change may be sent now: its zone allows it on this platform
    /// and isn't deleted, purged or missing.
    private func isSendable(_ id: SyncRecordID) -> Bool {
        guard id.isWellFormed else { return false }
        if platform == .mobile {
            // A phone writes only its own dictations and the Library.
            guard id.zone == .library || id.zone == ownDictationZone else { return false }
        }
        switch zoneState(id.zone) {
        case .created: return true
        case .notCreated: return canCreate(id.zone)
        case .deletedRemotely, .purged, .missing: return false
        }
    }

    /// A Mac may create any zone it has never seen (its own, the legacy zone,
    /// or the zone of a device whose dictations it holds from v1); a phone
    /// only its own and the Library.
    private func canCreate(_ zone: SyncZone) -> Bool {
        switch platform {
        case .mac: true
        case .mobile: zone == .library || zone == ownDictationZone
        }
    }

    private func zoneState(_ zone: SyncZone) -> ZoneState {
        zoneStates[zone] ?? .notCreated
    }

    private func setZoneState(_ state: ZoneState, for zone: SyncZone) throws {
        guard zoneState(zone) != state else { return }
        try store.setZoneState(state, for: zone)
        zoneStates[zone] = state
        refreshMissingZones()
    }

    // MARK: Events

    public func handle(_ event: SyncEvent) -> [EngineCommand] {
        do {
            let commands: [EngineCommand]
            switch event {
            case .stateUpdate(let data):
                commands = []
                // Once sync is off (purged, another account) nothing more is
                // saved for this account's engine.
                if !checkpointsBlocked, isActive { try store.saveEngineState(data) }
            case .accountChange(let change):
                commands = try handleAccountChange(change)
            case .fetchedDatabaseChanges(let modifiedZones, let deletions):
                commands = try handleDatabaseChanges(modifiedZones: modifiedZones, deletions: deletions)
            case .fetchedRecordZoneChanges(let modifications, let deletions):
                commands = try handleFetchedRecords(modifications, deletions: deletions)
            case .sentDatabaseChanges(let savedZones, let failedZones):
                commands = try handleSentZones(saved: savedZones, failed: failedZones)
            case .sentRecordZoneChanges(let saved, let failed):
                commands = try handleSentRecords(saved: saved, failed: failed)
            case .didFetchChanges:
                commands = try handleFetchFinished()
            }
            publishStatus()
            return commands
        } catch {
            // Whatever failed was not saved: stop checkpointing so the engine
            // fetches it again on the next launch.
            checkpointsBlocked = true
            note(error: "Sync event failed: \(error.localizedDescription)")
            publishStatus()
            return []
        }
    }

    private func handleAccountChange(_ change: AccountChange) throws -> [EngineCommand] {
        switch change {
        case .signIn:
            // Maybe a different account: the app checks before anything is
            // sent (confirmAccount, or its account choice).
            if status.suspension == .signedOut {
                try setSuspension(.awaitingAccountCheck)
            }
            return []
        case .signOut:
            try setSuspension(.signedOut)
            return []
        case .switchAccounts:
            // The host stops this engine; the person decides what happens
            // with this account's data under the new one.
            try setSuspension(.accountChanged)
            return []
        }
    }

    private func handleDatabaseChanges(modifiedZones: [SyncZone], deletions: [ZoneDeletion]) throws -> [EngineCommand] {
        var commands: [EngineCommand] = []
        for zone in modifiedZones where zoneState(zone) != .created {
            // It exists: a zone we thought missing (or never saw) is there.
            try setZoneState(.created, for: zone)
        }
        for deletion in deletions {
            commands += try handleZoneDeletion(deletion)
        }
        return commands
    }

    private func handleZoneDeletion(_ deletion: ZoneDeletion) throws -> [EngineCommand] {
        let zone = deletion.zone
        switch deletion.reason {
        case .deleted:
            try store.clearCloudMetadata(in: zone)
            try setZoneState(.deletedRemotely, for: zone)
            logger.notice("Zone \(zone.zoneName, privacy: .public) was deleted by another device")
            // The shared copy is gone: hold sync until the person decides.
            // Another device's dictation zone only stops being sent to.
            if zone == .library || zone == .macOnly || zone == ownDictationZone {
                try setSuspension(.libraryDeleted)
            }
            return []
        case .purged:
            for known in Array(zoneStates.keys) + homeZones {
                try store.clearCloudMetadata(in: known)
                try setZoneState(.purged, for: known)
            }
            try store.saveEngineState(nil)
            try setSuspension(.purged)
            logger.notice("Orttaai's iCloud data was deleted in Settings; sync is off")
            return []
        case .encryptedDataReset:
            // The keys were reset and the zone emptied. This device still has
            // everything, deletions included, so it rebuilds the zone.
            try store.clearCloudMetadata(in: zone)
            try setZoneState(.notCreated, for: zone)
            guard platform == .mac || zone == .library || zone == ownDictationZone else { return [] }
            let ids = try store.enqueueAllRecords(in: zone)
            logger.notice("Rebuilding \(zone.zoneName, privacy: .public) after an encryption reset (\(ids.count) records)")
            var commands: [EngineCommand] = [.addPendingZoneSaves([zone])]
            if !ids.isEmpty { commands.append(.addPendingSaves(ids)) }
            return commands
        }
    }

    private func handleFetchedRecords(_ modifications: [FetchedRecord], deletions: [SyncRecordID]) throws -> [EngineCommand] {
        var accepted: [InboundRecord] = []
        var quarantined: [QuarantinedRecord] = []
        var seenZones = Set<SyncZone>()

        for item in modifications {
            switch item {
            case .unreadable(let record):
                quarantined.append(record)
            case .record(let record):
                let envelope = record.envelope
                // A phone never stores another device's dictations, even if
                // they arrive.
                guard envelope.id.zone.isFetched(by: platform, deviceID: deviceID) else { continue }
                seenZones.insert(envelope.id.zone)
                if let problem = envelope.problem {
                    quarantined.append(QuarantinedRecord(
                        zoneName: envelope.id.zone.zoneName,
                        recordName: envelope.id.recordName,
                        recordType: envelope.kind?.recordType ?? "",
                        problem: problem,
                        archivedRecord: record.archivedRecord ?? record.systemFields,
                        receivedAt: Date()
                    ))
                } else {
                    accepted.append(record)
                }
            }
        }

        if !quarantined.isEmpty {
            try store.quarantine(quarantined)
            logger.error("Quarantined \(quarantined.count) records this version can't apply")
        }
        for zone in seenZones where zoneState(zone) != .created {
            try setZoneState(.created, for: zone)
        }

        var commands: [EngineCommand] = []
        if !accepted.isEmpty {
            let result = try store.applyInbound(accepted, decide: ConflictPolicy.decide)
            if !result.changed.isEmpty { observer?.syncDidApplyRemoteChanges(result.changed) }
            let resend = result.needsSend.filter(isSendable)
            if !resend.isEmpty, initialFetchDone { commands.append(.addPendingSaves(resend)) }
        }
        if !deletions.isEmpty {
            // v2 never deletes records (deletions are saved as tombstones), so
            // a physical deletion only means CloudKit forgot the record: drop
            // its system fields and keep the local row.
            try store.clearSystemFields(for: deletions)
        }
        return commands
    }

    private func handleSentZones(saved: [SyncZone], failed: [FailedZoneSave]) throws -> [EngineCommand] {
        for zone in saved {
            try setZoneState(.created, for: zone)
        }
        var commands: [EngineCommand] = []
        if !saved.isEmpty, initialFetchDone {
            // Changes held back until their zone existed can go now.
            let waiting = try store.outboxEntries().map(\.id).filter { saved.contains($0.zone) && isSendable($0) }
            if !waiting.isEmpty { commands.append(.addPendingSaves(waiting)) }
        }
        for failure in failed {
            switch failure.failure {
            case .transient:
                commands.append(.addPendingZoneSaves([failure.zone]))
            case .quotaExceeded:
                try setSuspension(.quotaExceeded)
            default:
                note(error: "Creating \(failure.zone.zoneName) failed: \(failure.failure)")
            }
        }
        return commands
    }

    private func handleSentRecords(saved: [SendAck], failed: [FailedSave]) throws -> [EngineCommand] {
        if !saved.isEmpty {
            try store.acknowledge(saved)
            status.lastSentAt = Date()
            status.lastError = nil
        }

        var commands: [EngineCommand] = []
        var resend: [SyncRecordID] = []
        for failure in failed {
            let id = failure.id
            switch failure.failure {
            case .serverRecordChanged(let server):
                guard let server, server.envelope.problem == nil, server.envelope.id == id else {
                    try store.markSendFailed(id, reason: "The server's copy could not be read")
                    continue
                }
                let result = try store.applyInbound([server], decide: ConflictPolicy.decide)
                if !result.changed.isEmpty { observer?.syncDidApplyRemoteChanges(result.changed) }
                resend += result.needsSend

            case .zoneNotFound:
                switch zoneState(id.zone) {
                case .notCreated:
                    if canCreate(id.zone) {
                        commands.append(.addPendingZoneSaves([id.zone]))
                    }
                case .created, .missing:
                    // It existed and now it doesn't, with no deletion seen
                    // yet. Never recreate it here: fetch, so a deletion or
                    // purge is handled by its own rule, and ask if nothing
                    // explains it.
                    try setZoneState(.missing, for: id.zone)
                    commands.append(.fetchNow)
                case .deletedRemotely, .purged:
                    break
                }

            case .unknownItem:
                if zoneState(id.zone) == .created {
                    try store.clearSystemFields(for: [id])
                    resend.append(id)
                }

            case .quotaExceeded:
                try setSuspension(.quotaExceeded)

            case .transient:
                resend.append(id)

            case .permanent(let reason):
                try store.markSendFailed(id, reason: reason)
                note(error: "\(id) can't be sent: \(reason)")
            }
        }
        let sendable = resend.filter(isSendable)
        if !sendable.isEmpty { commands.append(.addPendingSaves(sendable)) }
        return commands
    }

    private func handleFetchFinished() throws -> [EngineCommand] {
        status.lastFetchedAt = Date()
        var commands: [EngineCommand] = []
        if !initialFetchDone, !checkpointsBlocked {
            try store.setInitialFetchCompleted()
            initialFetchDone = true
            commands += try queueEverythingPending()
        }
        observer?.syncDidFinishFetch()
        return commands
    }

    // MARK: Quarantine

    public func quarantinedForRetry() throws -> [(id: Int64, archivedRecord: Data)] {
        try store.quarantinedForRetry()
    }

    public func removeQuarantined(_ ids: [Int64]) throws {
        try store.removeQuarantined(ids)
    }

    /// Applies records taken back out of quarantine. Throws when they
    /// couldn't be saved, so the caller keeps the quarantined copies.
    public func replayQuarantined(_ records: [FetchedRecord]) throws -> [EngineCommand] {
        let commands = try handleFetchedRecords(records, deletions: [])
        publishStatus()
        return commands
    }

    // MARK: Account

    /// The app checked: the account signed in is the one this store syncs
    /// with. Sending resumes.
    public func confirmAccount() throws -> [EngineCommand] {
        guard status.suspension == .awaitingAccountCheck || status.suspension == .signedOut else { return [] }
        try setSuspension(.none)
        publishStatus()
        return try queueEverythingPending()
    }

    // MARK: Person's choices

    /// Resumes after iCloud storage was freed.
    public func resumeAfterQuota() throws -> [EngineCommand] {
        guard status.suspension == .quotaExceeded else { return [] }
        try setSuspension(.none)
        publishStatus()
        return try queueEverythingPending()
    }

    /// "Restore your iCloud copy": the person chose to rebuild a zone that is
    /// missing or was deleted, from this device's records.
    public func restore(zone: SyncZone) throws -> [EngineCommand] {
        try store.clearCloudMetadata(in: zone)
        try setZoneState(.notCreated, for: zone)
        if status.suspension == .libraryDeleted, zoneStates.values.allSatisfy({ $0 != .deletedRemotely }) {
            try setSuspension(.none)
        }
        let ids = try store.enqueueAllRecords(in: zone)
        publishStatus()
        guard isActive else { return [] }
        var commands: [EngineCommand] = [.addPendingZoneSaves([zone])]
        if !ids.isEmpty, initialFetchDone { commands.append(.addPendingSaves(ids)) }
        return commands
    }

    /// Restores every zone after "the iCloud copy was deleted" or a purge,
    /// when the person chooses to upload this device's data again.
    public func restoreAll() throws -> [EngineCommand] {
        var commands: [EngineCommand] = []
        let zones = Set(zoneStates.filter { $0.value != .created }.map(\.key)).union(homeZones)
        try setSuspension(.none)
        for zone in zones where zone.isFetched(by: platform, deviceID: deviceID) || platform == .mac {
            commands += try restore(zone: zone)
        }
        return commands
    }

    // MARK: Status

    private func setSuspension(_ suspension: SyncSuspension) throws {
        guard status.suspension != suspension else { return }
        try store.saveSuspension(suspension)
        status.suspension = suspension
    }

    private func refreshMissingZones() {
        status.missingZones = zoneStates.filter { $0.value == .missing }.map(\.key).sorted { $0.zoneName < $1.zoneName }
    }

    private func note(error message: String) {
        status.lastError = message
        logger.error("\(message, privacy: .public)")
    }

    private func publishStatus() {
        observer?.syncStatusDidChange(status)
    }
}
