// CoachPracticeTests.swift
// OrttaaiTests
//
// Practice: reps are kept as numbers and check results, skills are mastered
// after three strong reps, today's rep follows the way you talk most, and a
// redo picks one of your own dictations that missed.

import CoachCore
import GRDB
import XCTest
@testable import Orttaai

final class CoachPracticeTests: XCTestCase {
    private let now = Date()

    private func makeDatabase() throws -> DatabaseManager {
        try DatabaseManager(dbQueue: try DatabaseQueue(path: ":memory:"))
    }

    private func rep(_ skill: String, score: Double?, met: Bool?, daysAgo: Double = 0) -> CoachRepRecord {
        let checks = [CheckResult(check: .judged(.finishLine), answer: met.map { $0 ? .yes : .no }, confidence: 0.9)]
        return CoachRepRecord(
            id: nil, skillID: skill, kind: CoachRepKind.drill.rawValue, spoken: true,
            createdAt: now.addingTimeInterval(-daysAgo * 86_400), score: score, skillMet: met,
            durationMs: 30_000, words: 60,
            checks: String(data: try! JSONEncoder().encode(checks), encoding: .utf8)!,
            persona: CoachPersona.editor.rawValue
        )
    }

    func testRepsKeepNumbersAndChecksOnly() throws {
        let db = try makeDatabase()
        let saved = try db.saveCoachRep(rep("finish-line", score: 4.2, met: true))
        XCTAssertNotNil(saved.id)
        let fetched = try XCTUnwrap(try db.fetchCoachReps().first)
        XCTAssertEqual(fetched.skill?.title, "Say what done looks like")
        XCTAssertEqual(fetched.checkResults.first?.answer, .yes)
        XCTAssertEqual(fetched.checkResults.first?.confidence, 0.9)
        let columns = try db.dbQueue.read { try $0.columns(in: "coach_rep").map(\.name) }
        XCTAssertFalse(columns.contains("text"))
    }

    func testThreeStrongRepsMasterASkill() {
        let reps = [
            rep("ask-first", score: 4.5, met: true, daysAgo: 3),
            rep("ask-first", score: 4.6, met: false, daysAgo: 2),
            rep("ask-first", score: 3.0, met: true, daysAgo: 2),
            rep("ask-first", score: 4.0, met: true, daysAgo: 1),
        ]
        var progress = CoachSkillProgress.make(reps)
        XCTAssertEqual(progress.reps, 4)
        XCTAssertEqual(progress.strongReps, 2)
        XCTAssertFalse(progress.mastered)
        XCTAssertEqual(try XCTUnwrap(progress.usual), (4.5 + 4.6 + 3.0 + 4.0) / 4, accuracy: 0.0001)
        progress = CoachSkillProgress.make(reps + [rep("ask-first", score: 5, met: true, daysAgo: 9)].map { $0 })
        XCTAssertTrue(progress.mastered)
    }

    func testMasteredSkillsComeBackForReviewAfterAWeek() {
        let old = CoachSkillProgress.make([
            rep("one-ask", score: 4.5, met: true, daysAgo: 12),
            rep("one-ask", score: 4.5, met: true, daysAgo: 11),
            rep("one-ask", score: 4.5, met: true, daysAgo: 10),
        ])
        XCTAssertTrue(old.mastered)
        XCTAssertTrue(old.reviewDue(now: now))
        XCTAssertFalse(CoachSkillProgress.make([rep("one-ask", score: 4.5, met: true)]).reviewDue(now: now))
    }

    func testSnapshotFollowsYourMostUsedWayOfTalkingAndMovesOnWhenMastered() throws {
        let db = try makeDatabase()
        for i in 0..<12 {
            let text = "Make the paste faster after switching apps and check the overlay timings in the log today."
            try db.saveTranscription(text: text, appName: "Claude", bundleID: "com.anthropic.claudefordesktop", recordingMs: 7_000, processingMs: 1, modelId: "m", rawText: text, createdAt: now.addingTimeInterval(-Double(i + 1) * 3_600))
        }
        try CoachIndexer.catchUp(database: db, skippingKeys: [])
        func build(_ reps: [CoachRepRecord]) throws -> CoachSnapshot {
            CoachSnapshotBuilder.build(inputs: try db.fetchCoachInputs(), habits: [], apps: [], overrides: [:], reps: reps, quotes: { _ in [:] }, now: now)
        }
        let fresh = try build([])
        XCTAssertEqual(fresh.busiestMode, .ai)
        XCTAssertEqual(fresh.currentSkill(in: .prompting).id, "task-first")
        XCTAssertEqual(fresh.todaysKind, .redo)
        XCTAssertEqual(fresh.level(of: .prompting), 1)

        let mastered = try build((0..<3).map { _ in rep("task-first", score: 4.5, met: true) })
        XCTAssertEqual(mastered.currentSkill(in: .prompting).id, "context")
        XCTAssertEqual(mastered.masteredCount(in: .prompting), 1)
        XCTAssertEqual(mastered.repsThisWeek, 3)
        XCTAssertTrue(mastered.repDays.contains(Calendar.current.startOfDay(for: now)))
    }

    func testRedoPicksOneOfYoursInTheTracksWayOfTalkingThatMissed() {
        func input(_ id: Int64, app: String, bundle: String, umUh: Int, words: Int = 40) -> CoachInput {
            CoachInput(id: id, createdAt: now.addingTimeInterval(-Double(id) * 600), bundleID: bundle, appName: app,
                       measures: DictationMeasures(words: words, umUh: umUh, phraseFillers: 0, wpm: 140, sentenceLengths: [10], repeats: 0, polishChangeRatio: 0, rawKnown: true))
        }
        let inputs = [
            input(1, app: "Slack", bundle: "com.tinyspeck.slackmacgap", umUh: 0),
            input(2, app: "Claude", bundle: "com.anthropic.claudefordesktop", umUh: 0),
            input(3, app: "Claude", bundle: "com.anthropic.claudefordesktop", umUh: 5),
            input(4, app: "Claude", bundle: "com.anthropic.claudefordesktop", umUh: 0, words: 5),
        ]
        let prompting = try! XCTUnwrap(CoachSkill.skill(id: "finish-line"))
        for _ in 0..<10 {
            XCTAssertTrue([2, 3].contains(CoachRepPlanner.redoSource(skill: prompting, inputs: inputs, overrides: [:], now: now)))
        }
        let fillers = try! XCTUnwrap(CoachSkill.skill(id: "fewer-umuh"))
        XCTAssertEqual(CoachRepPlanner.redoSource(skill: fillers, inputs: inputs, overrides: [:], now: now), 3)
        let messages = try! XCTUnwrap(CoachSkill.skill(id: "ask-first"))
        XCTAssertEqual(CoachRepPlanner.redoSource(skill: messages, inputs: inputs, overrides: [:], now: now), 1)
        XCTAssertNil(CoachRepPlanner.redoSource(skill: messages, inputs: inputs, overrides: ["com.tinyspeck.slackmacgap": .off], now: now))
    }

    func testRepFiguresCompareWithYourUsual() {
        let m = DictationMeasures(words: 100, umUh: 1, phraseFillers: 0, wpm: 150, sentenceLengths: [12, 20], repeats: 0, polishChangeRatio: 0, rawKnown: true)
        let usual = CoachSummary(Array(repeating: DictationMeasures(words: 100, umUh: 3, phraseFillers: 0, wpm: 140, sentenceLengths: [15], repeats: 0, polishChangeRatio: 0, rawKnown: true), count: 10))
        let spoken = CoachPracticeSession.figures(m, usual: usual, spoken: true)
        XCTAssertEqual(spoken.first?.label, "Ums and uhs")
        XCTAssertEqual(spoken.first?.better, true)
        XCTAssertEqual(spoken.first { $0.label == "Pace" }?.value, "150")
        let typed = CoachPracticeSession.figures(m, usual: usual, spoken: false)
        XCTAssertNil(typed.first { $0.label == "Ums and uhs" })
    }

    func testPersonasAreChosenPerWayOfTalking() {
        let defaults = UserDefaults.standard
        let saved = defaults.string(forKey: CoachPreferences.personasKey)
        defer {
            if let saved { defaults.set(saved, forKey: CoachPreferences.personasKey) } else { defaults.removeObject(forKey: CoachPreferences.personasKey) }
        }
        defaults.removeObject(forKey: CoachPreferences.personasKey)
        XCTAssertEqual(CoachPreferences.persona(for: .people), .mentor)
        CoachPreferences.setPersona(.sergeant, for: .ai)
        CoachPreferences.setPersona(.peer, for: .people)
        XCTAssertEqual(CoachPreferences.persona(for: .ai), .sergeant)
        XCTAssertEqual(CoachPreferences.persona(for: .people), .peer)
        // Writing hasn't been chosen: it takes the AI seat's coach.
        XCTAssertEqual(CoachPreferences.persona(for: .writing), .sergeant)
    }
}
