// DatabaseManagerTests.swift
// OrttaaiTests

import XCTest
import GRDB
@testable import Orttaai

final class DatabaseManagerTests: XCTestCase {
    var db: DatabaseManager!

    override func setUpWithError() throws {
        let dbQueue = try DatabaseQueue(path: ":memory:")
        db = try DatabaseManager(dbQueue: dbQueue)
    }

    override func tearDownWithError() throws {
        db = nil
    }

    func testInsertAndFetch() throws {
        try db.saveTranscription(
            text: "Hello world",
            appName: "TextEdit",
            recordingMs: 3000,
            processingMs: 1500,
            modelId: "openai_whisper-large-v3_turbo"
        )

        let records = try db.fetchRecent()
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.text, "Hello world")
        XCTAssertEqual(records.first?.targetAppName, "TextEdit")
    }

    func testFetchRecentOrdering() throws {
        try db.saveTranscription(
            text: "First",
            appName: "App1",
            recordingMs: 1000,
            processingMs: 500,
            modelId: "test"
        )

        // Small delay to ensure different timestamps
        try db.saveTranscription(
            text: "Second",
            appName: "App2",
            recordingMs: 2000,
            processingMs: 1000,
            modelId: "test"
        )

        let records = try db.fetchRecent()
        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(records.first?.text, "Second")
        XCTAssertEqual(records.last?.text, "First")
    }

    func testDoesNotPruneSavedTranscriptions() throws {
        for i in 0..<510 {
            try db.saveTranscription(
                text: "Entry \(i)",
                appName: "TestApp",
                recordingMs: 1000,
                processingMs: 500,
                modelId: "test"
            )
        }

        let records = try db.fetchRecent(limit: 600)
        XCTAssertEqual(records.count, 510)
    }

    func testSearch() throws {
        try db.saveTranscription(
            text: "The quick brown fox",
            appName: "TextEdit",
            recordingMs: 3000,
            processingMs: 1500,
            modelId: "test"
        )
        try db.saveTranscription(
            text: "Hello world",
            appName: "TextEdit",
            recordingMs: 2000,
            processingMs: 1000,
            modelId: "test"
        )

        let results = try db.search(query: "fox")
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.text, "The quick brown fox")
    }

    func testDeleteAll() throws {
        for i in 0..<5 {
            try db.saveTranscription(
                text: "Entry \(i)",
                appName: "TestApp",
                recordingMs: 1000,
                processingMs: 500,
                modelId: "test"
            )
        }

        try db.deleteAll()
        let records = try db.fetchRecent()
        XCTAssertEqual(records.count, 0)
    }

    func testDeleteAllCreatesRecoverableBackupForFileBackedDatabase() throws {
        let fileManager = FileManager.default
        let tempRoot = fileManager.temporaryDirectory
            .appendingPathComponent("OrttaaiDatabaseManagerTests-\(UUID().uuidString)")
        let dbDirectory = tempRoot.appendingPathComponent("Orttaai", isDirectory: true)
        let backupDirectory = tempRoot.appendingPathComponent("Orttaai Backups", isDirectory: true)
        try fileManager.createDirectory(at: dbDirectory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempRoot) }

        let dbURL = dbDirectory.appendingPathComponent("orttaai.db")
        let fileBackedDB = try DatabaseManager(
            dbQueue: DatabaseQueue(path: dbURL.path),
            databaseURL: dbURL,
            backupDirectoryURL: backupDirectory
        )
        try fileBackedDB.saveTranscription(
            text: "Keep this in the backup",
            appName: "TextEdit",
            recordingMs: 1_000,
            processingMs: 500,
            modelId: "test"
        )

        try fileBackedDB.deleteAll()

        let backupFiles = try fileManager.contentsOfDirectory(
            at: backupDirectory,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "db" }
        XCTAssertEqual(backupFiles.count, 1)

        let backupQueue = try DatabaseQueue(path: backupFiles[0].path)
        let backedUpRecords = try backupQueue.read { db in
            try Transcription.fetchAll(db)
        }
        XCTAssertEqual(backedUpRecords.map(\.text), ["Keep this in the backup"])
    }

    func testDeleteTranscriptionById() throws {
        try db.saveTranscription(
            text: "Delete me",
            appName: "TestApp",
            recordingMs: 1_000,
            processingMs: 500,
            modelId: "test"
        )
        let inserted = try XCTUnwrap(try db.fetchRecent().first)
        let id = try XCTUnwrap(inserted.id)

        let didDelete = try db.deleteTranscription(id: id)
        XCTAssertTrue(didDelete)

        let records = try db.fetchRecent()
        XCTAssertTrue(records.isEmpty)
    }

    func testDeleteTranscriptionReturnsFalseWhenMissing() throws {
        let didDelete = try db.deleteTranscription(id: 123_456)
        XCTAssertFalse(didDelete)
    }

    func testEmptyFetch() throws {
        let records = try db.fetchRecent()
        XCTAssertEqual(records.count, 0)
    }

    func testLatencyTelemetryPersistence() throws {
        try db.saveTranscription(
            text: "Telemetry entry",
            appName: "TextEdit",
            recordingMs: 2_100,
            processingMs: 980,
            modelId: "test",
            latency: DictationLatencyTelemetry(
                settingsSyncMs: 4,
                transcriptionMs: 600,
                textProcessingMs: 7,
                injectionMs: 72,
                appActivationMs: 25,
                clipboardRestoreDelayMs: 68
            )
        )

        let record = try XCTUnwrap(try db.fetchRecent(limit: 1).first)
        XCTAssertEqual(record.settingsSyncDurationMs, 4)
        XCTAssertEqual(record.transcriptionDurationMs, 600)
        XCTAssertEqual(record.textProcessingDurationMs, 7)
        XCTAssertEqual(record.injectionDurationMs, 72)
        XCTAssertEqual(record.appActivationDurationMs, 25)
        XCTAssertEqual(record.clipboardRestoreDelayMs, 68)
    }

    func testDictionaryUpsertAndFetchActive() throws {
        _ = try db.upsertDictionaryEntry(source: "whispr", target: "Wispr", isCaseSensitive: false, isActive: true)
        _ = try db.upsertDictionaryEntry(source: "draft", target: "Draft", isCaseSensitive: false, isActive: false)

        let allEntries = try db.fetchDictionaryEntries()
        let activeEntries = try db.fetchDictionaryEntries(includeInactive: false)

        XCTAssertEqual(allEntries.count, 2)
        XCTAssertEqual(activeEntries.count, 1)
        XCTAssertEqual(activeEntries.first?.source, "whispr")
    }

    func testUpdateDictionaryEntry() throws {
        let entry = try db.upsertDictionaryEntry(source: "wispr", target: "Wispr")
        let id = try XCTUnwrap(entry.id)

        let updated = try db.updateDictionaryEntry(
            id: id,
            source: "wispr flow",
            target: "Wispr Flow",
            isCaseSensitive: true,
            isActive: true
        )

        XCTAssertEqual(updated.source, "wispr flow")
        XCTAssertEqual(updated.target, "Wispr Flow")
        XCTAssertTrue(updated.isCaseSensitive)
    }

    func testSnippetUpsertAndDelete() throws {
        let entry = try db.upsertSnippetEntry(trigger: "my email", expansion: "me@example.com")
        let id = try XCTUnwrap(entry.id)
        XCTAssertEqual(try db.fetchSnippetEntries().count, 1)

        let didDelete = try db.deleteSnippetEntry(id: id)
        XCTAssertTrue(didDelete)
        XCTAssertTrue(try db.fetchSnippetEntries().isEmpty)
    }

    func testLearningSuggestionSaveAndStatusUpdate() throws {
        let changeCount = try db.saveLearningSuggestions([
            LearningSuggestionDraft(
                type: .snippet,
                candidateSource: "intro email",
                candidateTarget: "Hey, nice to meet you.",
                confidence: 0.82,
                evidence: "Appeared repeatedly."
            )
        ])
        XCTAssertEqual(changeCount, 1)

        let pending = try db.fetchLearningSuggestions(status: .pending)
        XCTAssertEqual(pending.count, 1)

        let id = try XCTUnwrap(pending.first?.id)
        try db.updateLearningSuggestionStatus(id: id, status: .accepted)

        XCTAssertTrue(try db.fetchLearningSuggestions(status: .pending).isEmpty)
        XCTAssertEqual(try db.fetchLearningSuggestions(status: .accepted).count, 1)
    }

    func testWritingInsightSnapshotPersistenceRoundTrip() throws {
        let snapshot = WritingInsightSnapshot(
            generatedAt: Date(),
            sampleCount: 12,
            analyzerName: "Apple Foundation Models",
            usedFallback: false,
            request: WritingInsightsRequest(
                timeRange: .days30,
                generationMode: .deep,
                appFilterMode: .includeOnly,
                selectedApps: ["Cursor", "Google Chrome"]
            ),
            summary: "You write mostly in product and coding contexts.",
            signals: [
                WritingInsightSignal(label: "Sessions", value: "12", detail: "Recent sessions")
            ],
            patterns: [
                WritingInsightPattern(title: "Pattern", detail: "Detail", evidence: "Evidence")
            ],
            strengths: ["Consistent cadence"],
            opportunities: ["Reduce filler words"],
            recommendations: [
                WritingInsightRecommendation(
                    kind: .snippet,
                    source: "intro email",
                    target: "Hey, would love to connect this week.",
                    rationale: "Appeared repeatedly.",
                    confidence: 0.82
                )
            ]
        )

        let savedId = try db.saveWritingInsightSnapshot(snapshot)
        XCTAssertGreaterThan(savedId, 0)

        let loaded = try XCTUnwrap(db.fetchLatestWritingInsightSnapshot())
        XCTAssertEqual(loaded.summary, snapshot.summary)
        XCTAssertEqual(loaded.sampleCount, snapshot.sampleCount)
        XCTAssertEqual(loaded.request.generationMode, .deep)
        XCTAssertEqual(loaded.request.selectedApps, ["Cursor", "Google Chrome"])
        XCTAssertEqual(loaded.recommendations.first?.kind, .snippet)
    }

    func testFetchDistinctTargetAppNames() throws {
        try db.saveTranscription(
            text: "One",
            appName: "Cursor",
            recordingMs: 1000,
            processingMs: 500,
            modelId: "test"
        )
        try db.saveTranscription(
            text: "Two",
            appName: "Google Chrome",
            recordingMs: 1000,
            processingMs: 500,
            modelId: "test"
        )
        try db.saveTranscription(
            text: "Three",
            appName: "Cursor",
            recordingMs: 1000,
            processingMs: 500,
            modelId: "test"
        )

        let apps = try db.fetchDistinctTargetAppNames(limit: 10)
        XCTAssertEqual(apps.count, 2)
        XCTAssertTrue(apps.contains("Cursor"))
        XCTAssertTrue(apps.contains("Google Chrome"))
    }

    func testWritingInsightHistorySupportsPinAndDelete() throws {
        let older = WritingInsightSnapshot(
            generatedAt: Date().addingTimeInterval(-120),
            sampleCount: 2,
            analyzerName: "Heuristic Analyzer",
            usedFallback: false,
            request: .default,
            summary: "Older snapshot",
            signals: [WritingInsightSignal(label: "Sessions", value: "2", detail: "Older")],
            patterns: [WritingInsightPattern(title: "Older pattern", detail: "Detail", evidence: nil)],
            strengths: ["Strength"],
            opportunities: ["Opportunity"],
            recommendations: []
        )
        let newer = WritingInsightSnapshot(
            generatedAt: Date(),
            sampleCount: 4,
            analyzerName: "Heuristic Analyzer",
            usedFallback: false,
            request: .default,
            summary: "Newer snapshot",
            signals: [WritingInsightSignal(label: "Sessions", value: "4", detail: "Newer")],
            patterns: [WritingInsightPattern(title: "Newer pattern", detail: "Detail", evidence: nil)],
            strengths: ["Strength"],
            opportunities: ["Opportunity"],
            recommendations: []
        )

        let olderID = try db.saveWritingInsightSnapshot(older)
        let newerID = try db.saveWritingInsightSnapshot(newer)

        var history = try db.fetchWritingInsightHistory(limit: 10)
        XCTAssertEqual(history.first?.id, newerID)

        try db.setWritingInsightSnapshotPinned(id: olderID, isPinned: true)
        history = try db.fetchWritingInsightHistory(limit: 10)
        XCTAssertEqual(history.first?.id, olderID)
        XCTAssertTrue(history.first?.isPinned == true)

        let deleted = try db.deleteWritingInsightSnapshot(id: newerID)
        XCTAssertTrue(deleted)
        history = try db.fetchWritingInsightHistory(limit: 10)
        XCTAssertEqual(history.count, 1)
        XCTAssertEqual(history.first?.id, olderID)
    }

    func testFetchLatestTranscriptionDateAndCountSince() throws {
        let baseDate = Date(timeIntervalSince1970: 1_735_000_000)
        let firstDate = baseDate.addingTimeInterval(-180)
        let secondDate = baseDate.addingTimeInterval(-60)
        let thirdDate = baseDate

        try db.saveTranscription(
            text: "First",
            appName: "Cursor",
            recordingMs: 1_000,
            processingMs: 500,
            modelId: "test",
            createdAt: firstDate
        )
        try db.saveTranscription(
            text: "Second",
            appName: "Cursor",
            recordingMs: 1_000,
            processingMs: 500,
            modelId: "test",
            createdAt: secondDate
        )
        try db.saveTranscription(
            text: "Third",
            appName: "Cursor",
            recordingMs: 1_000,
            processingMs: 500,
            modelId: "test",
            createdAt: thirdDate
        )

        let latest = try XCTUnwrap(try db.fetchLatestTranscriptionDate())
        XCTAssertEqual(latest.timeIntervalSince1970, thirdDate.timeIntervalSince1970, accuracy: 0.5)
        XCTAssertEqual(try db.countTranscriptions(since: secondDate), 1)
        XCTAssertEqual(try db.countTranscriptions(since: firstDate), 2)
    }

    func testWritingInsightPruningKeepsPinnedSnapshotsWhenPossible() throws {
        let pinnedSnapshot = WritingInsightSnapshot(
            generatedAt: Date().addingTimeInterval(-5_000),
            sampleCount: 1,
            analyzerName: "Heuristic Analyzer",
            usedFallback: false,
            request: .default,
            summary: "Pinned",
            signals: [],
            patterns: [],
            strengths: [],
            opportunities: [],
            recommendations: []
        )
        let pinnedID = try db.saveWritingInsightSnapshot(pinnedSnapshot)
        try db.setWritingInsightSnapshotPinned(id: pinnedID, isPinned: true)

        for index in 0..<60 {
            let snapshot = WritingInsightSnapshot(
                generatedAt: Date().addingTimeInterval(TimeInterval(index)),
                sampleCount: index + 2,
                analyzerName: "Heuristic Analyzer",
                usedFallback: false,
                request: .default,
                summary: "Snapshot \(index)",
                signals: [],
                patterns: [],
                strengths: [],
                opportunities: [],
                recommendations: []
            )
            _ = try db.saveWritingInsightSnapshot(snapshot)
        }

        let history = try db.fetchWritingInsightHistory(limit: 80)
        XCTAssertEqual(history.count, 60)
        XCTAssertTrue(history.contains(where: { $0.id == pinnedID }))
    }

    func testCloudSyncSnapshotExportsRowsAndDeleteTombstones() throws {
        try db.saveTranscription(
            text: "Sync me",
            appName: "TextEdit",
            recordingMs: 1_000,
            processingMs: 500,
            modelId: "test"
        )
        _ = try db.upsertDictionaryEntry(source: "ortai", target: "Orttaai")
        _ = try db.upsertSnippetEntry(trigger: "sign off", expansion: "Best,\nMe")

        var snapshot = try db.cloudSyncSnapshot()
        XCTAssertEqual(snapshot.transcriptions.count, 1)
        XCTAssertEqual(snapshot.dictionaryEntries.count, 1)
        XCTAssertEqual(snapshot.snippetEntries.count, 1)
        XCTAssertFalse(snapshot.transcriptions[0].syncID.isEmpty)

        let transcriptionID = try XCTUnwrap(try db.fetchRecent().first?.id)
        XCTAssertTrue(try db.deleteTranscription(id: transcriptionID))

        snapshot = try db.cloudSyncSnapshot()
        XCTAssertTrue(snapshot.transcriptions.isEmpty)
        XCTAssertTrue(snapshot.tombstones.contains { $0.table == .transcription })
    }

    func testCloudSyncSnapshotStopsExportingTombstonesAfterSyncCompletes() throws {
        try db.saveTranscription(
            text: "Delete once",
            appName: "TextEdit",
            recordingMs: 1_000,
            processingMs: 500,
            modelId: "test"
        )

        let transcriptionID = try XCTUnwrap(try db.fetchRecent().first?.id)
        XCTAssertTrue(try db.deleteTranscription(id: transcriptionID))
        XCTAssertEqual(try db.cloudSyncSnapshot().tombstones.count, 1)

        try db.markCloudSyncCompleted()

        XCTAssertTrue(try db.cloudSyncSnapshot().tombstones.isEmpty)
    }

    func testCloudSyncSnapshotDoesNotExportImportedTombstones() throws {
        let tombstone = CloudSyncTombstone(
            table: .transcription,
            syncID: "remote-deleted-transcription",
            deletedAt: Date(timeIntervalSince1970: 1_800_000_000)
        )

        try db.applyCloudSnapshot(
            CloudDatabaseSnapshot(tombstones: [tombstone]),
            replacingLocalData: false
        )

        XCTAssertTrue(try db.cloudSyncSnapshot().tombstones.isEmpty)
    }

    func testApplyCloudSnapshotImportsTranscriptions() throws {
        let createdAt = Date(timeIntervalSince1970: 1_800_000_000)
        let modifiedAt = createdAt.addingTimeInterval(30)
        let remoteRecord = CloudSyncTranscription(
            localID: nil,
            syncID: "remote-transcription-1",
            modifiedAt: modifiedAt,
            createdAt: createdAt,
            text: "Imported from iCloud",
            targetAppName: "Notes",
            targetAppBundleID: "com.apple.Notes",
            recordingDurationMs: 1_200,
            processingDurationMs: 450,
            settingsSyncDurationMs: nil,
            transcriptionDurationMs: nil,
            textProcessingDurationMs: nil,
            injectionDurationMs: nil,
            appActivationDurationMs: nil,
            clipboardRestoreDelayMs: nil,
            modelId: "test",
            audioDevice: nil
        )

        try db.applyCloudSnapshot(
            CloudDatabaseSnapshot(transcriptions: [remoteRecord]),
            replacingLocalData: false
        )

        let records = try db.fetchRecent()
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.text, "Imported from iCloud")
        XCTAssertEqual(records.first?.targetAppName, "Notes")
    }

    func testReplacingFromCloudSnapshotDoesNotTombstoneImportedRows() throws {
        try db.saveTranscription(
            text: "Keep this after merge",
            appName: "Notes",
            recordingMs: 1_000,
            processingMs: 300,
            modelId: "test"
        )
        let snapshot = try db.cloudSyncSnapshot()
        let syncID = try XCTUnwrap(snapshot.transcriptions.first?.syncID)

        try db.applyCloudSnapshot(snapshot, replacingLocalData: true)

        let result = try db.cloudSyncSnapshot()
        XCTAssertEqual(result.transcriptions.count, 1)
        XCTAssertEqual(result.transcriptions.first?.syncID, syncID)
        XCTAssertFalse(result.tombstones.contains { $0.table == .transcription && $0.syncID == syncID })
    }

    func testApplyingLiveCloudRecordClearsStaleTombstone() throws {
        try db.saveTranscription(
            text: "Deleted locally, then restored from cloud",
            appName: "Notes",
            recordingMs: 1_000,
            processingMs: 300,
            modelId: "test"
        )
        let original = try XCTUnwrap(try db.cloudSyncSnapshot().transcriptions.first)
        let localID = try XCTUnwrap(try db.fetchRecent().first?.id)
        XCTAssertTrue(try db.deleteTranscription(id: localID))
        XCTAssertTrue(try db.cloudSyncSnapshot().tombstones.contains {
            $0.table == .transcription && $0.syncID == original.syncID
        })

        var restored = original
        restored.modifiedAt = Date().addingTimeInterval(60)
        try db.applyCloudSnapshot(CloudDatabaseSnapshot(transcriptions: [restored]), replacingLocalData: false)

        let result = try db.cloudSyncSnapshot()
        XCTAssertEqual(result.transcriptions.count, 1)
        XCTAssertEqual(result.transcriptions.first?.syncID, original.syncID)
        XCTAssertFalse(result.tombstones.contains { $0.table == .transcription && $0.syncID == original.syncID })
    }

    func testCloudProfileSnapshotExcludesPerDeviceSyncMetadata() throws {
        let suiteName = "CloudProfileSnapshotTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set("openai_whisper-large-v3_turbo", forKey: "selectedModelId")
        defaults.set(true, forKey: CloudSyncService.syncEnabledKey)
        defaults.set(1_800_000_000.0, forKey: CloudSyncService.lastCompletedAtKey)
        defaults.set("device-a", forKey: CloudSyncService.deviceIDKey)
        defaults.set(1_800_000_100.0, forKey: CloudProfileSnapshot.modifiedAtKey)

        let snapshot = CloudProfileSnapshot.capture(defaults: defaults)

        XCTAssertEqual(snapshot.values["selectedModelId"], .string("openai_whisper-large-v3_turbo"))
        XCTAssertNil(snapshot.values[CloudSyncService.syncEnabledKey])
        XCTAssertNil(snapshot.values[CloudSyncService.lastCompletedAtKey])
        XCTAssertNil(snapshot.values[CloudSyncService.deviceIDKey])
        XCTAssertNil(snapshot.values[CloudProfileSnapshot.modifiedAtKey])
        XCTAssertEqual(snapshot.modifiedAt, Date(timeIntervalSince1970: 1_800_000_100.0))
    }

    func testApplyingCloudProfileRemovesMissingSyncedValuesButKeepsLocalSyncState() throws {
        let suiteName = "CloudProfileApplyTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set("local-model", forKey: "selectedModelId")
        defaults.set("device-a", forKey: CloudSyncService.deviceIDKey)
        defaults.set(true, forKey: CloudSyncService.syncEnabledKey)

        let modifiedAt = Date(timeIntervalSince1970: 1_800_000_200.0)
        let snapshot = CloudProfileSnapshot(
            values: ["dictationLanguage": .string("en-GB")],
            modifiedAt: modifiedAt
        )

        snapshot.apply(to: defaults)

        XCTAssertNil(defaults.object(forKey: "selectedModelId"))
        XCTAssertEqual(defaults.string(forKey: "dictationLanguage"), "en-GB")
        XCTAssertEqual(defaults.string(forKey: CloudSyncService.deviceIDKey), "device-a")
        XCTAssertTrue(defaults.bool(forKey: CloudSyncService.syncEnabledKey))
        XCTAssertEqual(defaults.double(forKey: CloudProfileSnapshot.modifiedAtKey), modifiedAt.timeIntervalSince1970)
    }
}
