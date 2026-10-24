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

    func testLargeCountsAreRounded() {
        XCTAssertEqual(MilestoneComparisons.landmarks.first { $0.name == "Kilimanjaro" }?.wordsToReach, 491_000)
        XCTAssertEqual(MilestoneComparisons.keyPressesText(words: 2_005), "~11,400")
        XCTAssertEqual(MilestoneComparisons.keyPressesText(words: 100), "~570")
    }

    func testCelebrationLinesUseThePersonsNumbers() {
        var stats = MilestoneStats()
        stats.totalWords = 2_005
        stats.dictations = 20
        stats.bestWPM = 179
        stats.speakingMs = 11 * 60_000
        let line = { (id: String) in MilestoneCopy.celebrationLine(for: MilestoneCatalog.badge(withID: id)!, stats: stats) }
        XCTAssertEqual(line("words-1k"), "2,005 words: 8 pages of a book, and 24 m tall stood on end.")
        XCTAssertEqual(line("quick-talker"), "179 words a minute, 4.5× faster than typing.")
        XCTAssertEqual(line("first-words"), "Your first dictation is in. Welcome to talking instead of typing.")
        XCTAssertTrue(line("hour-saved").contains("39 min of typing back"))
        for badge in MilestoneCatalog.badges {
            XCTAssertFalse(MilestoneCopy.celebrationLine(for: badge, stats: stats).isEmpty, badge.id)
        }
    }

    func testMultiplesAndDurations() {
        XCTAssertEqual(MilestoneComparisons.multiple(of: 179, over: MilestoneComparisons.typingWPM), "4.5")
        XCTAssertEqual(MilestoneComparisons.multiple(of: 179, over: MilestoneComparisons.handwritingWPM), "14")
        XCTAssertEqual(MilestoneComparisons.multiple(of: 80, over: MilestoneComparisons.typingWPM), "2")
        XCTAssertEqual(MilestoneComparisons.durationText(minutes: 39), "39 min")
        XCTAssertEqual(MilestoneComparisons.durationText(minutes: 60), "1 hour")
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

final class ShareCardKindTests: XCTestCase {
    private var stats: MilestoneStats {
        var stats = MilestoneStats()
        stats.totalWords = 2_684
        stats.dictations = 31
        stats.speakingMs = 1_070_000
        stats.bestWPM = 176
        stats.distinctApps = 3
        stats.longestDictationMs = 72_000
        stats.dictionaryWords = 12
        return stats
    }

    private let sharedDesigns: Set<ShareCardTemplate> = [.signal, .editorial, .medal, .receipt]

    func testEveryBadgeLeadsWithADesignAboutItsKind() {
        for badge in MilestoneCatalog.badges {
            let kind = ShareCardKind(badge: badge)
            let templates = kind.templates
            XCTAssertTrue(templates.contains(.medal), badge.id)
            XCTAssertEqual(Set(templates).count, templates.count, badge.id)
            if kind != .firstWords {
                XCTAssertFalse(sharedDesigns.contains(templates[0]), "\(badge.id) should open on its own picture")
            }
        }
        XCTAssertEqual(ShareCardKind(badge: nil).templates.count, 8)
    }

    func testKindsOfferDifferentDesigns() {
        let apps = ShareCardKind(badge: MilestoneCatalog.badge(withID: "three-apps")).templates
        let words = ShareCardKind(badge: MilestoneCatalog.badge(withID: "words-1k")).templates
        XCTAssertTrue(apps.contains(.apps))
        XCTAssertFalse(apps.contains(.mountain), "Height in words says nothing about apps")
        XCTAssertTrue(words.contains(.mountain))
    }

    func testCardsTellTheMilestonesOwnNumber() throws {
        let thousand = try XCTUnwrap(MilestoneCatalog.badge(withID: "words-1k"))
        let words = ShareCardContent(stats: stats, badge: thousand, earnedOn: nil)
        XCTAssertEqual(words.words, 1_000, "1,000 Words is about 1,000 words, not the running total")
        XCTAssertEqual(words.headline.emphasis, "1,000 words")

        let apps = ShareCardContent(stats: stats, badge: MilestoneCatalog.badge(withID: "three-apps"), earnedOn: nil)
        XCTAssertEqual(apps.headline.emphasis, "3 apps")
        XCTAssertEqual(apps.supportingStats.first?.value, "3")

        let marathon = ShareCardContent(stats: stats, badge: MilestoneCatalog.badge(withID: "marathon"), earnedOn: nil)
        XCTAssertEqual(marathon.headline.emphasis, "1 min 12 s")

        let headlines = Set(MilestoneCatalog.badges.map {
            ShareCardContent(stats: stats, badge: $0, earnedOn: nil).headline.emphasis + "|" + ShareCardContent(stats: stats, badge: $0, earnedOn: nil).headline.tail
        })
        XCTAssertGreaterThan(headlines.count, 15, "Badges say different things")
    }
}
