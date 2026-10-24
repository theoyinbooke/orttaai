// MilestoneTests.swift
// OrttaaiTests

import GRDB
import XCTest
@testable import Orttaai

final class MilestoneStatsTests: XCTestCase {
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Chicago")!
        return calendar
    }()

    private func date(_ day: Int, _ hour: Int = 12, minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
    }

    private func dictation(_ day: Int, hour: Int = 12, words: Int = 20, seconds: Int = 10, app: String? = "Notes") -> MilestoneDictation {
        MilestoneDictation(createdAt: date(day, hour), words: words, recordingMs: seconds * 1_000, appName: app)
    }

    func testTotalsAndTheDayEachBadgeWasEarned() {
        let result = MilestoneStats.compute(
            dictations: [dictation(1, words: 600), dictation(2, words: 500), dictation(3, words: 10)],
            dictionaryEntryDates: [],
            calendar: calendar,
            now: date(3, 18)
        )
        XCTAssertEqual(result.stats.totalWords, 1_110)
        XCTAssertEqual(result.stats.dictations, 3)
        XCTAssertEqual(result.crossings["first-words"], date(1))
        XCTAssertEqual(result.crossings["words-1k"], date(2), "the dictation that crossed 1,000 earns it")
        XCTAssertNil(result.crossings["words-5k"])
    }

    func testStreaksUseLocalDaysAndKeepTheBestRun() {
        let result = MilestoneStats.compute(
            dictations: [dictation(1), dictation(2), dictation(2, hour: 20), dictation(3), dictation(6), dictation(7)],
            dictionaryEntryDates: [],
            calendar: calendar,
            now: date(8, 9)
        )
        XCTAssertEqual(result.stats.bestStreakDays, 3)
        XCTAssertEqual(result.stats.currentStreakDays, 2, "6th and 7th, still running on the 8th")
        XCTAssertEqual(result.crossings["streak-3"], date(3))

        let broken = MilestoneStats.compute(
            dictations: [dictation(1), dictation(2)],
            dictionaryEntryDates: [],
            calendar: calendar,
            now: date(9)
        )
        XCTAssertEqual(broken.stats.currentStreakDays, 0)
        XCTAssertEqual(broken.stats.bestStreakDays, 2)
    }

    func testShortClipsCannotSetASpeedRecord() {
        let result = MilestoneStats.compute(
            dictations: [
                dictation(1, words: 4, seconds: 1),
                dictation(1, words: 30, seconds: 12),
            ],
            dictionaryEntryDates: [],
            calendar: calendar,
            now: date(1)
        )
        XCTAssertEqual(result.stats.bestWPM, 150)
        XCTAssertNotNil(result.crossings["quick-talker"])
        XCTAssertNil(result.crossings["lightning"])
    }

    func testTimeSavedIsTypingTimeMinusSpeakingTime() {
        // 2,005 words typed at 40 WPM take 50 minutes; spoken in 11.
        let stats = MilestoneStats.compute(
            dictations: [dictation(1, words: 2_005, seconds: 11 * 60)],
            dictionaryEntryDates: [],
            calendar: calendar,
            now: date(1)
        ).stats
        XCTAssertEqual(stats.minutesSaved, 39)
        XCTAssertEqual(stats.averageWPM, 182)
    }

    func testAppsNightOwlMarathonAndDictionary() {
        let result = MilestoneStats.compute(
            dictations: [
                dictation(1, app: "Notes"),
                dictation(1, app: "notes "),
                dictation(2, app: "Mail"),
                dictation(3, hour: 1, seconds: 75, app: "Claude"),
            ],
            dictionaryEntryDates: (1...10).map { date($0) },
            calendar: calendar,
            now: date(10)
        )
        XCTAssertEqual(result.stats.distinctApps, 3, "app names compare without case or spaces")
        XCTAssertEqual(result.crossings["three-apps"], date(3, 1))
        XCTAssertEqual(result.crossings["night-owl"], date(3, 1))
        XCTAssertEqual(result.crossings["marathon"], date(3, 1))
        XCTAssertEqual(result.crossings["wordsmith"], date(10), "the 10th dictionary word earns it")
    }

    func testCatalogHasTwentyTwoUniqueBadges() {
        XCTAssertEqual(MilestoneCatalog.badges.count, 22)
        XCTAssertEqual(Set(MilestoneCatalog.badges.map(\.id)).count, 22)
        for family in MilestoneFamily.allCases {
            XCTAssertFalse(MilestoneCatalog.badges.filter { $0.family == family }.isEmpty)
        }
    }
}

final class MilestoneComparisonsTests: XCTestCase {
    func testHeightsPagesAndKeyPresses() {
        XCTAssertEqual(MilestoneComparisons.heightText(words: 2_005), "24 m")
        XCTAssertEqual(MilestoneComparisons.heightText(words: 500_000), "6.0 km")
        XCTAssertEqual(MilestoneComparisons.storeys(words: 2_005), 8)
        XCTAssertEqual(MilestoneComparisons.pages(words: 2_005), 8)
        XCTAssertEqual(MilestoneComparisons.keyPresses(words: 2_005), 11_429)
        XCTAssertEqual(MilestoneComparisons.typingMinutes(words: 2_005), 50)
    }

    func testLandmarks() {
        XCTAssertEqual(MilestoneComparisons.landmarks.first?.wordsToReach, 7_750)
        XCTAssertEqual(MilestoneComparisons.nextLandmark(after: 2_005)?.name, "Statue of Liberty")
        XCTAssertNil(MilestoneComparisons.lastLandmark(passedBy: 2_005))
        XCTAssertEqual(MilestoneComparisons.lastLandmark(passedBy: 500_000)?.name, "Kilimanjaro")
        XCTAssertEqual(MilestoneComparisons.nextLandmark(after: 500_000)?.name, "Everest")
    }

    func testMultiplesAndDurations() {
        XCTAssertEqual(MilestoneComparisons.multiple(of: 179, over: MilestoneComparisons.typingWPM), "4.5")
        XCTAssertEqual(MilestoneComparisons.multiple(of: 179, over: MilestoneComparisons.handwritingWPM), "14")
        XCTAssertEqual(MilestoneComparisons.multiple(of: 80, over: MilestoneComparisons.typingWPM), "2")
        XCTAssertEqual(MilestoneComparisons.durationText(minutes: 39), "39 min")
        XCTAssertEqual(MilestoneComparisons.durationText(minutes: 125), "2 h 5 min")
        XCTAssertEqual(MilestoneComparisons.durationText(minutes: 1_250), "21 hours")
        XCTAssertEqual(MilestoneComparisons.timeBackEquivalent(minutes: 39), "a TV episode")
        XCTAssertEqual(MilestoneComparisons.longestBookPassed(words: 50_000)?.title, "The Great Gatsby")
    }
}

@MainActor
final class MilestoneStoreTests: XCTestCase {
    private func makeDatabase() throws -> DatabaseManager {
        try DatabaseManager(dbQueue: try DatabaseQueue(path: ":memory:"))
    }

    func testUnlocksKeepTheirFirstDateAndCelebrationIsRecorded() throws {
        let db = try makeDatabase()
        let first = Date(timeIntervalSince1970: 1_000)
        let inserted = try db.insertMilestoneUnlocks([MilestoneUnlock(badgeID: "first-words", unlockedAt: first)])
        XCTAssertEqual(inserted.count, 1)

        let again = try db.insertMilestoneUnlocks([MilestoneUnlock(badgeID: "first-words", unlockedAt: Date())])
        XCTAssertTrue(again.isEmpty)
        XCTAssertEqual(try db.fetchMilestoneUnlocks().first?.unlockedAt, first)

        try db.markMilestonesCelebrated(["first-words"])
        XCTAssertNotNil(try db.fetchMilestoneUnlocks().first?.celebratedAt)
    }

    func testInputsCountDictationsButNotEditCommandsOrText() throws {
        let db = try makeDatabase()
        _ = try db.saveTranscription(text: "one two three", appName: "Notes", recordingMs: 2_000, processingMs: 10, modelId: "m")
        _ = try db.saveTranscription(text: "make it shorter", appName: "Notes", recordingMs: 1_000, processingMs: 10, modelId: "m", entryKind: Transcription.editEntryKind)

        let inputs = try db.fetchMilestoneInputs()
        XCTAssertEqual(inputs.dictations.map(\.words), [3])
        XCTAssertEqual(inputs.dictations.first?.appName, "Notes")
    }

    func testDeletingHistoryKeepsEarnedBadges() async throws {
        let db = try makeDatabase()
        let id = try db.saveTranscription(text: "hello there", appName: "Notes", recordingMs: 2_000, processingMs: 10, modelId: "m")
        let center = MilestoneCenter()
        center.start(database: db)
        for _ in 0..<200 where center.unlocks["first-words"] == nil {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertNotNil(center.unlocks["first-words"])
        // Night Owl may join it when the test runs after midnight.
        XCTAssertEqual(center.badgesAwaitingCelebration.first?.id, "first-words")

        _ = try db.deleteTranscription(id: id)
        await center.refresh()
        XCTAssertNotNil(center.unlocks["first-words"], "a badge, once earned, stays")
        XCTAssertEqual(center.stats.dictations, 0)

        center.markCelebrated(center.badgesAwaitingCelebration)
        XCTAssertTrue(center.badgesAwaitingCelebration.isEmpty)
    }
}
