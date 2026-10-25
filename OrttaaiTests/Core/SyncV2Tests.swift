// SyncV2Tests.swift
// OrttaaiTests
//
// iCloud sync v2 on the Mac's database: the migration, the ledger every
// local write goes through, applying records from other devices, and
// acknowledgements. The sync decisions themselves are tested in the
// OrttaaiSync package against a simulated iCloud.

import GRDB
import OrttaaiSyncCore
import XCTest
@testable import Orttaai

final class SyncV2Tests: XCTestCase {
    private var queue: DatabaseQueue!
    private var db: DatabaseManager!
    private var store: MacSyncStore!
    private let phoneID = "6f1c2a4e-0000-4000-8000-00000000abcd"

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

    // MARK: Helpers

    private func syncRecord(_ name: String) throws -> Row? {
        try queue.read { try Row.fetchOne($0, sql: "SELECT * FROM sync_record WHERE recordName = ?", arguments: [name]) }
    }

    private func outbox() throws -> [String: Int64] {
        try queue.read { db in
            var entries: [String: Int64] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT recordName, revCounter FROM sync_outbox") {
                entries[row["recordName"]] = row["revCounter"]
            }
            return entries
        }
    }

    private func syncID(ofTranscription id: Int64) throws -> String {
        try queue.read { try String.fetchOne($0, sql: "SELECT syncID FROM transcription WHERE id = ?", arguments: [id])! }
    }

    private func phoneDictation(_ syncID: String, text: String, counter: Int64 = 5, deleted: Bool = false) throws -> InboundRecord {
        let zone = SyncZone.dictations(originDeviceID: phoneID)
        let envelope = SyncEnvelope(
            id: .dictation(syncID: syncID, zone: zone),
            revision: Revision(counter: counter, modifiedAt: SyncDate.rounded(Date()), writerDeviceID: phoneID),
            isDeleted: deleted,
            payload: deleted ? nil : try PayloadCoder.encode(DictationPayload(createdAt: SyncDate.rounded(Date()), text: text, rawText: text.lowercased(), recordingMs: 2_000, transcriptionMs: 90)),
            origin: DictationOrigin(deviceID: phoneID, kind: .iphone)
        )
        return InboundRecord(envelope: envelope, systemFields: Data("sys".utf8))
    }

    // MARK: Time zones

    func testADictationCarriesTheTimeZoneItWasSaidIn() throws {
        let zone = SyncZone.dictations(originDeviceID: phoneID)
        var payload = DictationPayload(createdAt: SyncDate.rounded(Date()), text: "Said in Tokyo", recordingMs: 2_000)
        payload.timeZoneIdentifier = "Asia/Tokyo"
        let envelope = SyncEnvelope(
            id: .dictation(syncID: "tokyo", zone: zone),
            revision: Revision(counter: 3, modifiedAt: SyncDate.rounded(Date()), writerDeviceID: phoneID),
            payload: try PayloadCoder.encode(payload),
            origin: DictationOrigin(deviceID: phoneID, kind: .iphone)
        )
        _ = try store.applyInbound([InboundRecord(envelope: envelope, systemFields: Data("sys".utf8))], decide: ConflictPolicy.decide)
        XCTAssertEqual(try db.fetchRecent().first { $0.text == "Said in Tokyo" }?.timeZoneIdentifier, "Asia/Tokyo")

        // This Mac's own dictations send where they were said.
        let id = try db.saveTranscription(text: "Said here", appName: nil, recordingMs: 500, processingMs: 50, modelId: "m")
        let mine = SyncRecordID.dictation(syncID: try syncID(ofTranscription: id), zone: .dictations(originDeviceID: DeviceIdentity.currentID))
        let sent = try XCTUnwrap(try store.outgoingRecord(for: mine))
        let sentPayload = try PayloadCoder.decode(DictationPayload.self, from: try XCTUnwrap(sent.envelope.payload))
        XCTAssertEqual(sentPayload.timeZoneIdentifier, TimeZone.current.identifier)
    }

    /// The id saving returns is the new dictation's, not the last row the
    /// sync ledger wrote: the dictation's delivery details are completed on
    /// it afterwards.
    func testSavingReturnsTheNewDictationsID() throws {
        _ = try store.applyInbound([try phoneDictation("p0", text: "From the phone first")], decide: ConflictPolicy.decide)
        _ = try db.saveTranscription(text: "Earlier on the Mac", appName: "Notes", recordingMs: 500, processingMs: 50, modelId: "m")

        let id = try db.saveTranscription(text: "Just said", appName: "Notes", recordingMs: 500, processingMs: 50, modelId: "m")
        try db.completeTranscriptionEntry(id: id, processingMs: 420, latency: DictationLatencyTelemetry(settingsSyncMs: nil, transcriptionMs: 300, textProcessingMs: nil, injectionMs: 20, appActivationMs: nil, clipboardRestoreDelayMs: nil), injectionMethod: "paste")

        let rows = try queue.read { try Row.fetchAll($0, sql: "SELECT text, injectionMethod, processingDurationMs FROM transcription ORDER BY id") }
        XCTAssertEqual(rows.map { $0["text"] as String }, ["From the phone first", "Earlier on the Mac", "Just said"])
        XCTAssertEqual(rows.map { $0["injectionMethod"] as String? }, [nil, nil, "paste"])
        XCTAssertEqual(rows.last?["processingDurationMs"] as Int?, 420)
    }

    // MARK: Suggestions from two Macs

    private func suggestFix(confidence: Double) throws {
        _ = try db.saveLearningSuggestions([
            LearningSuggestionDraft(type: .dictionary, candidateSource: "orta", candidateTarget: "Orttaai", confidence: confidence, evidence: nil),
        ])
    }

    /// The same suggestion as another Mac made it, under its own sync ID.
    private func addOtherMacsCopy(confidence: Double, status: LearningSuggestionStatus = .pending) throws {
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO learning_suggestion (type, candidateSource, candidateTarget, normalizedSource, confidence, status, evidence, createdAt, updatedAt, modifiedAt, syncID)
                SELECT type, candidateSource, candidateTarget, normalizedSource, ?, ?, evidence, createdAt, updatedAt, modifiedAt, 'other-mac-copy'
                FROM learning_suggestion LIMIT 1
                """, arguments: [confidence, status.rawValue])
        }
    }

    func testTheSameSuggestionFromTwoMacsShowsOnce() throws {
        try suggestFix(confidence: 0.6)
        try addOtherMacsCopy(confidence: 0.9)

        let pending = try db.fetchLearningSuggestions(status: .pending)
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending.first?.confidence, 0.9)
        XCTAssertEqual(try db.pendingLearningSuggestionCount(), 1)
    }

    func testDecidingASuggestionDecidesItsCopies() throws {
        try suggestFix(confidence: 0.6)
        try addOtherMacsCopy(confidence: 0.9)
        let id = try XCTUnwrap(try db.fetchLearningSuggestions(status: .pending).first?.id)

        try db.updateLearningSuggestionStatus(id: id, status: .accepted)

        XCTAssertEqual(try db.pendingLearningSuggestionCount(), 0)
        let statuses = try queue.read { try String.fetchAll($0, sql: "SELECT status FROM learning_suggestion") }
        XCTAssertEqual(statuses, ["accepted", "accepted"])
        // Both copies sync their new status.
        XCTAssertEqual(try outbox().keys.filter { $0.hasPrefix("suggestion.") }.count, 2)
    }

    func testASuggestionAnotherMacRejectedIsNoLongerPending() throws {
        try suggestFix(confidence: 0.6)
        try addOtherMacsCopy(confidence: 0.6, status: .rejected)

        XCTAssertTrue(try db.fetchLearningSuggestions(status: .pending).isEmpty)
        XCTAssertEqual(try db.pendingLearningSuggestionCount(), 0)
    }

    // MARK: Ledger

    func testSavingADictationRecordsItForSync() throws {
        let id = try db.saveTranscription(text: "Hello from the Mac", appName: "Notes", recordingMs: 1_000, processingMs: 200, modelId: "m")
        let name = "dictation.\(try syncID(ofTranscription: id))"
        let record = try XCTUnwrap(try syncRecord(name))
        XCTAssertEqual(record["zoneName"] as String, "Dictations-\(DeviceIdentity.currentID)")
        XCTAssertEqual(record["originKind"] as String, "mac")
        XCTAssertEqual(record["localID"] as Int64, id)
        XCTAssertEqual(record["isDeleted"] as Bool, false)
        XCTAssertNotNil(try outbox()[name])
        let transcription = try XCTUnwrap(try db.fetchRecent().first)
        XCTAssertEqual(transcription.sourceDeviceKind, "mac")
    }

    func testDeletingKeepsADurableTombstone() throws {
        let id = try db.saveTranscription(text: "Delete me", appName: nil, recordingMs: 1_000, processingMs: 100, modelId: "m")
        let name = "dictation.\(try syncID(ofTranscription: id))"
        let before = try XCTUnwrap(try outbox()[name])
        XCTAssertTrue(try db.deleteTranscription(id: id))
        let record = try XCTUnwrap(try syncRecord(name))
        XCTAssertEqual(record["isDeleted"] as Bool, true)
        XCTAssertNil(record["localID"] as Int64?)
        XCTAssertGreaterThan(try XCTUnwrap(try outbox()[name]), before)
        let outgoing = try XCTUnwrap(try store.outgoingRecord(for: SyncRecordID(zone: .dictations(originDeviceID: DeviceIdentity.currentID), recordName: name)))
        XCTAssertTrue(outgoing.envelope.isDeleted)
        XCTAssertNil(outgoing.envelope.payload)
        XCTAssertNil(outgoing.envelope.problem)
    }

    func testUsageCountsNeverSync() throws {
        let entry = try db.upsertDictionaryEntry(source: "Tolu", target: "Tolu")
        let name = SyncRecordID.dictionaryEntry(normalizedSource: "tolu").recordName
        let revision = try XCTUnwrap(try outbox()[name])
        try db.incrementDictionaryUsage(id: try XCTUnwrap(entry.id))
        try db.incrementDictionaryUsage(id: try XCTUnwrap(entry.id))
        XCTAssertEqual(try outbox()[name], revision)
        let payload = try XCTUnwrap(try store.outgoingRecord(for: .dictionaryEntry(normalizedSource: "tolu"))?.envelope.payload)
        XCTAssertFalse(String(decoding: payload, as: UTF8.self).contains("usage"))
    }

    func testRenamingAWordTombstonesTheOldRecord() throws {
        let entry = try db.upsertDictionaryEntry(source: "Orttakee", target: "Orttakey")
        _ = try db.updateDictionaryEntry(id: try XCTUnwrap(entry.id), source: "Ortakey", target: "Orttakey", isCaseSensitive: false, isActive: true)
        let old = try XCTUnwrap(try syncRecord(SyncRecordID.dictionaryEntry(normalizedSource: "orttakee").recordName))
        let new = try XCTUnwrap(try syncRecord(SyncRecordID.dictionaryEntry(normalizedSource: "ortakey").recordName))
        XCTAssertEqual(old["isDeleted"] as Bool, true)
        XCTAssertEqual(new["isDeleted"] as Bool, false)
        XCTAssertEqual(new["localID"] as Int64, entry.id)
    }

    func testRevisionsKeepClimbing() throws {
        let first = try db.upsertDictionaryEntry(source: "Lagos", target: "Lagos")
        let name = SyncRecordID.dictionaryEntry(normalizedSource: "lagos").recordName
        let r1 = try XCTUnwrap(try outbox()[name])
        _ = try db.updateDictionaryEntry(id: try XCTUnwrap(first.id), source: "Lagos", target: "LAGOS", isCaseSensitive: false, isActive: true)
        XCTAssertGreaterThan(try XCTUnwrap(try outbox()[name]), r1)
    }

    // MARK: Migration

    func testMigrationBackfillsExistingRowsWithoutClaimingThem() throws {
        let legacyQueue = try DatabaseQueue(path: ":memory:")
        try DatabaseManager.schemaMigrator.migrate(legacyQueue, upTo: "v18_raw_transcript")
        let otherMac = "11111111-2222-4333-8444-555555555555"
        try legacyQueue.write { db in
            for (index, source) in [String?.none, otherMac, DeviceIdentity.currentID].enumerated() {
                try db.execute(sql: """
                    INSERT INTO transcription (createdAt, text, recordingDurationMs, processingDurationMs, modelId, sourceDeviceID, syncID, modifiedAt)
                    VALUES (?, ?, 1000, 100, 'm', ?, ?, ?)
                    """, arguments: [Date(), "Row \(index)", source, "legacy-\(index)", Date()])
            }
            try db.execute(sql: """
                INSERT INTO dictionary_entry (source, target, normalizedSource, isCaseSensitive, isActive, usageCount, createdAt, updatedAt, syncID, modifiedAt)
                VALUES ('GRDB', 'GRDB', 'grdb', 0, 1, 7, ?, ?, 'old-sync-id', ?)
                """, arguments: [Date(), Date(), Date()])
        }
        _ = try DatabaseManager(dbQueue: legacyQueue)

        try legacyQueue.read { db in
            let zones = try Row.fetchAll(db, sql: "SELECT recordName, zoneName, originKind, revCounter FROM sync_record WHERE kind = 'Dictation' ORDER BY recordName")
            XCTAssertEqual(zones.map { $0["zoneName"] as String }, [
                "Dictations-legacy",
                "Dictations-\(otherMac)",
                "Dictations-\(DeviceIdentity.currentID)",
            ])
            XCTAssertEqual(zones.map { $0["originKind"] as String }, ["unknown", "mac", "mac"])
            XCTAssertTrue(zones.allSatisfy { $0["revCounter"] as Int64 == 0 })
            let kinds = try String.fetchAll(db, sql: "SELECT sourceDeviceKind FROM transcription ORDER BY syncID")
            XCTAssertEqual(kinds, ["unknown", "mac", "mac"])
            let word = try Row.fetchOne(db, sql: "SELECT * FROM sync_record WHERE kind = 'DictionaryEntry'")
            XCTAssertEqual(word?["recordName"] as String?, SyncRecordID.dictionaryEntry(normalizedSource: "grdb").recordName)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sync_outbox"), 4)
        }
    }

    // MARK: Applying remote records

    func testAPhoneDictationArrivesWithoutBeingSentBack() throws {
        let result = try store.applyInbound([try phoneDictation("p1", text: "Said on the phone")], decide: ConflictPolicy.decide)
        XCTAssertEqual(result.changed.count, 1)
        let row = try XCTUnwrap(try db.fetchRecent().first)
        XCTAssertEqual(row.text, "Said on the phone")
        XCTAssertEqual(row.sourceDeviceID, phoneID)
        XCTAssertEqual(row.sourceDeviceKind, "iphone")
        XCTAssertEqual(row.displayAppName, "Orttakey on iPhone")
        XCTAssertEqual(row.distinctRawText, "said on the phone")
        XCTAssertTrue(try outbox().isEmpty)
        XCTAssertEqual(try db.semanticIndexQueueCount(), 1)
        XCTAssertEqual(try syncRecord("dictation.p1")?["systemFields"] as Data?, Data("sys".utf8))
    }

    func testAnUpdateKeepsTheLocalIDAndADeletionRemovesTheRow() throws {
        _ = try store.applyInbound([try phoneDictation("p2", text: "First")], decide: ConflictPolicy.decide)
        let id = try XCTUnwrap(try db.fetchRecent().first?.id)
        _ = try store.applyInbound([try phoneDictation("p2", text: "Second", counter: 6)], decide: ConflictPolicy.decide)
        XCTAssertEqual(try db.fetchRecent().first?.id, id)
        XCTAssertEqual(try db.fetchRecent().first?.text, "Second")

        _ = try store.applyInbound([try phoneDictation("p2", text: "", counter: 7, deleted: true)], decide: ConflictPolicy.decide)
        XCTAssertTrue(try db.fetchRecent().isEmpty)
        XCTAssertEqual(try syncRecord("dictation.p2")?["isDeleted"] as Bool?, true)
        // A stale copy arriving later never brings it back.
        _ = try store.applyInbound([try phoneDictation("p2", text: "Zombie", counter: 99)], decide: ConflictPolicy.decide)
        XCTAssertTrue(try db.fetchRecent().isEmpty)
        XCTAssertNotNil(try outbox()["dictation.p2"])
    }

    func testARemoteWordFoldsIntoTheLocalRowAndKeepsItsUsage() throws {
        let local = try db.upsertDictionaryEntry(source: "Swift UI", target: "SwiftUI")
        try db.incrementDictionaryUsage(id: try XCTUnwrap(local.id))
        let id = SyncRecordID.dictionaryEntry(normalizedSource: "swift ui")
        let remote = SyncEnvelope(
            id: id,
            revision: Revision(counter: 50, modifiedAt: SyncDate.rounded(Date()), writerDeviceID: phoneID),
            payload: try PayloadCoder.encode(DictionaryEntryPayload(source: "swift ui", target: "SwiftUI!", createdAt: Date()))
        )
        _ = try store.applyInbound([InboundRecord(envelope: remote, systemFields: nil)], decide: ConflictPolicy.decide)
        let entries = try db.fetchDictionaryEntries()
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.target, "SwiftUI!")
        XCTAssertEqual(entries.first?.usageCount, 1)
        XCTAssertEqual(entries.first?.id, local.id)
    }

    func testOnlyTheAcknowledgedRevisionLeavesTheOutbox() throws {
        let entry = try db.upsertDictionaryEntry(source: "CloudKit", target: "CloudKit")
        let id = SyncRecordID.dictionaryEntry(normalizedSource: "cloudkit")
        let sent = try XCTUnwrap(try store.outgoingRecord(for: id))
        _ = try db.updateDictionaryEntry(id: try XCTUnwrap(entry.id), source: "CloudKit", target: "CLOUDKIT", isCaseSensitive: false, isActive: true)
        try store.acknowledge([SendAck(id: id, revision: sent.envelope.revision, systemFields: Data("tag".utf8))])
        XCTAssertNotNil(try outbox()[id.recordName])
        let newer = try XCTUnwrap(try store.outgoingRecord(for: id))
        try store.acknowledge([SendAck(id: id, revision: newer.envelope.revision, systemFields: Data("tag2".utf8))])
        XCTAssertNil(try outbox()[id.recordName])
        XCTAssertEqual(try syncRecord(id.recordName)?["systemFields"] as Data?, Data("tag2".utf8))
    }

    func testTwoMacsConverge() throws {
        let otherQueue = try DatabaseQueue(path: ":memory:")
        _ = try DatabaseManager(dbQueue: otherQueue)
        let other = MacSyncStore(dbQueue: otherQueue, device: SyncDeviceInfo(deviceID: "99999999-2222-4333-8444-555555555555", name: "Other"))

        let id = try db.saveTranscription(text: "Shared across Macs", appName: "Xcode", recordingMs: 1_500, processingMs: 300, modelId: "m")
        let recordID = SyncRecordID.dictation(syncID: try syncID(ofTranscription: id), zone: .dictations(originDeviceID: DeviceIdentity.currentID))
        let outgoing = try XCTUnwrap(try store.outgoingRecord(for: recordID))
        _ = try other.applyInbound([InboundRecord(envelope: outgoing.envelope, systemFields: nil)], decide: ConflictPolicy.decide)
        let otherDB = try DatabaseManager(dbQueue: otherQueue)
        XCTAssertEqual(try otherDB.fetchRecent().first?.text, "Shared across Macs")
        XCTAssertEqual(try otherDB.fetchRecent().first?.targetAppName, "Xcode")

        // The other Mac deletes it; this Mac follows.
        XCTAssertTrue(try otherDB.deleteTranscription(id: try XCTUnwrap(try otherDB.fetchRecent().first?.id)))
        let tombstone = try XCTUnwrap(try other.outgoingRecord(for: recordID))
        XCTAssertTrue(tombstone.envelope.isDeleted)
        _ = try store.applyInbound([InboundRecord(envelope: tombstone.envelope, systemFields: nil)], decide: ConflictPolicy.decide)
        XCTAssertTrue(try db.fetchRecent().isEmpty)
    }

    func testSettingsMergeKeyByKey() throws {
        let older = Revision(counter: 1, modifiedAt: Date(timeIntervalSince1970: 1), writerDeviceID: "a")
        let newer = Revision(counter: 9, modifiedAt: Date(timeIntervalSince1970: 9), writerDeviceID: "b")
        try queue.write { db in
            try SyncLedger.noteRecordChange(in: db, recordID: .macPreferences, payload: try PayloadCoder.encode(MacPreferencesPayload(entries: [
                "snippetsEnabled": .init(value: .bool(true), revision: newer),
                "dictationLanguage": .init(value: .string("en"), revision: older),
            ])))
        }
        let remote = SyncEnvelope(
            id: .macPreferences,
            revision: Revision(counter: 20, modifiedAt: SyncDate.rounded(Date()), writerDeviceID: "b"),
            payload: try PayloadCoder.encode(MacPreferencesPayload(entries: [
                "snippetsEnabled": .init(value: .bool(false), revision: older),
                "dictationLanguage": .init(value: .string("fr"), revision: newer),
            ]))
        )
        let result = try store.applyInbound([InboundRecord(envelope: remote, systemFields: nil)], decide: ConflictPolicy.decide)
        XCTAssertEqual(result.needsSend, [.macPreferences])
        let merged = try XCTUnwrap(try store.outgoingRecord(for: .macPreferences)?.envelope.payload)
        let entries = try PayloadCoder.decode(MacPreferencesPayload.self, from: merged).entries
        XCTAssertEqual(entries["snippetsEnabled"]?.value, .bool(true))
        XCTAssertEqual(entries["dictationLanguage"]?.value, .string("fr"))
    }

    func testTheSummaryCountsEveryDeviceOnce() throws {
        _ = try db.saveTranscription(text: "one two three", appName: "Notes", recordingMs: 1_000, processingMs: 100, modelId: "m")
        _ = try store.applyInbound([try phoneDictation("p3", text: "four five")], decide: ConflictPolicy.decide)
        try queue.write { db in
            try SyncLedger.noteRecordChange(in: db, recordID: .macSummary(macDeviceID: DeviceIdentity.currentID), payload: Data("{}".utf8))
        }
        let data = try XCTUnwrap(try store.outgoingRecord(for: .macSummary(macDeviceID: DeviceIdentity.currentID))?.envelope.payload)
        let summary = try PayloadCoder.decode(MacSummaryPayload.self, from: data)
        XCTAssertEqual(summary.totals.dictations, 2)
        XCTAssertEqual(summary.totals.words, 5)
        XCTAssertEqual(summary.perDevice[phoneID]?.dictations, 1)
        XCTAssertEqual(summary.perDevice[DeviceIdentity.currentID]?.words, 3)
        XCTAssertEqual(summary.recentDays.count, 30)
        XCTAssertEqual(summary.coverage["Dictations-\(phoneID)"], 1)
    }

    func testOlderMacDataNeverRetiresAnUploadOrBlanksCloudKitFields() throws {
        // A dictation iCloud has confirmed, and one still waiting to go.
        let confirmedID = try db.saveTranscription(text: "Confirmed", appName: nil, recordingMs: 500, processingMs: 50, modelId: "m")
        let pendingID = try db.saveTranscription(text: "Pending", appName: nil, recordingMs: 500, processingMs: 50, modelId: "m")
        let zone = SyncZone.dictations(originDeviceID: DeviceIdentity.currentID)
        let confirmed = SyncRecordID.dictation(syncID: try syncID(ofTranscription: confirmedID), zone: zone)
        let pending = SyncRecordID.dictation(syncID: try syncID(ofTranscription: pendingID), zone: zone)
        let sent = try XCTUnwrap(try store.outgoingRecord(for: confirmed))
        try store.acknowledge([SendAck(id: confirmed, revision: sent.envelope.revision, systemFields: Data("tag".utf8))])

        // The same two, as v1 copies an older Mac wrote earlier, imported twice.
        func legacy(_ id: SyncRecordID, _ text: String) throws -> SyncEnvelope {
            SyncEnvelope(
                id: id,
                revision: Revision(counter: 0, modifiedAt: Date(timeIntervalSince1970: 1), writerDeviceID: LegacySyncBridge.legacyWriter),
                payload: try PayloadCoder.encode(DictationPayload(createdAt: Date(timeIntervalSince1970: 1), text: text)),
                origin: DictationOrigin(deviceID: DeviceIdentity.currentID, kind: .mac)
            )
        }
        for _ in 0..<2 {
            XCTAssertTrue(try store.importLegacy([try legacy(confirmed, "Old"), try legacy(pending, "Old")]).isEmpty)
        }
        XCTAssertEqual(try syncRecord(confirmed.recordName)?["systemFields"] as Data?, Data("tag".utf8))
        XCTAssertNotNil(try outbox()[pending.recordName])
        XCTAssertEqual(try db.fetchRecent().map(\.text).sorted(), ["Confirmed", "Pending"])

        // A v1 record newer than this Mac's pre-migration copy (revision 0) is
        // adopted and queued, and a second import of it changes nothing. A
        // change made under v2 is never overridden by v1 data (counter > 0).
        try queue.write { db in
            try db.execute(sql: "UPDATE sync_record SET revCounter = 0, revModifiedAtMs = ? WHERE recordName = ?", arguments: [SyncSchema.milliseconds(Date()), confirmed.recordName])
        }
        let newer = SyncEnvelope(
            id: confirmed,
            // Rounded to the millisecond as LegacySyncBridge rounds it: the
            // stored copy is, and an unrounded date would compare newer than
            // itself and be adopted again.
            revision: Revision(counter: 0, modifiedAt: SyncDate.rounded(Date().addingTimeInterval(3_600)), writerDeviceID: LegacySyncBridge.legacyWriter),
            payload: try PayloadCoder.encode(DictationPayload(createdAt: Date(), text: "Edited on an older Mac")),
            origin: DictationOrigin(deviceID: DeviceIdentity.currentID, kind: .mac)
        )
        XCTAssertEqual(try store.importLegacy([newer]), [confirmed])
        XCTAssertNotNil(try outbox()[confirmed.recordName])
        XCTAssertEqual(try syncRecord(confirmed.recordName)?["systemFields"] as Data?, Data("tag".utf8))
        XCTAssertTrue(try store.importLegacy([newer]).isEmpty)
        XCTAssertTrue(try db.fetchRecent().contains { $0.text == "Edited on an older Mac" })
    }

    func testRecordsICloudNeverConfirmedAreQueuedAgain() throws {
        _ = try db.saveTranscription(text: "Stranded", appName: nil, recordingMs: 500, processingMs: 50, modelId: "m")
        try queue.write { try $0.execute(sql: "DELETE FROM sync_outbox") }
        XCTAssertTrue(try outbox().isEmpty)
        XCTAssertEqual(try store.enqueueUnconfirmed(), 1)
        XCTAssertEqual(try outbox().count, 1)
        XCTAssertEqual(try store.enqueueUnconfirmed(), 0)
    }

    // MARK: Review fixes

    func testV1DeletionsBecomeDurableTombstones() throws {
        let legacyQueue = try DatabaseQueue(path: ":memory:")
        try DatabaseManager.schemaMigrator.migrate(legacyQueue, upTo: "v18_raw_transcript")
        try legacyQueue.write { db in
            try db.execute(sql: "INSERT INTO cloud_sync_tombstone (tableName, syncID, deletedAt, needsCloudSync) VALUES ('transcription', 'gone-1', ?, 0)", arguments: [Date()])
        }
        _ = try DatabaseManager(dbQueue: legacyQueue)
        let barrierStore = MacSyncStore(dbQueue: legacyQueue, device: SyncDeviceInfo(deviceID: DeviceIdentity.currentID, name: "Mac"))
        let row = try legacyQueue.read { try Row.fetchOne($0, sql: "SELECT * FROM sync_record WHERE recordName = 'dictation.gone-1'") }
        XCTAssertEqual(row?["isDeleted"] as Bool?, true)
        // Another Mac still holding it live can't bring it back here, and the
        // tombstone moves to the zone where that copy lives, to go there too.
        let otherMac = "11111111-2222-4333-8444-555555555555"
        let live = SyncEnvelope(
            id: .dictation(syncID: "gone-1", zone: .dictations(originDeviceID: otherMac)),
            revision: Revision(counter: 40, modifiedAt: SyncDate.rounded(Date()), writerDeviceID: otherMac),
            payload: try PayloadCoder.encode(DictationPayload(createdAt: Date(), text: "Zombie")),
            origin: DictationOrigin(deviceID: otherMac, kind: .mac)
        )
        let result = try barrierStore.applyInbound([InboundRecord(envelope: live, systemFields: Data("s".utf8))], decide: ConflictPolicy.decide)
        XCTAssertEqual(result.needsSend.count, 1)
        let moved = try XCTUnwrap(try barrierStore.outgoingRecord(for: live.id))
        XCTAssertTrue(moved.envelope.isDeleted)
        XCTAssertEqual(try legacyQueue.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM transcription") }, 0)
    }

    func testAWordReAddedInV1IsNotDeletedByItsOldTombstone() throws {
        let local = LocalRecordState(revision: Revision(counter: 0, modifiedAt: Date(timeIntervalSince1970: 200), writerDeviceID: "mac"), isDeleted: false)
        let oldTombstone = SyncEnvelope(
            id: .dictionaryEntry(normalizedSource: "tolu"),
            revision: Revision(counter: 0, modifiedAt: Date(timeIntervalSince1970: 100), writerDeviceID: LegacySyncBridge.legacyWriter),
            isDeleted: true,
            payload: nil
        )
        XCTAssertFalse(MacSyncStore.legacyAdopts(local: local, legacy: oldTombstone))
        var newerTombstone = oldTombstone
        newerTombstone.revision.modifiedAt = Date(timeIntervalSince1970: 300)
        XCTAssertTrue(MacSyncStore.legacyAdopts(local: local, legacy: newerTombstone))
        // A word that started a new life under v2 is never touched by v1.
        let readded = LocalRecordState(revision: Revision(counter: 9, modifiedAt: Date(timeIntervalSince1970: 50), writerDeviceID: "mac"), isDeleted: false, generation: 1)
        XCTAssertFalse(MacSyncStore.legacyAdopts(local: readded, legacy: newerTombstone))
    }

    func testReAddingADeletedWordStartsItsNextLife() throws {
        let entry = try db.upsertDictionaryEntry(source: "Arsenal", target: "Arsenal")
        XCTAssertTrue(try db.deleteDictionaryEntry(id: try XCTUnwrap(entry.id)))
        _ = try db.upsertDictionaryEntry(source: "Arsenal", target: "Arsenal")
        let outgoing = try XCTUnwrap(try store.outgoingRecord(for: .dictionaryEntry(normalizedSource: "arsenal")))
        XCTAssertEqual(outgoing.envelope.generation, 1)
        XCTAssertFalse(outgoing.envelope.isDeleted)
    }

    func testChatsAreOnlyDeletedOnPurpose() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "SyncV2Tests-\(UUID().uuidString)"))
        func chats(_ ids: [UUID]) throws -> Data {
            try JSONSerialization.data(withJSONObject: ids.map { ["id": $0.uuidString, "title": "Chat", "messages": [], "createdAt": 1.0, "updatedAt": 2.0] })
        }
        let kept = UUID()
        let trimmed = UUID()
        let deleted = UUID()
        defaults.set(try chats([kept, trimmed, deleted]), forKey: MacProfileSync.chatsKey)
        let first = try MainActor.assumeIsolated { try MacProfileSync.recordLocalChanges(dbQueue: queue, defaults: defaults) }
        XCTAssertEqual(first.filter { $0.kind == .chatConversation }.count, 3)

        // One trimmed from the list (not deleted), one deleted on purpose.
        defaults.set(try chats([kept]), forKey: MacProfileSync.chatsKey)
        MacProfileSync.noteChatDeleted(deleted, defaults: defaults)
        let second = try MainActor.assumeIsolated { try MacProfileSync.recordLocalChanges(dbQueue: queue, defaults: defaults) }
        XCTAssertEqual(second, [.chatConversation(deleted.uuidString.lowercased())])
        XCTAssertEqual(try syncRecord("chat.\(trimmed.uuidString.lowercased())")?["isDeleted"] as Bool?, false)
        XCTAssertEqual(try syncRecord("chat.\(deleted.uuidString.lowercased())")?["isDeleted"] as Bool?, true)
        XCTAssertTrue(defaults.stringArray(forKey: MacProfileSync.deletedChatsKey)?.isEmpty ?? true)
    }

    func testADeletedChatStaysDeletedEvenIfAStaleListStillHasIt() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "SyncV2Tests-\(UUID().uuidString)"))
        let chat = UUID()
        let list = try JSONSerialization.data(withJSONObject: [["id": chat.uuidString, "title": "Chat", "messages": [], "createdAt": 1.0, "updatedAt": 2.0]])
        defaults.set(list, forKey: MacProfileSync.chatsKey)
        _ = try MainActor.assumeIsolated { try MacProfileSync.recordLocalChanges(dbQueue: queue, defaults: defaults) }
        // Deleted on another Mac.
        let name = "chat.\(chat.uuidString.lowercased())"
        try queue.write { try $0.execute(sql: "UPDATE sync_record SET isDeleted = 1, payload = NULL WHERE recordName = ?", arguments: [name]) }
        // This Mac's list is stale: recording must not bring it back.
        let changed = try MainActor.assumeIsolated { try MacProfileSync.recordLocalChanges(dbQueue: queue, defaults: defaults) }
        XCTAssertTrue(changed.isEmpty)
        XCTAssertEqual(try syncRecord(name)?["isDeleted"] as Bool?, true)
        // Applying the synced copy clears the list.
        MainActor.assumeIsolated { MacProfileSync.applyRemote(dbQueue: queue, defaults: defaults) }
        XCTAssertEqual(defaults.data(forKey: MacProfileSync.chatsKey), Data("[]".utf8))
    }

    func testTheV1TombstoneBackfillCanRunTwice() throws {
        try queue.write { db in
            try db.execute(sql: "INSERT INTO cloud_sync_tombstone (tableName, syncID, deletedAt, needsCloudSync) VALUES ('transcription', 'twice-1', ?, 0)", arguments: [Date()])
            try SyncSchema.backfillV1Tombstones(db, thisDeviceID: DeviceIdentity.currentID)
            try SyncSchema.backfillV1Tombstones(db, thisDeviceID: DeviceIdentity.currentID)
        }
        let count = try queue.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM sync_record WHERE recordName = 'dictation.twice-1' AND isDeleted = 1") }
        XCTAssertEqual(count, 1)
    }

    func testAnEqualLengthEditChangesTheSessionKey() {
        let now = Date()
        let before = WorkSessionBuilder.sessionKey([ConceptSource(id: 1, text: "ship it", createdAt: now, targetAppName: nil)])
        let after = WorkSessionBuilder.sessionKey([ConceptSource(id: 1, text: "skip it", createdAt: now, targetAppName: nil)])
        XCTAssertNotEqual(before, after)
    }

    func testIndexingDrainsTheQueueEvenForOldDictations() throws {
        _ = try store.applyInbound([try phoneDictation("p4", text: "An old phone dictation")], decide: ConflictPolicy.decide)
        let sources = try db.fetchSemanticIndexSourceTranscriptions(limit: 1)
        XCTAssertTrue(sources.contains { $0.text == "An old phone dictation" })
        try db.dequeueSemanticIndex(transcriptionIDs: sources.compactMap(\.id))
        XCTAssertEqual(try db.semanticIndexQueueCount(), 0)
    }
}
