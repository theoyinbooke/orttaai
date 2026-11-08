// LinkRelayTests.swift
// OrttaaiTests
//
// What Orttaai Link does with records from linked devices on this Mac: they
// land in the archive like a phone's, are queued for iCloud at the device's
// own revision, and come back to devices through the change feed.

import GRDB
import OrttaaiLink
import OrttaaiSyncCore
import XCTest
@testable import Orttaai

final class LinkRelayTests: XCTestCase {
    private var queue: DatabaseQueue!
    private var db: DatabaseManager!
    private var host: MacLinkHost!
    private let linuxID = "2f0c8a4e-7d21-4b9a-a3f6-5e8d9c1b0a42"
    private let androidID = "c47b2e90-5a13-4d6e-9f08-71e3a5d2b6c4"
    private let now = SyncDate.rounded(Date())

    override func setUpWithError() throws {
        queue = try DatabaseQueue(path: ":memory:")
        db = try DatabaseManager(dbQueue: queue)
        host = MacLinkHost(dbQueue: queue, device: SyncDeviceInfo(deviceID: DeviceIdentity.currentID, name: "Test Mac"))
    }

    override func tearDownWithError() throws {
        host = nil
        db = nil
        queue = nil
    }

    private func device(_ id: String, _ kind: DeviceKind) -> LinkedDevice {
        try! JSONDecoder.iso.decode(LinkedDevice.self, from: Data("""
        {"id":"\(id)","kind":"\(kind.rawValue)","name":"\(kind.displayName)","app":"Orttaai","linkedAt":"2026-11-08T00:00:00Z","viaTailnet":false,"tokenHash":""}
        """.utf8))
    }

    private func linuxDictation(_ syncID: String, text: String, counter: Int64) throws -> SyncEnvelope {
        SyncEnvelope(
            id: .dictation(syncID: syncID, zone: .dictations(originDeviceID: linuxID)),
            revision: Revision(counter: counter, modifiedAt: now, writerDeviceID: linuxID),
            payload: try PayloadCoder.encode(DictationPayload(createdAt: now, text: text, targetAppName: "Claude Code", recordingMs: 2_500)),
            origin: DictationOrigin(deviceID: linuxID, kind: .linux),
            createdAt: now
        )
    }

    private func outbox() throws -> [String: Int64] {
        try queue.read { db in
            Dictionary(uniqueKeysWithValues: try Row.fetchAll(db, sql: "SELECT recordName, revCounter FROM sync_outbox").map { ($0["recordName"], $0["revCounter"]) })
        }
    }

    func testALinuxDictationLandsLabelledAndIsQueuedForICloud() async throws {
        let record = try linuxDictation("l1", text: "Ship it on Friday", counter: 7)
        let outcome = try await host.apply([record], from: device(linuxID, .linux))
        XCTAssertEqual(outcome.accepted[record.id], record.revision)
        XCTAssertTrue(outcome.newer.isEmpty)

        let row = try XCTUnwrap(try db.fetchRecent().first)
        XCTAssertEqual(row.text, "Ship it on Friday")
        XCTAssertEqual(row.sourceDeviceID, linuxID)
        XCTAssertEqual(row.sourceDeviceKind, "linux")
        XCTAssertEqual(row.targetAppName, "Claude Code")
        XCTAssertEqual(try outbox()["dictation.l1"], 7)

        // And it goes to iCloud as the device wrote it, in the device's zone.
        let store = MacSyncStore(dbQueue: queue, device: SyncDeviceInfo(deviceID: DeviceIdentity.currentID, name: "Test Mac"))
        let outgoing = try XCTUnwrap(try store.outgoingRecord(for: record.id))
        XCTAssertEqual(outgoing.envelope.revision, record.revision)
        XCTAssertEqual(outgoing.envelope.origin, record.origin)
        XCTAssertEqual(outgoing.envelope.schemaVersion, 2)
        XCTAssertNil(outgoing.envelope.problem)
        XCTAssertEqual(try PayloadCoder.decode(DictationPayload.self, from: try XCTUnwrap(outgoing.envelope.payload)).text, "Ship it on Friday")
    }

    func testAStaleEditGetsThisMacsNewerVersion() async throws {
        let entry = try db.upsertDictionaryEntry(source: "Lagos", target: "Lagos")
        XCTAssertNotNil(entry.id)
        let id = SyncRecordID.dictionaryEntry(normalizedSource: "lagos")
        let stale = SyncEnvelope(
            id: id, revision: Revision(counter: 0, modifiedAt: now.addingTimeInterval(-60), writerDeviceID: linuxID),
            payload: try PayloadCoder.encode(DictionaryEntryPayload(source: "Lagos", target: "LAGOS", createdAt: now))
        )
        let outcome = try await host.apply([stale], from: device(linuxID, .linux))
        XCTAssertTrue(outcome.accepted.isEmpty)
        XCTAssertEqual(outcome.newer.map(\.id), [id])
        XCTAssertEqual(try db.fetchDictionaryEntries().first?.target, "Lagos")
    }

    func testTheFeedGivesAPCEverythingAndAPhoneOnlyWhatItReads() async throws {
        _ = try db.saveTranscription(text: "Said on the Mac", appName: "Notes", recordingMs: 1_000, processingMs: 100, modelId: "m")
        _ = try db.upsertDictionaryEntry(source: "Orttaai", target: "Orttaai")
        _ = try await host.apply([try linuxDictation("l1", text: "From Linux", counter: 3)], from: device(linuxID, .linux))

        let pc = try await host.changes(after: 0, limit: 500, for: device(linuxID, .linux))
        let pcKinds = pc.records.compactMap(\.kind)
        XCTAssertTrue(pcKinds.contains(.dictation))
        XCTAssertTrue(pcKinds.contains(.dictionaryEntry))
        XCTAssertTrue(pc.records.contains { $0.id.recordName == "dictation.l1" })
        XCTAssertFalse(pc.records.contains { $0.kind == .macPreferences || $0.kind == .toneProfile })
        XCTAssertFalse(pc.more)

        let phone = try await host.changes(after: 0, limit: 500, for: device(androidID, .android))
        XCTAssertFalse(phone.records.contains { $0.kind == .dictation }, "a phone never gets other devices' dictations")
        XCTAssertTrue(phone.records.contains { $0.kind == .dictionaryEntry })
        XCTAssertEqual(phone.cursor, pc.cursor)

        // Caught up: nothing after the cursor.
        let after = try await host.changes(after: pc.cursor, limit: 500, for: device(linuxID, .linux))
        XCTAssertTrue(after.records.isEmpty)
    }

    func testALinkedDevicesOwnRecordIsPassedOnAsItCame() async throws {
        let payload = DevicePayload(deviceID: linuxID, kind: .linux, name: "ThinkPad", app: "Orttaai", appVersion: "0.4.0",
                                    firstSeenAt: now, lastSeenAt: now, totals: DeviceTotals(dictations: 12, words: 340))
        let record = SyncEnvelope(id: .device(linuxID), revision: Revision(counter: 2, modifiedAt: now, writerDeviceID: linuxID), payload: try PayloadCoder.encode(payload))
        _ = try await host.apply([record], from: device(linuxID, .linux))

        let store = MacSyncStore(dbQueue: queue, device: SyncDeviceInfo(deviceID: DeviceIdentity.currentID, name: "Test Mac"))
        let outgoing = try XCTUnwrap(try store.outgoingRecord(for: record.id))
        let sent = try PayloadCoder.decode(DevicePayload.self, from: try XCTUnwrap(outgoing.envelope.payload))
        XCTAssertEqual(sent.name, "ThinkPad", "not this Mac's own device record")
        XCTAssertEqual(sent.kind, .linux)
        XCTAssertEqual(outgoing.envelope.schemaVersion, 2)
    }

    func testTotalsCountEachDevicesOwnDictations() async throws {
        _ = try await host.apply([
            try linuxDictation("l1", text: "one two three", counter: 1),
            try linuxDictation("l2", text: "four five", counter: 2),
        ], from: device(linuxID, .linux))
        let totals = try host.deviceTotals([linuxID, androidID])
        XCTAssertEqual(totals[linuxID]?.dictations, 2)
        XCTAssertEqual(totals[linuxID]?.words, 5)
        XCTAssertEqual(totals[androidID]?.dictations, 0)
    }
}

private extension JSONDecoder {
    static let iso: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
