// CoachTests.swift
// OrttaaiTests
//
// Coach's storage and snapshot: counts are numbers keyed to a dictation,
// apps switched off are never read, deleting a dictation deletes its counts,
// and habits are judged on the right way of talking. The counting rules
// themselves are pinned in LocalPackages/CoachCore.

import CoachCore
import GRDB
import XCTest
@testable import Orttaai

final class CoachTests: XCTestCase {
    private let now = Date()

    private func makeDatabase() throws -> DatabaseManager {
        try DatabaseManager(dbQueue: try DatabaseQueue(path: ":memory:"))
    }

    @discardableResult
    private func save(
        _ db: DatabaseManager,
        _ text: String,
        raw: String? = nil,
        app: String = "Slack",
        bundle: String? = "com.tinyspeck.slackmacgap",
        ms: Int = 10_000,
        daysAgo: Double = 1,
        kind: String? = nil
    ) throws -> Int64 {
        try db.saveTranscription(
            text: text,
            appName: app,
            bundleID: bundle,
            recordingMs: ms,
            processingMs: 10,
            modelId: "m",
            rawText: raw,
            entryKind: kind,
            createdAt: now.addingTimeInterval(-daysAgo * 86_400)
        )
    }

    func testIndexingCountsDictationsButNotEditCommands() throws {
        let db = try makeDatabase()
        try save(db, "So, the plan is done.", raw: "Um so, the the plan is done.")
        try save(db, "make it shorter", kind: Transcription.editEntryKind)
        try CoachIndexer.catchUp(database: db, skippingKeys: [])

        let inputs = try db.fetchCoachInputs()
        XCTAssertEqual(inputs.count, 1)
        let m = try XCTUnwrap(inputs.first?.measures)
        XCTAssertEqual(m.umUh, 1)
        XCTAssertEqual(m.repeats, 1)
        XCTAssertTrue(m.rawKnown)
        XCTAssertEqual(m.sentenceLengths, [7])
        XCTAssertTrue(try db.fetchCoachBacklog(skippingKeys: []).isEmpty)
    }

    func testRowsFromBeforeRawTranscriptsGiveOnlyAPace() throws {
        let db = try makeDatabase()
        let old = try db.saveTranscription(
            text: "The polished text without any of the fillers that were said.",
            appName: "Notes", bundleID: "com.apple.Notes", recordingMs: 5_000, processingMs: 10, modelId: "m",
            createdAt: CoachIndexSource.rawKeptSince.addingTimeInterval(-86_400)
        )
        try CoachIndexer.catchUp(database: db, skippingKeys: [])
        let m = try XCTUnwrap(try db.fetchCoachInputs().first { $0.id == old }?.measures)
        XCTAssertFalse(m.rawKnown)
        XCTAssertNil(m.polishChangeRatio)
        XCTAssertNil(CoachMeasure.fillers.value(of: m))
        XCTAssertNotNil(CoachMeasure.pace.value(of: m))
    }

    func testAppsSwitchedOffAreNeverRead() throws {
        let db = try makeDatabase()
        try save(db, "A message for the team about the release.")
        try save(db, "A prompt for Claude about the paste timing.", app: "Claude", bundle: "com.anthropic.claudefordesktop")

        try CoachIndexer.catchUp(database: db, skippingKeys: ["com.tinyspeck.slackmacgap"])
        let inputs = try db.fetchCoachInputs()
        XCTAssertEqual(inputs.map(\.appName), ["Claude"])
        // Nothing left in the backlog either: off apps aren't waiting.
        XCTAssertTrue(try db.fetchCoachBacklog(skippingKeys: ["com.tinyspeck.slackmacgap"]).isEmpty)

        // Switching an app off afterwards forgets what was counted.
        try CoachIndexer.catchUp(database: db, skippingKeys: [])
        XCTAssertEqual(try db.fetchCoachInputs().count, 2)
        try db.deleteCoachMetrics(forKeys: ["com.anthropic.claudefordesktop"])
        XCTAssertEqual(try db.fetchCoachInputs().map(\.appName), ["Slack"])
    }

    func testAppsAreListedByKeyWithNamesOnlyRowsToo() throws {
        let db = try makeDatabase()
        try save(db, "one")
        try save(db, "two")
        try save(db, "three", app: "Codex", bundle: nil)
        let apps = try db.fetchCoachApps()
        XCTAssertEqual(apps.map(\.key), ["com.tinyspeck.slackmacgap", "name:codex"])
        XCTAssertEqual(apps.first?.dictations, 2)
        XCTAssertEqual(apps.last?.displayName, "Codex")
    }

    func testDeletingADictationDeletesItsCountsAndQuote() throws {
        let db = try makeDatabase()
        let id = try save(db, "This is a dictation worth quoting later on.")
        try CoachIndexer.catchUp(database: db, skippingKeys: [])
        XCTAssertNotNil(try db.fetchCoachQuotes(ids: [id])[id])
        XCTAssertTrue(try db.deleteTranscription(id: id))
        XCTAssertTrue(try db.fetchCoachInputs().isEmpty)
        XCTAssertTrue(try db.fetchCoachQuotes(ids: [id]).isEmpty)
    }

    func testHabitsStartAndEnd() throws {
        let db = try makeDatabase()
        let habit = try db.startCoachHabit(measure: .fillers, mode: .people, at: now)
        XCTAssertEqual(try db.fetchCoachHabits().first?.coachMode, .people)
        try db.endCoachHabit(id: try XCTUnwrap(habit.id), at: now)
        XCTAssertNotNil(try db.fetchCoachHabits().first?.endedAt)
    }

    func testSnapshotJudgesHabitsOnTheirWayOfTalking() throws {
        let db = try makeDatabase()
        // After raw transcripts were kept, so fillers can be told.
        let start = now.addingTimeInterval(-86_400)
        // People: ums before the habit, none since. AI stays full of ums.
        for i in 0..<20 {
            let text = "Um, could you review the notes before three? Um, they are in the doc today."
            try db.saveTranscription(text: text, appName: "Slack", bundleID: "com.tinyspeck.slackmacgap", recordingMs: 6_000, processingMs: 1, modelId: "m", rawText: text, createdAt: start.addingTimeInterval(-Double(i + 1) * 600))
            let clean = "Could you review the notes before three today? They are in the doc for you."
            try db.saveTranscription(text: clean, appName: "Slack", bundleID: "com.tinyspeck.slackmacgap", recordingMs: 6_000, processingMs: 1, modelId: "m", rawText: clean, createdAt: start.addingTimeInterval(Double(i + 1) * 600))
            let ai = "Um, um, make the paste faster, um, after switching apps, um, please and thanks."
            try db.saveTranscription(text: ai, appName: "Claude", bundleID: "com.anthropic.claudefordesktop", recordingMs: 6_000, processingMs: 1, modelId: "m", rawText: ai, createdAt: start.addingTimeInterval(Double(i + 1) * 600))
        }
        try db.startCoachHabit(measure: .fillers, mode: .people, at: start)
        try CoachIndexer.catchUp(database: db, skippingKeys: [])

        let snapshot = CoachSnapshotBuilder.build(
            inputs: try db.fetchCoachInputs(),
            habits: try db.fetchCoachHabits(),
            apps: try db.fetchCoachApps(),
            overrides: [:],
            quotes: { (try? db.fetchCoachQuotes(ids: $0)) ?? [:] },
            now: now
        )
        let state = try XCTUnwrap(snapshot.habits.first)
        XCTAssertEqual(state.verdict.beforeShare, 0)
        XCTAssertEqual(state.verdict.afterShare, 1)
        XCTAssertEqual(state.verdict.status, .working)
        XCTAssertNotNil(state.example)
        XCTAssertEqual(snapshot.caught?.measure, .fillers)
        XCTAssertEqual(snapshot.caught?.streak, 20)
        // The AI dictations kept their ums and became the focus there.
        XCTAssertEqual(snapshot.focus?.measure, .fillers)
        XCTAssertEqual(snapshot.focus?.mode, .ai)
        XCTAssertEqual(snapshot.week.count, 7)
    }

    func testOverridesMoveAndHideApps() throws {
        let db = try makeDatabase()
        try save(db, "A note to myself about tomorrow's plan for the release.", app: "Safari", bundle: "com.apple.Safari")
        try CoachIndexer.catchUp(database: db, skippingKeys: [])
        let inputs = try db.fetchCoachInputs()
        func build(_ overrides: [String: CoachAppRule]) -> CoachSnapshot {
            CoachSnapshotBuilder.build(inputs: inputs, habits: [], apps: [], overrides: overrides, quotes: { _ in [:] }, now: now)
        }
        XCTAssertEqual(build([:]).recentByMode[.elsewhere], 1)
        XCTAssertEqual(build(["com.apple.safari": .writing]).recentByMode[.writing], 1)
        XCTAssertEqual(build(["com.apple.safari": .off]).dictations, 0)
    }
}
