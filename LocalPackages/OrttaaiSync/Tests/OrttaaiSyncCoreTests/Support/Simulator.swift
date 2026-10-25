// Simulator.swift
// OrttaaiSyncCoreTests
//
// A small iCloud and a small CKSyncEngine, enough to run real coordinators
// against each other: zones, change feeds with tokens, change tags that
// refuse stale saves, zone deletions, and failures injected on purpose.

import Foundation
@testable import OrttaaiSyncCore

/// A seeded random source, so a failing run can be replayed.
struct SeededRandom: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func chance(_ probability: Double) -> Bool {
        Double.random(in: 0..<1, using: &self) < probability
    }
}

final class SimCloud: @unchecked Sendable {
    struct Stored {
        var envelope: SyncEnvelope
        var tag: Int
    }

    struct Zone {
        var records: [String: Stored] = [:]
        var changes: [(seq: Int, name: String)] = []
    }

    enum DatabaseChange {
        case modified(SyncZone)
        case deleted(ZoneDeletion)
    }

    private(set) var zones: [SyncZone: Zone] = [:]
    private var seq = 0
    private var databaseLog: [(seq: Int, change: DatabaseChange)] = []
    private(set) var saveCount = 0

    static func systemFields(tag: Int) -> Data { Data("tag:\(tag)".utf8) }

    static func tag(from systemFields: Data?) -> Int? {
        guard let systemFields, let text = String(data: systemFields, encoding: .utf8), text.hasPrefix("tag:") else { return nil }
        return Int(text.dropFirst(4))
    }

    var existingZones: [SyncZone] { Array(zones.keys) }

    func saveZone(_ zone: SyncZone) {
        guard zones[zone] == nil else { return }
        zones[zone] = Zone()
        seq += 1
        databaseLog.append((seq, .modified(zone)))
    }

    func deleteZone(_ zone: SyncZone, reason: ZoneDeletionReason) {
        zones[zone] = nil
        seq += 1
        databaseLog.append((seq, .deleted(ZoneDeletion(zone: zone, reason: reason))))
    }

    func removeZoneWithoutLog(_ zone: SyncZone) {
        zones[zone] = nil
    }

    func save(_ record: OutgoingRecord) -> Result<SendAck, SaveFailure> {
        let id = record.envelope.id
        guard var zone = zones[id.zone] else { return .failure(.zoneNotFound) }
        let sentTag = Self.tag(from: record.systemFields)
        let existing = zone.records[id.recordName]
        if let existing {
            guard sentTag == existing.tag else {
                return .failure(.serverRecordChanged(InboundRecord(envelope: existing.envelope, systemFields: Self.systemFields(tag: existing.tag))))
            }
        } else if sentTag != nil {
            return .failure(.unknownItem)
        }
        let newTag = (existing?.tag ?? 0) + 1
        zone.records[id.recordName] = Stored(envelope: record.envelope, tag: newTag)
        seq += 1
        zone.changes.append((seq, id.recordName))
        zones[id.zone] = zone
        saveCount += 1
        return .success(SendAck(id: id, revision: record.envelope.revision, systemFields: Self.systemFields(tag: newTag)))
    }

    func databaseChanges(since token: Int) -> (modified: [SyncZone], deletions: [ZoneDeletion], token: Int) {
        var modified: [SyncZone] = []
        var deletions: [ZoneDeletion] = []
        for entry in databaseLog where entry.seq > token {
            switch entry.change {
            case .modified(let zone): modified.append(zone)
            case .deleted(let deletion): deletions.append(deletion)
            }
        }
        // Zones whose records changed also count as modified.
        for (zone, contents) in zones where contents.changes.contains(where: { $0.seq > token }) && !modified.contains(zone) {
            modified.append(zone)
        }
        return (modified, deletions, seq)
    }

    func zoneChanges(_ zone: SyncZone, since token: Int) -> (records: [InboundRecord], token: Int)? {
        guard let contents = zones[zone] else { return nil }
        let names = Set(contents.changes.filter { $0.seq > token }.map(\.name))
        let records = names.compactMap { name -> InboundRecord? in
            guard let stored = contents.records[name] else { return nil }
            return InboundRecord(envelope: stored.envelope, systemFields: Self.systemFields(tag: stored.tag))
        }
        return (records, seq)
    }

    func record(_ id: SyncRecordID) -> SyncEnvelope? {
        zones[id.zone]?.records[id.recordName]?.envelope
    }
}

/// One device: a real coordinator over a reference store, and an engine
/// that behaves like CKSyncEngine as far as the coordinator can tell.
final class SimDevice: SyncCoordinatorObserver, @unchecked Sendable {
    struct EngineState: Codable {
        var databaseToken = 0
        var zoneTokens: [String: Int] = [:]
        var pendingSaves: [SyncRecordID] = []
        var pendingZones: [SyncZone] = []
    }

    let name: String
    let platform: SyncPlatform
    let store: InMemorySyncStore
    private(set) var coordinator: SyncCoordinator!
    private var engine = EngineState()
    private var needsFetch = false
    private(set) var lastStatus = SyncStatus()

    init(name: String, platform: SyncPlatform, kind: DeviceKind, deviceID: String = DeviceID.make()) {
        self.name = name
        self.platform = platform
        self.store = InMemorySyncStore(deviceID: deviceID, kind: kind)
    }

    var deviceID: String { store.deviceID }

    func boot() async throws {
        coordinator = SyncCoordinator(store: store, platform: platform, deviceID: deviceID, observer: self)
        if let data = try await coordinator.savedEngineState() {
            engine = try JSONDecoder().decode(EngineState.self, from: data)
        } else {
            engine = EngineState()
        }
        apply(try await coordinator.start())
    }

    /// The app is killed: everything in memory goes, then it launches again.
    /// `losePending` also drops the engine's saved pending list, the worst case.
    func crashAndRelaunch(losePending: Bool = false) async throws {
        coordinator = nil
        try await boot()
        if losePending {
            engine.pendingSaves = []
            engine.pendingZones = []
            apply(try await coordinator.start())
        }
    }

    var pendingSaves: Set<SyncRecordID> { Set(engine.pendingSaves) }

    func apply(_ commands: [EngineCommand]) {
        for command in commands {
            switch command {
            case .addPendingSaves(let ids):
                for id in ids where !engine.pendingSaves.contains(id) { engine.pendingSaves.append(id) }
            case .removePendingSaves(let ids):
                engine.pendingSaves.removeAll { ids.contains($0) }
            case .addPendingZoneSaves(let zones):
                for zone in zones where !engine.pendingZones.contains(zone) { engine.pendingZones.append(zone) }
            case .fetchNow:
                needsFetch = true
            }
        }
    }

    func noteLocalChanges(_ ids: [SyncRecordID]) async {
        apply(await coordinator.noteLocalChanges(ids))
        await checkpoint()
    }

    private func checkpoint() async {
        let data = try! JSONEncoder().encode(engine)
        apply(await coordinator.handle(.stateUpdate(data)))
    }

    func send(to cloud: SimCloud, random: inout SeededRandom, failureRate: Double = 0) async {
        guard await coordinator.isActive else { return }

        if !engine.pendingZones.isEmpty {
            var saved: [SyncZone] = []
            var failed: [FailedZoneSave] = []
            for zone in engine.pendingZones {
                if random.chance(failureRate) {
                    failed.append(FailedZoneSave(zone: zone, failure: .transient))
                } else {
                    cloud.saveZone(zone)
                    saved.append(zone)
                }
            }
            engine.pendingZones = []
            apply(await coordinator.handle(.sentDatabaseChanges(savedZones: saved, failedZones: failed)))
        }

        let batch = await coordinator.prepareBatch(pending: engine.pendingSaves)
        engine.pendingSaves.removeAll { batch.drop.contains($0) }
        var saved: [SendAck] = []
        var failed: [FailedSave] = []
        for id in batch.send {
            engine.pendingSaves.removeAll { $0 == id }
            guard let record = await coordinator.outgoingRecord(for: id) else { continue }
            if random.chance(failureRate) {
                failed.append(FailedSave(id: id, failure: .transient))
                continue
            }
            switch cloud.save(record) {
            case .success(let ack): saved.append(ack)
            case .failure(let failure): failed.append(FailedSave(id: id, failure: failure))
            }
        }
        if !saved.isEmpty || !failed.isEmpty {
            apply(await coordinator.handle(.sentRecordZoneChanges(saved: saved, failed: failed)))
        }
        await checkpoint()
    }

    func fetch(from cloud: SimCloud) async {
        guard await coordinator.isActive else { return }
        needsFetch = false
        let database = cloud.databaseChanges(since: engine.databaseToken)
        apply(await coordinator.handle(.fetchedDatabaseChanges(modifiedZones: database.modified, deletions: database.deletions)))
        engine.databaseToken = database.token
        for deletion in database.deletions { engine.zoneTokens[deletion.zone.zoneName] = nil }

        let scope = await coordinator.fetchScope
        for zone in cloud.existingZones {
            if case .zones(let allowed) = scope, !allowed.contains(zone) { continue }
            guard let changes = cloud.zoneChanges(zone, since: engine.zoneTokens[zone.zoneName] ?? 0) else { continue }
            if !changes.records.isEmpty {
                apply(await coordinator.handle(.fetchedRecordZoneChanges(modifications: changes.records.map { .record($0) }, deletions: [])))
            }
            engine.zoneTokens[zone.zoneName] = changes.token
        }
        await checkpoint()
        apply(await coordinator.handle(.didFetchChanges))
        await checkpoint()
    }

    func sync(with cloud: SimCloud, random: inout SeededRandom, failureRate: Double = 0) async {
        await fetch(from: cloud)
        await send(to: cloud, random: &random, failureRate: failureRate)
        if needsFetch { await fetch(from: cloud) }
    }

    // MARK: SyncCoordinatorObserver

    func syncDidApplyRemoteChanges(_ ids: [SyncRecordID]) {}
    func syncStatusDidChange(_ status: SyncStatus) { lastStatus = status }
    func syncDidFinishFetch() {}
}

/// Lets the simulated cloud return Result<SendAck, SaveFailure>.
extension SaveFailure: Error {}
