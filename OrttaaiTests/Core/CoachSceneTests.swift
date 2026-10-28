// CoachSceneTests.swift
// OrttaaiTests
//
// Phase 3: the judge's answers about real dictations are cached as numbers
// and deleted with the dictation, habits can track a judged skill, and the
// snapshot judges those habits from the cached answers.

import CoachCore
import GRDB
import XCTest
@testable import Orttaai

final class CoachSceneTests: XCTestCase {
    private let now = Date()

    private func makeDatabase() throws -> DatabaseManager {
        try DatabaseManager(dbQueue: try DatabaseQueue(path: ":memory:"))
    }

    func testHabitTargetsRoundTrip() {
        XCTAssertEqual(CoachHabitTarget(stored: "fillers"), .measure(.fillers))
        XCTAssertEqual(CoachHabitTarget(stored: "q:finishLine"), .question(.finishLine))
        XCTAssertNil(CoachHabitTarget(stored: "q:nonsense"))
        XCTAssertEqual(CoachHabitTarget.question(.askFirst).stored, "q:askFirst")
        XCTAssertEqual(CoachHabitTarget.question(.finishLine).title, "Say what done looks like")
    }

    func testJudgementsAreCachedAndDeletedWithTheDictation() throws {
        let db = try makeDatabase()
        let id = try db.saveTranscription(text: "Fix the paste and tell me when the test passes.", appName: "Claude", bundleID: "com.anthropic.claudefordesktop", recordingMs: 5_000, processingMs: 1, modelId: "m")
        try db.saveCoachJudgement(transcriptionId: id, question: .finishLine, model: "judge", answer: .yes, confidence: 0.9)
        try db.saveCoachJudgement(transcriptionId: id, question: .finishLine, model: "other", answer: .no, confidence: 0.6)
        XCTAssertEqual(try db.fetchCoachJudgements(question: .finishLine, model: "judge"), [id: true])
        XCTAssertEqual(try db.fetchCoachJudgements(question: .finishLine, model: "other"), [id: false])
        XCTAssertEqual(try db.countCoachJudgements(since: now.addingTimeInterval(-60)), 2)
        XCTAssertEqual(try db.fetchCoachText(id: id), "Fix the paste and tell me when the test passes.")
        XCTAssertTrue(try db.deleteTranscription(id: id))
        XCTAssertTrue(try db.fetchCoachJudgements(question: .finishLine, model: "judge").isEmpty)
        // A dictation deleted before its answer arrives isn't recorded.
        try db.saveCoachJudgement(transcriptionId: id, question: .finishLine, model: "judge", answer: .yes, confidence: 0.9)
        XCTAssertTrue(try db.fetchCoachJudgements(question: .finishLine, model: "judge").isEmpty)
    }

    func testJudgedHabitsAreJudgedFromCachedAnswers() throws {
        let db = try makeDatabase()
        let start = now.addingTimeInterval(-86_400)
        var ids: [(Int64, Bool)] = []
        for i in 0..<20 {
            let text = "Make the paste faster after switching apps, starting from the overlay log."
            let before = try db.saveTranscription(text: text, appName: "Claude", bundleID: "com.anthropic.claudefordesktop", recordingMs: 6_000, processingMs: 1, modelId: "m", rawText: text, createdAt: start.addingTimeInterval(-Double(i + 1) * 600))
            ids.append((before, false))
            let after = try db.saveTranscription(text: text + " Done when the test passes.", appName: "Claude", bundleID: "com.anthropic.claudefordesktop", recordingMs: 6_000, processingMs: 1, modelId: "m", rawText: text, createdAt: start.addingTimeInterval(Double(i + 1) * 600))
            ids.append((after, true))
        }
        try db.startCoachHabit(target: .question(.finishLine), mode: .ai, at: start)
        try CoachIndexer.catchUp(database: db, skippingKeys: [])
        let answers = Dictionary(uniqueKeysWithValues: ids.map { ($0.0, $0.1) })
        let snapshot = CoachSnapshotBuilder.build(
            inputs: try db.fetchCoachInputs(),
            habits: try db.fetchCoachHabits(),
            apps: [],
            overrides: [:],
            judgements: [.finishLine: answers],
            quotes: { (try? db.fetchCoachQuotes(ids: $0)) ?? [:] },
            now: now
        )
        let state = try XCTUnwrap(snapshot.habits.first)
        XCTAssertEqual(state.target, .question(.finishLine))
        XCTAssertNil(state.measure)
        XCTAssertEqual(state.verdict.beforeShare, 0)
        XCTAssertEqual(state.verdict.afterShare, 1)
        XCTAssertEqual(state.verdict.status, .working)
        XCTAssertEqual(state.unit, "of dictations")
        XCTAssertEqual(state.figure(0.5), "50%")
        XCTAssertNotNil(snapshot.caught)
        XCTAssertNil(snapshot.caught?.measure)
        XCTAssertEqual(snapshot.caught?.streak, 20)
    }

    func testAModelThatAgreesWithTheOthersRanksFirst() async {
        // With no server, nothing answers: every row reports no agreement.
        let setup = CoachModelSetup(provider: .ollama, endpoint: "http://127.0.0.1:1", coachModel: "a", judgeModel: "a")
        let rows = await CoachModelComparison.run(models: ["a", "b"], texts: ["one", "two"], question: .taskFirst, setup: setup, progress: { _ in })
        XCTAssertEqual(rows.map(\.answered), [0, 0])
        XCTAssertTrue(rows.allSatisfy { $0.agreement == nil && $0.msPerAnswer == nil })
    }
}
