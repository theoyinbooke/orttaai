// AnalyticsDeviceTests.swift
// OrttaaiTests

import XCTest
import GRDB
@testable import Orttaai

@MainActor
final class AnalyticsDeviceTests: XCTestCase {
    private var queue: DatabaseQueue!
    private var db: DatabaseManager!
    private var viewModel: AnalyticsDashboardViewModel!

    override func setUp() async throws {
        queue = try DatabaseQueue(path: ":memory:")
        db = try DatabaseManager(dbQueue: queue)
        let db = db!
        viewModel = AnalyticsDashboardViewModel(settings: AppSettings(), makeDatabase: { db })
    }

    override func tearDown() async throws {
        viewModel?.cancelObservation()
        viewModel = nil
        db = nil
        queue = nil
    }

    private func savePhoneDictation(_ text: String, kind: String = "iphone", timeZone: String? = nil) throws {
        let id = try db.saveTranscription(text: text, appName: nil, recordingMs: 2_000, processingMs: 300, modelId: "mini", sourceDeviceID: "phone-\(kind)")
        try queue.write { db in
            try db.execute(sql: "UPDATE transcription SET sourceDeviceKind = ?, timeZoneIdentifier = ? WHERE id = ?", arguments: [kind, timeZone, id])
        }
    }

    func testOneDeviceShowsNoDeviceFilterOrBreakdown() async throws {
        _ = try db.saveTranscription(text: "just this mac", appName: "Notes", recordingMs: 1_000, processingMs: 200, modelId: "m")

        viewModel.load()
        await viewModel.waitForRefresh()

        XCTAssertEqual(viewModel.availableDeviceFilters, [.all, .thisMac])
        XCTAssertEqual(viewModel.deviceBreakdown.count, 1)
    }

    func testFilteringToThePhoneCountsOnlyItsDictations() async throws {
        _ = try db.saveTranscription(text: "said on this mac", appName: "Notes", recordingMs: 1_000, processingMs: 200, modelId: "m")
        try savePhoneDictation("on the phone")

        viewModel.load()
        await viewModel.waitForRefresh()
        XCTAssertEqual(viewModel.availableDeviceFilters, [.all, .thisMac, .iphone])
        XCTAssertEqual(viewModel.totalWords, 7)
        XCTAssertEqual(viewModel.deviceBreakdown.map(\.words), [4, 3])
        XCTAssertEqual(viewModel.wordsByApp.map(\.name).sorted(), ["Notes", "Orttakey on iPhone"])

        viewModel.setDeviceFilter(.iphone)
        await viewModel.waitForRefresh()
        XCTAssertEqual(viewModel.totalWords, 3)
        XCTAssertEqual(viewModel.totalSessions, 1)
        XCTAssertEqual(viewModel.wordsByApp.map(\.name), ["Orttakey on iPhone"])
        // The breakdown always shows every device.
        XCTAssertEqual(viewModel.deviceBreakdown.count, 2)
    }

    func testOnlyTheLatestOfQuickSwitchesIsShown() async throws {
        _ = try db.saveTranscription(text: "said on this mac", appName: "Notes", recordingMs: 1_000, processingMs: 200, modelId: "m")
        try savePhoneDictation("on the phone")
        viewModel.load()
        await viewModel.waitForRefresh()

        viewModel.setDeviceFilter(.iphone)
        viewModel.setDeviceFilter(.thisMac)
        await viewModel.waitForRefresh()

        XCTAssertEqual(viewModel.deviceFilter, .thisMac)
        XCTAssertEqual(viewModel.totalWords, 4)
        XCTAssertEqual(viewModel.totalSessions, 1)
    }

    func testASwitchMadeWhileLoadingIsShown() async throws {
        _ = try db.saveTranscription(text: "said on this mac", appName: "Notes", recordingMs: 1_000, processingMs: 200, modelId: "m")
        try savePhoneDictation("on the phone")

        viewModel.load()
        viewModel.setDeviceFilter(.iphone)
        await viewModel.waitForRefresh()

        XCTAssertTrue(viewModel.hasLoaded)
        XCTAssertEqual(viewModel.deviceFilter, .iphone)
        XCTAssertEqual(viewModel.totalWords, 3)
    }

    func testADictationSavedWhileOpenIsCounted() async throws {
        _ = try db.saveTranscription(text: "said on this mac", appName: "Notes", recordingMs: 1_000, processingMs: 200, modelId: "m")
        viewModel.load()
        await viewModel.waitForRefresh()
        XCTAssertEqual(viewModel.totalSessions, 1)

        _ = try db.saveTranscription(text: "and one more", appName: "Notes", recordingMs: 1_000, processingMs: 200, modelId: "m")
        // The change reaches the dashboard through its database observation.
        for _ in 0..<50 where viewModel.totalSessions < 2 {
            try await Task.sleep(for: .milliseconds(20))
            await viewModel.waitForRefresh()
        }
        XCTAssertEqual(viewModel.totalSessions, 2)
    }

    func testHoursAreChartedInTheTimeZoneTheDictationWasSaidIn() async throws {
        let elsewhere = TimeZone.current.identifier == "Asia/Tokyo" ? "America/Chicago" : "Asia/Tokyo"
        try savePhoneDictation("said abroad", timeZone: elsewhere)
        let createdAt = try XCTUnwrap(try db.fetchRecent().first?.createdAt)

        viewModel.load()
        await viewModel.waitForRefresh()

        var local = Calendar.current
        local.timeZone = try XCTUnwrap(TimeZone(identifier: elsewhere))
        let busiestHour = viewModel.hourlyActivity.first { $0.count == 1 }?.hour
        XCTAssertEqual(busiestHour, local.component(.hour, from: createdAt))
        let busiestWeekday = viewModel.weekdayActivity.first { $0.sessions == 1 }?.weekday
        XCTAssertEqual(busiestWeekday, local.component(.weekday, from: createdAt))
    }
}
