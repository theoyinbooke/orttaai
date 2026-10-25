// CloudSyncMergeTests.swift
// OrttaaiTests
//
// A first iCloud merge on a new Mac moves thousands of rows. These run the
// merge and the database round trip off the main thread at that size, the
// way CloudSyncService now does.

import GRDB
import XCTest
@testable import Orttaai

private func isOnMainThread() -> Bool {
    Thread.isMainThread
}

final class CloudSyncMergeTests: XCTestCase {
    private func transcription(_ syncID: String, text: String, modifiedAt: Date) -> CloudSyncTranscription {
        CloudSyncTranscription(
            localID: nil,
            syncID: syncID,
            modifiedAt: modifiedAt,
            createdAt: modifiedAt,
            text: text,
            targetAppName: "Notes",
            targetAppBundleID: "com.apple.Notes",
            recordingDurationMs: 1_000,
            processingDurationMs: 200,
            settingsSyncDurationMs: nil,
            transcriptionDurationMs: nil,
            textProcessingDurationMs: nil,
            injectionDurationMs: nil,
            appActivationDurationMs: nil,
            clipboardRestoreDelayMs: nil,
            modelId: "test",
            audioDevice: nil
        )
    }

    /// This Mac has 3,000 dictations, iCloud has 2,500, 2,000 of them shared
    /// (iCloud's copy newer), and 300 shared ones were deleted on the other Mac.
    private func largeMerge() -> (local: CloudDatabaseSnapshot, remote: CloudDatabaseSnapshot) {
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let local = (0..<3_000).map { transcription("t-\($0)", text: "local \($0)", modifiedAt: base) }
        let remote = (1_000..<3_500).map {
            transcription("t-\($0)", text: "remote \($0)", modifiedAt: base.addingTimeInterval(60))
        }
        let tombstones = (1_000..<1_300).map {
            CloudSyncTombstone(table: .transcription, syncID: "t-\($0)", deletedAt: base.addingTimeInterval(120))
        }
        return (
            CloudDatabaseSnapshot(transcriptions: local),
            CloudDatabaseSnapshot(transcriptions: remote, tombstones: tombstones)
        )
    }

    func testLargeMergeRunsOffTheMainThread() async {
        let (local, remote) = largeMerge()

        let (merged, ranOnMain) = await Task.detached {
            (CloudSyncService.mergedDatabaseSnapshot(local: local, remote: remote), isOnMainThread())
        }.value

        XCTAssertFalse(ranOnMain)
        // 3,500 distinct rows minus the 300 deleted ones.
        XCTAssertEqual(merged.transcriptions.count, 3_200)
        XCTAssertEqual(merged.tombstones.count, 300)
        let texts = Dictionary(uniqueKeysWithValues: merged.transcriptions.map { ($0.syncID, $0.text) })
        XCTAssertEqual(texts["t-0"], "local 0")
        XCTAssertEqual(texts["t-2000"], "remote 2000", "the newer copy wins")
        XCTAssertNil(texts["t-1100"], "deleted on the other Mac")
    }

    func testLargeSnapshotRoundTripsThroughTheDatabaseOffTheMainThread() async throws {
        let (local, remote) = largeMerge()
        let merged = CloudSyncService.mergedDatabaseSnapshot(local: local, remote: remote)
        let db = try DatabaseManager(dbQueue: DatabaseQueue(path: ":memory:"))

        let (stored, ranOnMain) = try await Task.detached {
            try db.applyCloudSnapshot(merged, replacingLocalData: true)
            return (try db.cloudSyncSnapshot(), isOnMainThread())
        }.value

        XCTAssertFalse(ranOnMain)
        XCTAssertEqual(stored.transcriptions.count, 3_200)
        XCTAssertEqual(Set(stored.transcriptions.map(\.syncID)), Set(merged.transcriptions.map(\.syncID)))
    }
}
