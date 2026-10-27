// HomeViewModelTests.swift
// OrttaaiTests

import GRDB
import XCTest
@testable import Orttaai

@MainActor
final class HomeViewModelTests: XCTestCase {
    private var queue: DatabaseQueue!
    private var db: DatabaseManager!
    private var reads: ArchiveReads!
    private var viewModel: HomeViewModel!

    override func setUp() async throws {
        let reads = ArchiveReads()
        var configuration = Configuration()
        configuration.prepareDatabase { db in
            db.trace { reads.ran($0.description) }
        }
        queue = try DatabaseQueue(path: ":memory:", configuration: configuration)
        db = try DatabaseManager(dbQueue: queue)
        self.reads = reads
        viewModel = HomeViewModel(statsService: DashboardStatsService(databaseManager: db), insightsService: nil, settings: AppSettings())
    }

    override func tearDown() async throws {
        await viewModel?.waitForRefresh()
        viewModel = nil
        db = nil
        queue = nil
        reads = nil
    }

    @discardableResult
    private func save(_ text: String) throws -> Int64 {
        try db.saveTranscription(text: text, appName: "Notes", recordingMs: 1_000, processingMs: 200, modelId: "m")
    }

    func testOpeningReadsTheArchiveOnce() async throws {
        try save("said on this mac")

        viewModel.load()
        await viewModel.waitForRefresh()
        // Time for the database observation's first call, which used to
        // refresh the dashboard a second time.
        try await Task.sleep(for: .milliseconds(200))
        await viewModel.waitForRefresh()

        XCTAssertTrue(viewModel.hasLoaded)
        XCTAssertFalse(viewModel.isLoading)
        XCTAssertEqual(viewModel.payload.header.totalWords, 4)
        XCTAssertEqual(reads.wholeArchive, 1)
    }

    func testADictationSavedWhileOpenIsCounted() async throws {
        try save("said on this mac")
        viewModel.load()
        await viewModel.waitForRefresh()
        XCTAssertEqual(viewModel.payload.today.sessions, 1)

        try save("and one more")
        // The change reaches Home through its database observation.
        for _ in 0..<50 where viewModel.payload.today.sessions < 2 {
            try await Task.sleep(for: .milliseconds(20))
            await viewModel.waitForRefresh()
        }
        XCTAssertEqual(viewModel.payload.today.sessions, 2)
    }

    func testARefreshAskedForDuringAnotherRunsAfterIt() async throws {
        viewModel.load()
        await viewModel.waitForRefresh()
        let readsBefore = reads.wholeArchive

        reads.holdNextStatement()
        viewModel.refresh()
        await reads.waitUntilHeld()
        // As a new dictation's change notice would, mid-refresh.
        viewModel.refresh()
        reads.release()
        await viewModel.waitForRefresh()

        XCTAssertEqual(reads.wholeArchive - readsBefore, 2)
        XCTAssertFalse(viewModel.isLoading)
    }

    func testDeletingARecentDictationTakesItOffHome() async throws {
        let id = try save("said on this mac")
        try save("and one more")
        viewModel.load()
        await viewModel.waitForRefresh()
        XCTAssertEqual(viewModel.payload.recent.count, 2)

        viewModel.deleteRecentDictation(id: id)
        await viewModel.waitForRefresh()

        XCTAssertFalse(viewModel.payload.recent.contains { $0.id == id })
        XCTAssertEqual(viewModel.payload.today.sessions, 1)
    }

    /// Each visit to Home makes a new view model; one kept alive by its
    /// refresh would keep refreshing for every dictation.
    func testLeavingHomeMidRefreshLetsItsViewModelGo() async throws {
        try save("said on this mac")
        viewModel.load()
        weak let left = viewModel
        viewModel = nil

        for _ in 0..<50 where left != nil {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertNil(left)
    }
}

/// Counts Home's reads of the whole archive, and can hold the database at
/// its next statement.
private final class ArchiveReads: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var holdsNext = false
    private let held = DispatchSemaphore(value: 0)
    private let released = DispatchSemaphore(value: 0)

    var wholeArchive: Int {
        lock.withLock { count }
    }

    /// From the database's trace, on its queue, as each statement starts.
    func ran(_ sql: String) {
        let holds = lock.withLock {
            // `fetchAllTranscriptions`: every row, in no range and to no limit.
            if sql.contains("FROM \"transcription\" ORDER BY \"createdAt\" DESC"), !sql.contains("WHERE"), !sql.contains("LIMIT") {
                count += 1
            }
            defer { holdsNext = false }
            return holdsNext
        }
        if holds {
            held.signal()
            released.wait()
        }
    }

    func holdNextStatement() {
        lock.withLock { holdsNext = true }
    }

    func waitUntilHeld() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async { [held] in
                held.wait()
                continuation.resume()
            }
        }
    }

    func release() {
        released.signal()
    }
}
