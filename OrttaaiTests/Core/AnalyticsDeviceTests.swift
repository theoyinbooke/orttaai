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

    func testOneDeviceShowsNoDeviceFilterOrBreakdown() throws {
        _ = try db.saveTranscription(text: "just this mac", appName: "Notes", recordingMs: 1_000, processingMs: 200, modelId: "m")

        viewModel.load()

        XCTAssertEqual(viewModel.availableDeviceFilters, [.all, .thisMac])
        XCTAssertEqual(viewModel.deviceBreakdown.count, 1)
    }

    func testFilteringToThePhoneCountsOnlyItsDictations() throws {
        _ = try db.saveTranscription(text: "said on this mac", appName: "Notes", recordingMs: 1_000, processingMs: 200, modelId: "m")
        try savePhoneDictation("on the phone")

        viewModel.load()
        XCTAssertEqual(viewModel.availableDeviceFilters, [.all, .thisMac, .iphone])
        XCTAssertEqual(viewModel.totalWords, 7)
        XCTAssertEqual(viewModel.deviceBreakdown.map(\.words), [4, 3])
        XCTAssertEqual(viewModel.wordsByApp.map(\.name).sorted(), ["Notes", "Orttakey on iPhone"])

        viewModel.setDeviceFilter(.iphone)
        XCTAssertEqual(viewModel.totalWords, 3)
        XCTAssertEqual(viewModel.totalSessions, 1)
        XCTAssertEqual(viewModel.wordsByApp.map(\.name), ["Orttakey on iPhone"])
        // The breakdown always shows every device.
        XCTAssertEqual(viewModel.deviceBreakdown.count, 2)
    }

    func testHoursAreChartedInTheTimeZoneTheDictationWasSaidIn() throws {
        let elsewhere = TimeZone.current.identifier == "Asia/Tokyo" ? "America/Chicago" : "Asia/Tokyo"
        try savePhoneDictation("said abroad", timeZone: elsewhere)
        let createdAt = try XCTUnwrap(try db.fetchRecent().first?.createdAt)

        viewModel.load()

        var local = Calendar.current
        local.timeZone = try XCTUnwrap(TimeZone(identifier: elsewhere))
        let busiestHour = viewModel.hourlyActivity.first { $0.count == 1 }?.hour
        XCTAssertEqual(busiestHour, local.component(.hour, from: createdAt))
        let busiestWeekday = viewModel.weekdayActivity.first { $0.sessions == 1 }?.weekday
        XCTAssertEqual(busiestWeekday, local.component(.weekday, from: createdAt))
    }
}
