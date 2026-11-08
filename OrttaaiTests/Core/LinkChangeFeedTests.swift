// LinkChangeFeedTests.swift
// OrttaaiTests
//
// The change feed Orttaai Link serves linked devices from: every change to a
// sync record gets the next number, whichever path made it, and saving
// CloudKit's bookkeeping doesn't count as a change.

import GRDB
import OrttaaiSyncCore
import XCTest
@testable import Orttaai

final class LinkChangeFeedTests: XCTestCase {
    private var queue: DatabaseQueue!
    private var db: DatabaseManager!
    private var store: MacSyncStore!
    private let linuxID = "2f0c8a4e-7d21-4b9a-a3f6-5e8d9c1b0a42"

    override func setUpWithError() throws {
        queue = try DatabaseQueue(path: ":memory:")
        db = try DatabaseManager(dbQueue: queue)
        store = MacSyncStore(dbQueue: queue, device: SyncDeviceInfo(deviceID: DeviceIdentity.currentID, name: "Test Mac"))
    }

    override func tearDownWithError() throws {
        store = nil
        db = nil
        queue = nil
    }

    private func latest() throws -> Int64 { try queue.read { try SyncSchema.latestChange(in: $0) } }

    private func changes(after cursor: Int64) throws -> [String] {
        try queue.read { try SyncSchema.changes(after: cursor, limit: 100, in: $0).map(\.recordName) }
    }

    private func syncID(ofTranscription id: Int64) throws -> String {
        try queue.read { try String.fetchOne($0, sql: "SELECT syncID FROM transcription WHERE id = ?", arguments: [id])! }
    }

    private func linuxDictation(_ syncID: String, text: String, counter: Int64, deleted: Bool = false) throws -> InboundRecord {
        let envelope = SyncEnvelope(
            id: .dictation(syncID: syncID, zone: .dictations(originDeviceID: linuxID)),
            revision: Revision(counter: counter, modifiedAt: SyncDate.rounded(Date()), writerDeviceID: linuxID),
            isDeleted: deleted,
            deletedAt: deleted ? SyncDate.rounded(Date()) : nil,
            payload: deleted ? nil : try PayloadCoder.encode(DictationPayload(createdAt: SyncDate.rounded(Date()), text: text, targetAppName: "Claude Code", recordingMs: 2_000)),
            origin: DictationOrigin(deviceID: linuxID, kind: .linux)
        )
        return InboundRecord(envelope: envelope, systemFields: nil)
    }

    func testALocalDictationIsTheNextChange() throws {
        let start = try latest()
        let id = try db.saveTranscription(text: "Hello from the Mac", appName: "Notes", recordingMs: 1_000, processingMs: 200, modelId: "m")
        let name = "dictation.\(try syncID(ofTranscription: id))"
        XCTAssertEqual(try changes(after: start), [name])
        XCTAssertGreaterThan(try latest(), start)
        XCTAssertEqual(try changes(after: try latest()), [])
    }

    func testSavingCloudKitFieldsIsNotAChange() throws {
        let entry = try db.upsertDictionaryEntry(source: "Orttaai", target: "Orttaai")
        XCTAssertNotNil(entry.id)
        let id = SyncRecordID.dictionaryEntry(normalizedSource: "orttaai")
        let sent = try XCTUnwrap(try store.outgoingRecord(for: id))
        let before = try latest()
        try store.acknowledge([SendAck(id: id, revision: sent.envelope.revision, systemFields: Data("tag".utf8))])
        XCTAssertEqual(try latest(), before)
        XCTAssertEqual(try changes(after: before), [])
    }

    func testRecordsFromOtherDevicesAndTheirDeletionsAreChanges() throws {
        let start = try latest()
        _ = try store.applyInbound([try linuxDictation("l1", text: "Said on Linux", counter: 3)], decide: ConflictPolicy.decide)
        let afterArrival = try latest()
        XCTAssertEqual(try changes(after: start), ["dictation.l1"])

        _ = try store.applyInbound([try linuxDictation("l1", text: "", counter: 4, deleted: true)], decide: ConflictPolicy.decide)
        XCTAssertEqual(try changes(after: afterArrival), ["dictation.l1"])
        let tombstone = try queue.read { try Row.fetchOne($0, sql: "SELECT isDeleted FROM sync_record WHERE recordName = 'dictation.l1'") }
        XCTAssertEqual(tombstone?["isDeleted"] as Bool?, true)
    }

    func testTheFeedIsInChangeOrderAndPages() throws {
        let start = try latest()
        for n in 1...5 {
            _ = try db.saveTranscription(text: "Dictation \(n)", appName: nil, recordingMs: 1_000, processingMs: 100, modelId: "m")
        }
        let all = try changes(after: start)
        XCTAssertEqual(all.count, 5)
        let firstPage = try queue.read { try SyncSchema.changes(after: start, limit: 2, in: $0) }
        XCTAssertEqual(firstPage.map(\.recordName), Array(all.prefix(2)))
        let rest = try changes(after: try XCTUnwrap(firstPage.last?.changeSeq))
        XCTAssertEqual(rest, Array(all.dropFirst(2)))
    }

    func testAnEditMovesARecordToTheEnd() throws {
        let entry = try db.upsertDictionaryEntry(source: "Lagos", target: "Lagos")
        _ = try db.saveTranscription(text: "After the word", appName: nil, recordingMs: 1_000, processingMs: 100, modelId: "m")
        let before = try latest()
        _ = try db.updateDictionaryEntry(id: try XCTUnwrap(entry.id), source: "Lagos", target: "LAGOS", isCaseSensitive: false, isActive: true)
        XCTAssertEqual(try changes(after: before), [SyncRecordID.dictionaryEntry(normalizedSource: "lagos").recordName])
    }
}
