// DashboardStatsServiceTests.swift
// OrttaaiTests

import XCTest
import GRDB
@testable import Orttaai

final class DashboardStatsServiceTests: XCTestCase {
    private var db: DatabaseManager!
    private var calendar: Calendar!
    private var now: Date!
    private var service: DashboardStatsService!

    override func setUpWithError() throws {
        var utcCalendar = Calendar(identifier: .gregorian)
        utcCalendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        calendar = utcCalendar

        now = makeDate(year: 2026, month: 2, day: 23, hour: 12)

        let dbQueue = try DatabaseQueue(path: ":memory:")
        db = try DatabaseManager(dbQueue: dbQueue)
        service = DashboardStatsService(
            databaseManager: db,
            calendar: calendar,
            now: { [unowned self] in self.now }
        )
    }

    override func tearDownWithError() throws {
        service = nil
        db = nil
        calendar = nil
        now = nil
    }

    func testWordCountingEdgeCases() throws {
        try save(text: "Hello   world", dayOffset: 0, recordingMs: 2_000)
        try save(text: "   ", dayOffset: 0, recordingMs: 2_000)
        try save(text: "Hi,\nthere friend", dayOffset: 0, recordingMs: 2_000)

        let payload = try service.load(currentModelId: "test-model")

        XCTAssertEqual(payload.today.words, 5)
        XCTAssertEqual(payload.header.words7d, 5)
    }

    func testAverageWPMIsSafeWhenRecordingDurationIsZero() throws {
        try save(text: "one two three four five", dayOffset: 0, recordingMs: 0)

        let payload = try service.load(currentModelId: "test-model")

        XCTAssertEqual(payload.today.averageWPM, 0)
        XCTAssertEqual(payload.header.averageWPM7d, 0)
    }

    func testTrendBucketingReturnsSevenDaysInOrder() throws {
        try save(text: "one two", dayOffset: 0, recordingMs: 2_000)
        try save(text: "three four five", dayOffset: -2, recordingMs: 2_000)

        let payload = try service.load(currentModelId: "test-model")
        let startDay = calendar.date(byAdding: .day, value: -6, to: calendar.startOfDay(for: now))!

        XCTAssertEqual(payload.trend7d.count, 7)
        XCTAssertEqual(payload.trend7d.first?.dayStart, startDay)
        XCTAssertEqual(payload.trend7d.last?.dayStart, calendar.startOfDay(for: now))

        let todayBucket = payload.trend7d.last
        XCTAssertEqual(todayBucket?.words, 2)

        let thirdFromEnd = payload.trend7d[payload.trend7d.count - 3]
        XCTAssertEqual(thirdFromEnd.words, 3)
    }

    func testActiveDaysCountsDistinctDaysOnly() throws {
        try save(text: "alpha beta", dayOffset: 0, recordingMs: 1_000)
        try save(text: "gamma", dayOffset: 0, recordingMs: 1_000)
        try save(text: "delta epsilon", dayOffset: -3, recordingMs: 1_000)

        let payload = try service.load(currentModelId: "test-model")

        XCTAssertEqual(payload.header.activeDays7d, 2)
    }

    func testPerformanceLevelThresholds() throws {
        // no data
        var payload = try service.load(currentModelId: nil)
        XCTAssertEqual(payload.performance.level, .noData)

        // fast (<1200ms)
        try save(text: "a b c", dayOffset: 0, recordingMs: 1_000, processingMs: 900)
        payload = try service.load(currentModelId: nil)
        XCTAssertEqual(payload.performance.level, .fast)

        // normal (1200-2999ms)
        try save(text: "a b c", dayOffset: 0, recordingMs: 1_000, processingMs: 2_000)
        payload = try service.load(currentModelId: nil)
        XCTAssertEqual(payload.performance.level, .normal)

        // slow (>=3000ms)
        try save(text: "a b c", dayOffset: 0, recordingMs: 1_000, processingMs: 6_500)
        payload = try service.load(currentModelId: nil)
        XCTAssertEqual(payload.performance.level, .slow)
    }

    func testPerformanceTelemetryAveragesUseRecordedStageData() throws {
        try save(
            text: "alpha beta",
            dayOffset: 0,
            recordingMs: 1_000,
            processingMs: 1_300,
            latency: DictationLatencyTelemetry(
                settingsSyncMs: 5,
                transcriptionMs: 720,
                textProcessingMs: 9,
                injectionMs: 84,
                appActivationMs: 28,
                clipboardRestoreDelayMs: 76
            )
        )
        try save(
            text: "gamma delta",
            dayOffset: 0,
            recordingMs: 1_000,
            processingMs: 1_500,
            latency: DictationLatencyTelemetry(
                settingsSyncMs: 6,
                transcriptionMs: 880,
                textProcessingMs: 10,
                injectionMs: 92,
                appActivationMs: 34,
                clipboardRestoreDelayMs: 82
            )
        )

        let payload = try service.load(currentModelId: nil)
        XCTAssertEqual(payload.performance.averageTranscriptionMs, 800)
        XCTAssertEqual(payload.performance.averageInjectionMs, 88)
        XCTAssertEqual(payload.performance.processingP50Ms, 1_400)
        XCTAssertEqual(payload.performance.processingP95Ms, 1_490)
        XCTAssertEqual(payload.performance.sampleCount, 2)
    }

    func testPerformanceLatencyUsesCurrentModelOnlyWithPercentiles() throws {
        try save(
            text: "alpha one",
            dayOffset: 0,
            recordingMs: 1_000,
            processingMs: 1_000,
            modelId: "model-a",
            latency: DictationLatencyTelemetry(
                settingsSyncMs: 5,
                transcriptionMs: 100,
                textProcessingMs: 8,
                injectionMs: 50,
                appActivationMs: 10,
                clipboardRestoreDelayMs: 40
            )
        )
        try save(
            text: "alpha two",
            dayOffset: 0,
            recordingMs: 1_000,
            processingMs: 3_000,
            modelId: "model-a",
            latency: DictationLatencyTelemetry(
                settingsSyncMs: 7,
                transcriptionMs: 500,
                textProcessingMs: 9,
                injectionMs: 150,
                appActivationMs: 14,
                clipboardRestoreDelayMs: 44
            )
        )
        try save(
            text: "beta one",
            dayOffset: 0,
            recordingMs: 1_000,
            processingMs: 8_000,
            modelId: "model-b",
            latency: DictationLatencyTelemetry(
                settingsSyncMs: 8,
                transcriptionMs: 2_000,
                textProcessingMs: 11,
                injectionMs: 400,
                appActivationMs: 22,
                clipboardRestoreDelayMs: 48
            )
        )

        let payload = try service.load(currentModelId: "model-a")

        XCTAssertEqual(payload.performance.currentModelId, "model-a")
        XCTAssertEqual(payload.performance.sampleCount, 2)
        XCTAssertEqual(payload.performance.averageProcessingMs, 2_000)
        XCTAssertEqual(payload.performance.processingP50Ms, 2_000)
        XCTAssertEqual(payload.performance.processingP95Ms, 2_900)
        XCTAssertEqual(payload.performance.averageTranscriptionMs, 300)
        XCTAssertEqual(payload.performance.transcriptionP50Ms, 300)
        XCTAssertEqual(payload.performance.transcriptionP95Ms, 480)
        XCTAssertEqual(payload.performance.averageInjectionMs, 100)
        XCTAssertEqual(payload.performance.injectionP50Ms, 100)
        XCTAssertEqual(payload.performance.injectionP95Ms, 145)
    }

    func testRecentDictationIncludesMetadataAndSupportsDelete() throws {
        try save(
            text: "first entry with five words",
            dayOffset: 0,
            recordingMs: 2_000,
            processingMs: 1_500,
            minuteOffset: 0
        )
        try save(
            text: "second entry",
            dayOffset: 0,
            recordingMs: 2_000,
            processingMs: 900,
            minuteOffset: 1
        )

        var payload = try service.load(currentModelId: "test-model")

        XCTAssertEqual(payload.recent.count, 2)
        let newest = try XCTUnwrap(payload.recent.first)
        XCTAssertFalse(newest.fullText.isEmpty)
        XCTAssertEqual(newest.wordCount, 2)
        XCTAssertEqual(newest.processingMs, 900)

        try service.deleteRecentDictation(id: newest.id)

        payload = try service.load(currentModelId: "test-model")
        XCTAssertEqual(payload.recent.count, 1)
        XCTAssertEqual(payload.recent.first?.previewText, "first entry with five words")
    }

    func testRecentDictationsAreLimitedSanitizedAndFallbackAppName() throws {
        let longText = Array(repeating: "word", count: 40).joined(separator: " ")
        for index in 0..<13 {
            try save(
                text: "entry \(index)",
                dayOffset: 0,
                recordingMs: 1_500,
                processingMs: 900 + index,
                appName: "Notes",
                minuteOffset: index
            )
        }

        try save(
            text: "line one\nline two\rline three",
            dayOffset: 0,
            recordingMs: 2_000,
            processingMs: 1_100,
            appName: nil,
            minuteOffset: 100
        )
        try save(
            text: longText,
            dayOffset: 0,
            recordingMs: 2_000,
            processingMs: 1_200,
            appName: "   ",
            minuteOffset: 101
        )

        let payload = try service.load(currentModelId: "test-model")

        XCTAssertEqual(payload.recent.count, 12)
        let newest = try XCTUnwrap(payload.recent.first)
        XCTAssertEqual(newest.fullText, longText)
        XCTAssertEqual(newest.previewText.count, 123)
        XCTAssertTrue(newest.previewText.hasSuffix("..."))

        let multiline = payload.recent.first(where: { $0.fullText.contains("line one\nline two") })
        XCTAssertEqual(multiline?.previewText, "line one line two line three")
        XCTAssertEqual(multiline?.appName, "Unknown App")

        let longEntry = payload.recent.first(where: { $0.fullText == longText })
        XCTAssertEqual(longEntry?.appName, "Unknown App")
        XCTAssertEqual(longEntry?.previewText.count, 123)
        XCTAssertTrue(longEntry?.previewText.hasSuffix("...") == true)
    }

    func testDeleteRecentDictationNoOpWhenIdMissing() throws {
        try save(text: "existing entry", dayOffset: 0, recordingMs: 1_000)
        try service.deleteRecentDictation(id: 99_999)

        let payload = try service.load(currentModelId: "test-model")
        XCTAssertEqual(payload.recent.count, 1)
    }

    private func save(
        text: String,
        dayOffset: Int,
        recordingMs: Int,
        processingMs: Int = 1_000,
        modelId: String = "test-model",
        appName: String? = "TextEdit",
        minuteOffset: Int = 0,
        latency: DictationLatencyTelemetry? = nil
    ) throws {
        let day = calendar.date(byAdding: .day, value: dayOffset, to: now)!
        let createdAt = calendar.date(byAdding: .minute, value: minuteOffset, to: day) ?? day
        try db.saveTranscription(
            text: text,
            appName: appName,
            recordingMs: recordingMs,
            processingMs: processingMs,
            modelId: modelId,
            latency: latency,
            createdAt: createdAt
        )
    }

    private func makeDate(
        year: Int,
        month: Int,
        day: Int,
        hour: Int = 0,
        minute: Int = 0
    ) -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        components.second = 0
        return calendar.date(from: components)!
    }
}
