// CoreRulesTests.swift
// OrttaaiSyncCoreTests

import Foundation
import Testing
@testable import OrttaaiSyncCore

@Suite("Identity, normalization and revisions")
struct CoreRulesTests {
    @Test func zoneNamesRoundTrip() {
        let device = DeviceID.make()
        for zone in [SyncZone.library, .macOnly, .legacyDictations, .dictations(originDeviceID: device)] {
            #expect(SyncZone(zoneName: zone.zoneName) == zone)
        }
        #expect(SyncZone(zoneName: "Dictations-") == nil)
        #expect(SyncZone(zoneName: "Dictations-NOT/valid") == nil)
        #expect(SyncZone(zoneName: "_defaultZone") == nil)
        #expect(!DeviceID.isValid("legacy"))
    }

    @Test func phonesFetchOnlyTheLibraryAndTheirOwnDictations() {
        let me = DeviceID.make()
        let other = DeviceID.make()
        #expect(SyncZone.library.isFetched(by: .mobile, deviceID: me))
        #expect(SyncZone.dictations(originDeviceID: me).isFetched(by: .mobile, deviceID: me))
        #expect(!SyncZone.dictations(originDeviceID: other).isFetched(by: .mobile, deviceID: me))
        #expect(!SyncZone.macOnly.isFetched(by: .mobile, deviceID: me))
        #expect(!SyncZone.legacyDictations.isFetched(by: .mobile, deviceID: me))
        #expect(SyncZone.dictations(originDeviceID: other).isFetched(by: .mac, deviceID: me))
    }

    @Test func recordIDsKnowTheirKindAndZone() {
        let device = DeviceID.make()
        let dictation = SyncRecordID.dictation(syncID: "abc", zone: .dictations(originDeviceID: device))
        #expect(dictation.kind == .dictation)
        #expect(dictation.localKey == "abc")
        #expect(dictation.isWellFormed)
        #expect(!SyncRecordID(zone: .library, recordName: "dictation.abc").isWellFormed)
        #expect(!SyncRecordID(zone: .library, recordName: "snippet.x").isWellFormed)
        #expect(SyncRecordID.dictionaryEntry(normalizedSource: "tolu").isWellFormed)
        #expect(SyncRecordID.macPreferences.kind == .macPreferences)
        #expect(!SyncRecordID(zone: .library, recordName: "mystery.1").isWellFormed)
    }

    @Test func normalizationMatchesOrttaai() {
        #expect(SyncNormalization.normalizedKey("  Tolu   Oyinbooke \n") == "tolu oyinbooke")
        #expect(SyncNormalization.normalizedKey("GRDB") == "grdb")
        #expect(SyncNormalization.normalizedKey("İstanbul") == "i̇stanbul")
    }

    @Test func sameWordGivesSameRecordWhateverTheTyping() {
        let composed = SyncNormalization.normalizedKey("Café")
        let decomposed = SyncNormalization.normalizedKey("Cafe\u{301}")
        #expect(SyncRecordID.dictionaryEntry(normalizedSource: composed) == SyncRecordID.dictionaryEntry(normalizedSource: decomposed))
        #expect(SyncRecordID.dictionaryEntry(normalizedSource: "tolu") != SyncRecordID.dictionaryEntry(normalizedSource: "tolú"))
    }

    @Test func digestIsFrozen() {
        // Changing the digest would give every word a second record.
        #expect(SyncNormalization.digest("orttaai") == "6e1a123b377ba0b325e7ad4382459caac0421e81f879a4d47a99cb4c7fbe99ab")
        #expect(SyncRecordID.dictionaryEntry(normalizedSource: "orttaai").recordName == "dict.6e1a123b377ba0b325e7ad4382459caac0421e81f879a4d47a99cb4c7fbe99ab")
    }

    @Test func revisionsOrderByCounterThenClockThenWriter() {
        let early = Date(timeIntervalSince1970: 100)
        let late = Date(timeIntervalSince1970: 200)
        // A higher counter wins even with an older clock: it saw the other.
        #expect(Revision(counter: 2, modifiedAt: early, writerDeviceID: "a") > Revision(counter: 1, modifiedAt: late, writerDeviceID: "b"))
        #expect(Revision(counter: 1, modifiedAt: late, writerDeviceID: "a") > Revision(counter: 1, modifiedAt: early, writerDeviceID: "b"))
        #expect(Revision(counter: 1, modifiedAt: early, writerDeviceID: "b") > Revision(counter: 1, modifiedAt: early, writerDeviceID: "a"))
    }

    @Test func clockMovesPastWhatItSees() {
        var clock = RevisionClock(counter: 3, deviceID: "a")
        clock.observe(Revision(counter: 10, modifiedAt: Date(), writerDeviceID: "b"))
        #expect(clock.next().counter == 11)
        clock.observe(Revision(counter: 2, modifiedAt: Date(), writerDeviceID: "b"))
        #expect(clock.next().counter == 12)
    }

    @Test func payloadDatesSurviveTheRoundTrip() throws {
        let date = SyncDate.rounded(Date())
        let payload = DictationPayload(createdAt: date, text: "Hello there", rawText: "hello there", recordingMs: 1200)
        let decoded = try PayloadCoder.decode(DictationPayload.self, from: PayloadCoder.encode(payload))
        #expect(decoded == payload)
    }

    @Test func wordsCountTheSameEverywhere() {
        #expect(WordCount.of("Hello there,  world\nagain") == 4)
        #expect(WordCount.of("   ") == 0)
    }

    @Test func preferencesMergeKeyByKey() {
        let old = Revision(counter: 1, modifiedAt: Date(timeIntervalSince1970: 1), writerDeviceID: "a")
        let new = Revision(counter: 2, modifiedAt: Date(timeIntervalSince1970: 2), writerDeviceID: "b")
        let lhs = MacPreferencesPayload(entries: ["a": .init(value: .bool(true), revision: new), "b": .init(value: .int(1), revision: old)])
        let rhs = MacPreferencesPayload(entries: ["a": .init(value: .bool(false), revision: old), "b": .init(value: .int(2), revision: new)])
        let merged = MacPreferencesPayload.merged(lhs, rhs)
        #expect(merged.entries["a"]?.value == .bool(true))
        #expect(merged.entries["b"]?.value == .int(2))
        #expect(MacPreferencesPayload.merged(rhs, lhs) == merged)
    }
}

@Suite("Envelope checks and conflict policy")
struct PolicyTests {
    let device = DeviceID.make()

    func dictation(revision: Int64, deleted: Bool = false, zoneDevice: String? = nil) -> SyncEnvelope {
        let zone = SyncZone.dictations(originDeviceID: zoneDevice ?? device)
        return SyncEnvelope(
            id: .dictation(syncID: "one", zone: zone),
            revision: Revision(counter: revision, modifiedAt: Date(timeIntervalSince1970: Double(revision)), writerDeviceID: device),
            isDeleted: deleted,
            payload: deleted ? nil : try! PayloadCoder.encode(DictationPayload(createdAt: Date(timeIntervalSince1970: 1), text: "Hello")),
            origin: DictationOrigin(deviceID: device, kind: .iphone)
        )
    }

    @Test func anUnreadablePayloadIsCaughtBeforeApplying() {
        var envelope = dictation(revision: 1)
        envelope.payload = Data("{\"not\": \"a dictation\"}".utf8)
        #expect(envelope.problem == .undecodablePayload)
    }

    @Test func envelopesAreChecked() {
        #expect(dictation(revision: 1).problem == nil)
        #expect(dictation(revision: 1, zoneDevice: DeviceID.make()).problem == .originZoneMismatch)
        var withText = dictation(revision: 1, deleted: true)
        withText.payload = Data("{}".utf8)
        #expect(withText.problem == .deletedWithPayload)
        var future = dictation(revision: 1)
        future.schemaVersion = 99
        #expect(future.problem == .unsupportedSchemaVersion(99))
        #expect(future.problem?.mayResolveAfterUpdate == true)
        var huge = dictation(revision: 1)
        huge.payload = Data(count: SyncEnvelope.maximumPayloadBytes + 1)
        #expect(huge.problem == .payloadTooLarge(SyncEnvelope.maximumPayloadBytes + 1))
        var noOrigin = dictation(revision: 1)
        noOrigin.origin = nil
        #expect(noOrigin.problem == .missingOrigin)
    }

    @Test func newerRevisionWins() {
        let local = LocalRecordState(revision: dictation(revision: 2).revision, isDeleted: false)
        #expect(ConflictPolicy.decide(local: local, remote: dictation(revision: 3)) == .acceptRemote)
        #expect(ConflictPolicy.decide(local: local, remote: dictation(revision: 1)) == .keepLocal)
        #expect(ConflictPolicy.decide(local: local, remote: dictation(revision: 2)) == .alreadyCurrent)
        #expect(ConflictPolicy.decide(local: nil, remote: dictation(revision: 1)) == .acceptRemote)
    }

    @Test func aDeletedDictationNeverComesBack() {
        let deletedLocally = LocalRecordState(revision: dictation(revision: 1).revision, isDeleted: true)
        #expect(ConflictPolicy.decide(local: deletedLocally, remote: dictation(revision: 99)) == .keepLocal)
        let live = LocalRecordState(revision: dictation(revision: 99).revision, isDeleted: false)
        #expect(ConflictPolicy.decide(local: live, remote: dictation(revision: 1, deleted: true)) == .acceptRemote)
        #expect(ConflictPolicy.decide(local: deletedLocally, remote: dictation(revision: 5, deleted: true)) == .alreadyCurrent)
    }

    @Test func aStaleEditCantReviveADeletedWordButAReAddCan() {
        let id = SyncRecordID.dictionaryEntry(normalizedSource: "tolu")
        func word(_ counter: Int64, generation: Int64, deleted: Bool) -> SyncEnvelope {
            SyncEnvelope(
                id: id,
                revision: Revision(counter: counter, modifiedAt: Date(timeIntervalSince1970: Double(counter)), writerDeviceID: "a"),
                generation: generation,
                isDeleted: deleted,
                payload: deleted ? nil : Data("{}".utf8)
            )
        }
        let tombstone = LocalRecordState(revision: word(5, generation: 0, deleted: true).revision, isDeleted: true, generation: 0)
        // An offline device's edit, far ahead in counter, same life: loses.
        #expect(ConflictPolicy.decide(local: tombstone, remote: word(500, generation: 0, deleted: false)) == .keepLocal)
        // An explicit re-add starts the next life: wins.
        #expect(ConflictPolicy.decide(local: tombstone, remote: word(6, generation: 1, deleted: false)) == .acceptRemote)
        // And a stale tombstone from the earlier life can't delete it again.
        let readded = LocalRecordState(revision: word(6, generation: 1, deleted: false).revision, isDeleted: false, generation: 1)
        #expect(ConflictPolicy.decide(local: readded, remote: word(900, generation: 0, deleted: true)) == .keepLocal)
    }

    @Test func aDeletedWordComesBackOnlyWithANewerRevision() {
        let id = SyncRecordID.dictionaryEntry(normalizedSource: "tolu")
        func word(_ counter: Int64, deleted: Bool) -> SyncEnvelope {
            SyncEnvelope(
                id: id,
                revision: Revision(counter: counter, modifiedAt: Date(timeIntervalSince1970: Double(counter)), writerDeviceID: "a"),
                isDeleted: deleted,
                payload: deleted ? nil : Data("{}".utf8)
            )
        }
        let tombstone = LocalRecordState(revision: word(5, deleted: true).revision, isDeleted: true)
        #expect(ConflictPolicy.decide(local: tombstone, remote: word(4, deleted: false)) == .keepLocal)
        // Same life: a delete beats an edit, whatever the revision.
        #expect(ConflictPolicy.decide(local: tombstone, remote: word(6, deleted: false)) == .keepLocal)
    }
}

@Suite("Coach in the Mac's summary")
struct CoachDigestTests {
    private func summary(coach: CoachDigestPayload?) -> MacSummaryPayload {
        MacSummaryPayload(
            publisherDeviceID: DeviceID.make(), publisherName: "Mac", asOf: Date(timeIntervalSince1970: 1_800_000_000),
            timeZoneIdentifier: "UTC", coverage: [:], totals: DeviceTotals(), perDevice: [:], recentDays: [], topApps: [],
            coach: coach
        )
    }

    @Test func aSummaryCarriesCoachBothWays() throws {
        let coach = CoachDigestPayload(
            shapes: [.init(mode: "Talking to AI", dictations: 42, axes: [.init(title: "Clarity", now: 0.7, before: 0.5)])],
            habits: [.init(title: "Fewer ums", mode: nil, status: .working, since: 20, window: 20, beforeShare: 0.4, sinceShare: 0.7)],
            tracks: [.init(title: "Prompting AI", level: 2, mastered: 1, skills: 6, current: "Give the context it needs")],
            repsThisWeek: 3
        )
        let decoded = try PayloadCoder.decode(MacSummaryPayload.self, from: try PayloadCoder.encode(summary(coach: coach)))
        #expect(decoded.coach == coach)
    }

    @Test func aSummaryFromBeforeCoachStillDecodes() throws {
        // What a Mac without Coach sends: no coach key at all.
        var json = try JSONSerialization.jsonObject(with: try PayloadCoder.encode(summary(coach: nil))) as! [String: Any]
        json.removeValue(forKey: "coach")
        let decoded = try PayloadCoder.decode(MacSummaryPayload.self, from: try JSONSerialization.data(withJSONObject: json))
        #expect(decoded.coach == nil)
        #expect(decoded.publisherName == "Mac")
    }
}
