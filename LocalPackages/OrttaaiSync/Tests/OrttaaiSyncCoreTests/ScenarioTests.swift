// ScenarioTests.swift
// OrttaaiSyncCoreTests
//
// The cases the contract names, one by one, on real coordinators over the
// simulated iCloud.

import Foundation
import Testing
@testable import OrttaaiSyncCore

@Suite("Sync scenarios")
struct ScenarioTests {
    func settle(_ devices: [SimDevice], _ cloud: SimCloud, rounds: Int = 4) async {
        var random = SeededRandom(seed: 1)
        for _ in 0..<rounds {
            for device in devices { await device.sync(with: cloud, random: &random) }
        }
    }

    func bootAll(_ devices: [SimDevice]) async throws {
        for device in devices { try await device.boot() }
    }

    @Test func phoneDictationsReachTheMacAndMacDictationsStayOnTheMac() async throws {
        let cloud = SimCloud()
        let mac = SimDevice(name: "mac", platform: .mac, kind: .mac)
        let phone = SimDevice(name: "phone", platform: .mobile, kind: .iphone)
        try await bootAll([mac, phone])

        let fromPhone = phone.store.createDictation(text: "Said on the phone")
        await phone.noteLocalChanges([fromPhone])
        let fromMac = mac.store.createDictation(text: "Said on the Mac")
        await mac.noteLocalChanges([fromMac])
        await settle([mac, phone], cloud)

        #expect(mac.store.liveDictations()[fromPhone] == "Said on the phone")
        #expect(mac.store.liveDictations()[fromMac] == "Said on the Mac")
        #expect(phone.store.liveDictations().keys.sorted { $0.recordName < $1.recordName } == [fromPhone])
        #expect(phone.store.row(fromMac) == nil)
        #expect(cloud.existingZones.contains(.dictations(originDeviceID: phone.deviceID)))
    }

    @Test func nothingIsSentBeforeTheFirstFetch() async throws {
        let cloud = SimCloud()
        let mac = SimDevice(name: "mac", platform: .mac, kind: .mac)
        try await mac.boot()
        let id = mac.store.createDictation(text: "Before any fetch")
        await mac.noteLocalChanges([id])
        var random = SeededRandom(seed: 2)
        await mac.send(to: cloud, random: &random)
        #expect(cloud.record(id) == nil)
        await mac.sync(with: cloud, random: &random)
        await mac.sync(with: cloud, random: &random)
        #expect(cloud.record(id) != nil)
    }

    @Test func deletingAPhoneDictationOnTheMacReachesThePhone() async throws {
        let cloud = SimCloud()
        let mac = SimDevice(name: "mac", platform: .mac, kind: .mac)
        let phone = SimDevice(name: "phone", platform: .mobile, kind: .iphone)
        try await bootAll([mac, phone])
        let id = phone.store.createDictation(text: "Delete me from the Mac")
        await phone.noteLocalChanges([id])
        await settle([phone, mac], cloud)

        mac.store.deleteDictation(id)
        await mac.noteLocalChanges([id])
        await settle([mac, phone], cloud)

        #expect(phone.store.deletedDictations().contains(id))
        #expect(phone.store.liveDictations()[id] == nil)
        #expect(cloud.record(id)?.isDeleted == true)
        #expect(cloud.record(id)?.payload == nil)
    }

    @Test func aStaleEditNeverRevivesADeletedDictation() async throws {
        let cloud = SimCloud()
        let macA = SimDevice(name: "macA", platform: .mac, kind: .mac)
        let macB = SimDevice(name: "macB", platform: .mac, kind: .mac)
        try await bootAll([macA, macB])
        let id = macA.store.createDictation(text: "Original")
        await macA.noteLocalChanges([id])
        await settle([macA, macB], cloud)

        // B edits while offline, many times, so its counter is far ahead.
        for round in 0..<5 { macB.store.editDictation(id, text: "Edited \(round)") }
        macA.store.deleteDictation(id)
        await macA.noteLocalChanges([id])
        await macB.noteLocalChanges([id])
        await settle([macA, macB], cloud)

        #expect(macA.store.liveDictations()[id] == nil)
        #expect(macB.store.liveDictations()[id] == nil)
        #expect(cloud.record(id)?.isDeleted == true)
    }

    @Test func twoDevicesAddingTheSameWordShareOneRecord() async throws {
        let cloud = SimCloud()
        let mac = SimDevice(name: "mac", platform: .mac, kind: .mac)
        let phone = SimDevice(name: "phone", platform: .mobile, kind: .iphone)
        try await bootAll([mac, phone])
        let onMac = mac.store.upsertWord(source: "Tolu", target: "Tolu")
        let onPhone = phone.store.upsertWord(source: "  tolu ", target: "Tolú")
        #expect(onMac == onPhone)
        await mac.noteLocalChanges([onMac])
        await phone.noteLocalChanges([onPhone])
        await settle([mac, phone], cloud)
        #expect(mac.store.dictionary() == phone.store.dictionary())
        #expect(mac.store.dictionary().count == 1)
    }

    @Test func aDeletedWordStaysDeletedUntilAddedAgain() async throws {
        let cloud = SimCloud()
        let mac = SimDevice(name: "mac", platform: .mac, kind: .mac)
        let phone = SimDevice(name: "phone", platform: .mobile, kind: .iphone)
        try await bootAll([mac, phone])
        let id = mac.store.upsertWord(source: "GRDB", target: "GRDB")
        await mac.noteLocalChanges([id])
        await settle([mac, phone], cloud)

        phone.store.deleteWord(source: "grdb")
        await phone.noteLocalChanges([id])
        await settle([phone, mac], cloud)
        #expect(mac.store.dictionary()[id] == .some(nil))

        mac.store.upsertWord(source: "GRDB", target: "GRDB")
        await mac.noteLocalChanges([id])
        await settle([mac, phone], cloud)
        #expect(phone.store.dictionary()[id] == "GRDB")
        #expect(mac.store.row(id)?.envelope.generation == 1)
    }

    @Test func aChangeMadeDuringASendIsNotLost() async throws {
        let cloud = SimCloud()
        let mac = SimDevice(name: "mac", platform: .mac, kind: .mac)
        try await mac.boot()
        var random = SeededRandom(seed: 3)
        await mac.sync(with: cloud, random: &random)
        let id = mac.store.createDictation(text: "First")
        await mac.noteLocalChanges([id])
        // The engine builds revision A; the person edits before the ack.
        let first = await mac.coordinator.outgoingRecord(for: id)!
        mac.store.editDictation(id, text: "Second")
        let ack = try cloud.save(first).get()
        _ = await mac.coordinator.handle(.sentRecordZoneChanges(saved: [ack], failed: []))
        // Revision B is still owed to the server.
        #expect(try mac.store.outboxEntries().contains { $0.id == id })
        await mac.noteLocalChanges([id])
        await mac.sync(with: cloud, random: &random)
        #expect(try PayloadCoder.decode(DictationPayload.self, from: cloud.record(id)!.payload!).text == "Second")
        #expect(try mac.store.outboxEntries().isEmpty)
    }

    @Test func aCrashBeforeSendingLosesNothing() async throws {
        let cloud = SimCloud()
        let phone = SimDevice(name: "phone", platform: .mobile, kind: .iphone)
        try await phone.boot()
        var random = SeededRandom(seed: 4)
        await phone.sync(with: cloud, random: &random)
        let id = phone.store.createDictation(text: "Saved, then the app died")
        // No noteLocalChanges: the app was killed right after the commit.
        try await phone.crashAndRelaunch(losePending: true)
        await phone.sync(with: cloud, random: &random)
        await phone.sync(with: cloud, random: &random)
        #expect(cloud.record(id) != nil)
    }

    @Test func aFailedInboundCommitIsFetchedAgain() async throws {
        let cloud = SimCloud()
        let mac = SimDevice(name: "mac", platform: .mac, kind: .mac)
        let phone = SimDevice(name: "phone", platform: .mobile, kind: .iphone)
        try await bootAll([mac, phone])
        await settle([mac, phone], cloud, rounds: 1)
        let id = phone.store.createDictation(text: "Arrives while the Mac's disk is full")
        await phone.noteLocalChanges([id])
        await settle([phone], cloud, rounds: 2)

        mac.store.failNextApply = true
        var random = SeededRandom(seed: 5)
        await mac.fetch(from: cloud)
        #expect(mac.store.liveDictations()[id] == nil)
        // The checkpoint wasn't saved past the failure; a relaunch refetches.
        try await mac.crashAndRelaunch()
        await mac.sync(with: cloud, random: &random)
        #expect(mac.store.liveDictations()[id] != nil)
    }

    @Test func aMissingZoneIsNeverRecreatedWithoutAReason() async throws {
        let cloud = SimCloud()
        let phone = SimDevice(name: "phone", platform: .mobile, kind: .iphone)
        try await phone.boot()
        await settle([phone], cloud, rounds: 2)
        #expect(phone.store.zoneState(.library) == .created)

        // The Library disappears with no deletion in the change feed.
        let id = phone.store.upsertWord(source: "Lagos", target: "Lagos")
        cloud.deleteZoneSilently(.library)
        await phone.noteLocalChanges([id])
        var random = SeededRandom(seed: 6)
        await phone.send(to: cloud, random: &random)
        #expect(phone.store.zoneState(.library) == .missing)
        #expect(!cloud.existingZones.contains(.library))
        #expect(phone.lastStatus.missingZones == [.library])

        // The person chooses to restore.
        phone.apply(try await phone.coordinator.restore(zone: .library))
        await phone.sync(with: cloud, random: &random)
        await phone.sync(with: cloud, random: &random)
        #expect(cloud.record(id) != nil)
    }

    @Test func anotherDeviceDeletingTheLibraryHoldsSync() async throws {
        let cloud = SimCloud()
        let phone = SimDevice(name: "phone", platform: .mobile, kind: .iphone)
        try await phone.boot()
        let id = phone.store.upsertWord(source: "Orttaai", target: "Orttaai")
        await phone.noteLocalChanges([id])
        await settle([phone], cloud, rounds: 3)

        cloud.deleteZone(.library, reason: .deleted)
        await settle([phone], cloud, rounds: 2)
        #expect(phone.store.currentSuspension == .libraryDeleted)
        #expect(!cloud.existingZones.contains(.library))
        #expect(phone.store.dictionary()[id] == "Orttaai")
    }

    @Test func aPurgeTurnsSyncOffAndKeepsLocalData() async throws {
        let cloud = SimCloud()
        let mac = SimDevice(name: "mac", platform: .mac, kind: .mac)
        try await mac.boot()
        let id = mac.store.createDictation(text: "Keep me")
        await mac.noteLocalChanges([id])
        await settle([mac], cloud, rounds: 3)

        cloud.deleteZone(.dictations(originDeviceID: mac.deviceID), reason: .purged)
        await settle([mac], cloud, rounds: 2)
        #expect(mac.store.currentSuspension == .purged)
        #expect(await !mac.coordinator.isActive)
        #expect(mac.store.liveDictations()[id] == "Keep me")
        #expect(mac.store.savedEngineState == nil)
    }

    @Test func anEncryptionResetRebuildsTheZoneWithItsTombstones() async throws {
        let cloud = SimCloud()
        let mac = SimDevice(name: "mac", platform: .mac, kind: .mac)
        try await mac.boot()
        let kept = mac.store.createDictation(text: "Kept")
        let deleted = mac.store.createDictation(text: "Deleted")
        await mac.noteLocalChanges([kept, deleted])
        await settle([mac], cloud, rounds: 3)
        mac.store.deleteDictation(deleted)
        await mac.noteLocalChanges([deleted])
        await settle([mac], cloud, rounds: 2)

        let zone = SyncZone.dictations(originDeviceID: mac.deviceID)
        cloud.deleteZone(zone, reason: .encryptedDataReset)
        await settle([mac], cloud, rounds: 3)
        #expect(cloud.record(kept)?.isDeleted == false)
        // The deletion is in iCloud again, so no stale device can revive it.
        #expect(cloud.record(deleted)?.isDeleted == true)
        #expect(mac.store.currentSuspension == SyncSuspension.none)
    }

    @Test func anOfflineEditNeverRevivesAWordDeletedElsewhere() async throws {
        let cloud = SimCloud()
        let mac = SimDevice(name: "mac", platform: .mac, kind: .mac)
        let phone = SimDevice(name: "phone", platform: .mobile, kind: .iphone)
        try await bootAll([mac, phone])
        let id = mac.store.upsertWord(source: "Lagos", target: "Lagos")
        await mac.noteLocalChanges([id])
        await settle([mac, phone], cloud)

        phone.store.deleteWord(source: "Lagos")
        await phone.noteLocalChanges([id])
        // The Mac, offline and busy, edits the word with a far higher counter.
        mac.store.advanceClock(by: 1_000)
        mac.store.editWord(source: "Lagos", target: "LAGOS")
        await mac.noteLocalChanges([id])
        await settle([phone, mac], cloud)
        #expect(mac.store.dictionary()[id] == .some(nil))
        #expect(phone.store.dictionary()[id] == .some(nil))

        // Adding it again on purpose brings it back everywhere.
        mac.store.upsertWord(source: "Lagos", target: "Lagos")
        await mac.noteLocalChanges([id])
        await settle([mac, phone], cloud)
        #expect(phone.store.dictionary()[id] == "Lagos")
    }

    @Test func signingBackInWaitsForTheAccountCheck() async throws {
        let cloud = SimCloud()
        let phone = SimDevice(name: "phone", platform: .mobile, kind: .iphone)
        try await phone.boot()
        await settle([phone], cloud, rounds: 1)
        _ = await phone.coordinator.handle(.accountChange(.signOut))
        _ = await phone.coordinator.handle(.accountChange(.signIn))
        #expect(phone.store.currentSuspension == .awaitingAccountCheck)
        #expect(await !phone.coordinator.isActive)
        let id = phone.store.createDictation(text: "Not until the account is confirmed")
        #expect(await phone.coordinator.noteLocalChanges([id]).isEmpty)
        phone.apply(try await phone.coordinator.confirmAccount())
        #expect(phone.store.currentSuspension == SyncSuspension.none)
        await phone.noteLocalChanges([id])
        await settle([phone], cloud, rounds: 2)
        #expect(cloud.record(id) != nil)
    }

    @Test func accountSwitchStopsSync() async throws {
        let cloud = SimCloud()
        let phone = SimDevice(name: "phone", platform: .mobile, kind: .iphone)
        try await phone.boot()
        await settle([phone], cloud, rounds: 1)
        _ = await phone.coordinator.handle(.accountChange(.switchAccounts))
        #expect(phone.store.currentSuspension == .accountChanged)
        #expect(await !phone.coordinator.isActive)
        _ = await phone.coordinator.handle(.accountChange(.signOut))
        #expect(phone.store.currentSuspension == .signedOut)
        _ = await phone.coordinator.handle(.accountChange(.signIn))
        #expect(phone.store.currentSuspension == .awaitingAccountCheck)
    }

    @Test func quotaPausesAndResumes() async throws {
        let cloud = SimCloud()
        let phone = SimDevice(name: "phone", platform: .mobile, kind: .iphone)
        try await phone.boot()
        await settle([phone], cloud, rounds: 1)
        let id = phone.store.createDictation(text: "Waiting for space")
        _ = await phone.coordinator.handle(.sentRecordZoneChanges(saved: [], failed: [FailedSave(id: id, failure: .quotaExceeded)]))
        #expect(phone.store.currentSuspension == .quotaExceeded)
        #expect(await phone.coordinator.prepareBatch(pending: [id]).send.isEmpty)
        phone.apply(try await phone.coordinator.resumeAfterQuota())
        await settle([phone], cloud, rounds: 2)
        #expect(cloud.record(id) != nil)
    }

    @Test func throttledSendWaitsWithoutAnError() async throws {
        let cloud = SimCloud()
        let mac = SimDevice(name: "mac", platform: .mac, kind: .mac)
        try await mac.boot()
        await settle([mac], cloud, rounds: 1)
        let id = mac.store.createDictation(text: "Sent once iCloud has room")
        let commands = await mac.coordinator.handle(.sentRecordZoneChanges(saved: [], failed: [FailedSave(id: id, failure: .transient)]))
        #expect(commands.contains(.addPendingSaves([id])))
        var status = await mac.coordinator.currentStatus
        #expect(status.waitingToRetry)
        #expect(status.lastError == nil)
        await mac.noteLocalChanges([id])
        await settle([mac], cloud, rounds: 2)
        #expect(cloud.record(id) != nil)
        status = await mac.coordinator.currentStatus
        #expect(!status.waitingToRetry)
    }

    @Test func unreadableAndFutureRecordsAreQuarantined() async throws {
        let mac = SimDevice(name: "mac", platform: .mac, kind: .mac)
        try await mac.boot()
        var future = SyncEnvelope(
            id: .dictionaryEntry(normalizedSource: "future"),
            revision: Revision(counter: 1, modifiedAt: Date(), writerDeviceID: "x"),
            payload: Data("{}".utf8)
        )
        future.schemaVersion = 7
        let unreadable = QuarantinedRecord(zoneName: "Library", recordName: "dict.zz", recordType: "DictionaryEntry", problem: .undecodableRecord, archivedRecord: nil, receivedAt: Date())
        _ = await mac.coordinator.handle(.fetchedRecordZoneChanges(
            modifications: [.record(InboundRecord(envelope: future, systemFields: nil)), .unreadable(unreadable)],
            deletions: []
        ))
        #expect(mac.store.quarantined.count == 2)
        #expect(mac.store.dictionary().isEmpty)
    }

    @Test func aPhoneIgnoresOtherDevicesDictationsEvenIfTheyArrive() async throws {
        let phone = SimDevice(name: "phone", platform: .mobile, kind: .iphone)
        try await phone.boot()
        let other = DeviceID.make()
        let envelope = SyncEnvelope(
            id: .dictation(syncID: "x", zone: .dictations(originDeviceID: other)),
            revision: Revision(counter: 1, modifiedAt: Date(), writerDeviceID: other),
            payload: try PayloadCoder.encode(DictationPayload(createdAt: Date(), text: "Not for the phone")),
            origin: DictationOrigin(deviceID: other, kind: .mac)
        )
        _ = await phone.coordinator.handle(.fetchedRecordZoneChanges(modifications: [.record(InboundRecord(envelope: envelope, systemFields: nil))], deletions: []))
        #expect(phone.store.liveDictations().isEmpty)
    }

    @Test func aMacUploadsDictationsItHoldsFromAnotherMac() async throws {
        // A v1 migration: dictations made on a Mac that never upgraded go to
        // that Mac's zone, which this Mac may create.
        let cloud = SimCloud()
        let mac = SimDevice(name: "mac", platform: .mac, kind: .mac)
        try await mac.boot()
        let oldMac = DeviceID.make()
        let id = SyncRecordID.dictation(syncID: "legacy-1", zone: .dictations(originDeviceID: oldMac))
        mac.store.importDictation(SyncEnvelope(
            id: id,
            revision: Revision(counter: 1, modifiedAt: Date(), writerDeviceID: mac.deviceID),
            payload: try PayloadCoder.encode(DictationPayload(createdAt: Date(), text: "From the old Mac")),
            origin: DictationOrigin(deviceID: oldMac, kind: .mac)
        ))
        await mac.noteLocalChanges([id])
        await settle([mac], cloud, rounds: 3)
        #expect(cloud.record(id) != nil)
    }
}

extension SimCloud {
    /// Removes a zone without telling anyone, as if CloudKit lost it.
    func deleteZoneSilently(_ zone: SyncZone) {
        removeZoneWithoutLog(zone)
    }
}
