// CoachMonthTests.swift
// OrttaaiTests
//
// Phase 4: the judge's answers are read back as points for the judged axes,
// the snapshot draws them on each way of talking's shape, and a month's
// report counts, compares and picks its best moment from that month alone.

import CoachCore
import GRDB
import XCTest
@testable import Orttaai

final class CoachMonthTests: XCTestCase {
    private let calendar = Calendar.current
    private lazy var september = calendar.date(from: DateComponents(year: 2026, month: 9, day: 1))!
    private lazy var august = calendar.date(from: DateComponents(year: 2026, month: 8, day: 1))!
    private lazy var now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 28, hour: 12))!

    private func makeDatabase() throws -> DatabaseManager {
        try DatabaseManager(dbQueue: try DatabaseQueue(path: ":memory:"))
    }

    @discardableResult
    private func save(_ db: DatabaseManager, _ text: String, at date: Date) throws -> Int64 {
        try db.saveTranscription(
            text: text,
            appName: "Claude",
            bundleID: "com.anthropic.claudefordesktop",
            recordingMs: 8_000,
            processingMs: 1,
            modelId: "m",
            // Different from the text, so it's kept: these dates are older
            // than raw transcripts, which is how Coach knows the fillers.
            rawText: text.lowercased(),
            createdAt: date
        )
    }

    private func rep(_ skill: CoachSkill, at date: Date, score: Double, met: Bool = true) -> CoachRepRecord {
        CoachRepRecord(id: nil, skillID: skill.id, kind: "drill", spoken: true, createdAt: date, score: score, skillMet: met, durationMs: 30_000, words: 40, checks: "[]", persona: "mentor")
    }

    func testJudgementsReadBackAsPointsByQuestion() throws {
        let db = try makeDatabase()
        let a = try save(db, "Fix the paste delay and tell me when the test passes.", at: now)
        let b = try save(db, "Make the overlay smaller.", at: now)
        try db.saveCoachJudgement(transcriptionId: a, question: .finishLine, model: "judge", answer: .yes, confidence: 0.9)
        try db.saveCoachJudgement(transcriptionId: b, question: .finishLine, model: "judge", answer: .partly, confidence: 0.5)
        try db.saveCoachJudgement(transcriptionId: b, question: .taskFirst, model: "judge", answer: .no, confidence: 0.8)
        try db.saveCoachJudgement(transcriptionId: a, question: .taskFirst, model: "other", answer: .yes, confidence: 0.8)
        let scores = try db.fetchCoachJudgementScores(model: "judge")
        XCTAssertEqual(scores[.finishLine], [a: 1, b: 0.5])
        XCTAssertEqual(scores[.taskFirst], [b: 0])
    }

    func testTheSnapshotDrawsJudgedAxesOnEachWayOfTalking() throws {
        let db = try makeDatabase()
        var answers: [Int64: Double] = [:]
        for i in 0..<10 {
            let id = try save(db, "Fix the paste delay after switching apps and tell me when the overlay test passes.", at: now.addingTimeInterval(-Double(i + 1) * 3_600))
            answers[id] = i < 5 ? 1 : 0
        }
        try CoachIndexer.catchUp(database: db, skippingKeys: [])
        let snapshot = CoachSnapshotBuilder.build(
            inputs: try db.fetchCoachInputs(),
            habits: [],
            apps: [],
            overrides: [:],
            axisJudgements: [.finishLine: answers],
            quotes: { _ in [:] },
            now: now
        )
        let ai = snapshot.shape(for: .ai)
        XCTAssertEqual(ai.axes.count, 6)
        XCTAssertEqual(ai.nowAxes[.question(.finishLine)], 0.5)
        XCTAssertNil(ai.nowAxes[.question(.taskFirst)])
        XCTAssertTrue(ai.waitsOnJudge)
        // The all-modes shape keeps the six counted axes.
        XCTAssertFalse(snapshot.allShape.axes.contains { $0.isJudged })
        XCTAssertTrue(snapshot.allShape.isComplete)
    }

    func testAMonthIsComparedWithTheOneBeforeAndPicksItsBestMoment() throws {
        let db = try makeDatabase()
        var scores: [Int64: Double] = [:]
        var septemberIDs: [Int64] = []
        for i in 0..<10 {
            let clean = try save(db, "Fix the paste delay after switching apps and tell me when the overlay test passes.", at: september.addingTimeInterval(Double(i) * 86_400 + 3_600))
            septemberIDs.append(clean)
            scores[clean] = 1
            let messy = try save(db, "Um fix the uh paste delay after um switching apps and uh tell me when it works please.", at: august.addingTimeInterval(Double(i) * 86_400 + 3_600))
            scores[messy] = 0.5
        }
        // October's dictations stay out of September's report.
        try save(db, "Um uh um uh this is October.", at: now)
        try CoachIndexer.catchUp(database: db, skippingKeys: [])

        let path = CoachSkill.all[0]
        let other = CoachSkill.all[1]
        let reps = [
            rep(path, at: august.addingTimeInterval(86_400), score: 4.5),
            rep(path, at: september.addingTimeInterval(86_400), score: 4.2),
            rep(path, at: september.addingTimeInterval(2 * 86_400), score: 4.8),
            rep(other, at: august.addingTimeInterval(86_400), score: 5),
            rep(other, at: august.addingTimeInterval(2 * 86_400), score: 5),
            rep(other, at: august.addingTimeInterval(3 * 86_400), score: 5),
            rep(other, at: september.addingTimeInterval(4 * 86_400), score: 2.5, met: false),
        ]
        let habits = [
            CoachHabitRecord(id: 1, measure: "fillers", mode: "ai", startedAt: september.addingTimeInterval(4 * 86_400), endedAt: nil),
            CoachHabitRecord(id: 2, measure: "pace", mode: nil, startedAt: august, endedAt: september.addingTimeInterval(2 * 86_400)),
            CoachHabitRecord(id: 3, measure: "repeats", mode: nil, startedAt: august, endedAt: august.addingTimeInterval(86_400)),
        ]

        let report = CoachMonthReportBuilder.build(
            month: september.addingTimeInterval(10 * 86_400),
            inputs: try db.fetchCoachInputs(),
            habits: habits,
            reps: reps,
            scores: [.finishLine: scores],
            overrides: [:],
            quotes: { (try? db.fetchCoachQuotes(ids: $0)) ?? [:] },
            now: now,
            calendar: calendar
        )

        XCTAssertEqual(report.month.start, september)
        XCTAssertFalse(report.isCurrent)
        XCTAssertEqual(report.firstMonth, august)
        XCTAssertEqual(report.dictations, 10)
        XCTAssertEqual(report.dictationsBefore, 10)
        XCTAssertEqual(report.daysDictated, 10)
        XCTAssertEqual(report.words, 10 * 15)
        XCTAssertEqual(report.reps, 3)

        // Fillers moved most everywhere; the judged finish line moved for AI.
        XCTAssertEqual(report.topGain?.axis, .measure(.fillers))
        XCTAssertNil(report.topGain?.mode)
        let finish = report.moves(for: .ai).first { $0.axis == .question(.finishLine) }
        XCTAssertEqual(finish?.now, 1)
        XCTAssertEqual(finish?.then, 0.5)
        XCTAssertTrue(report.moves(for: nil).allSatisfy { !$0.axis.isJudged })

        // Mastered in September: the skill whose third strong rep fell then.
        let mastered = report.tracks.flatMap(\.mastered)
        XCTAssertEqual(mastered.map(\.id), [path.id])
        XCTAssertEqual(report.bestRep?.score, 4.8)

        // Habits that ran during the month, including one stopped in it.
        XCTAssertEqual(Set(report.habits.compactMap(\.habit.id)), [1, 2])

        // The best moment met the top gain, in that month.
        let moment = try XCTUnwrap(report.bestMoment)
        XCTAssertEqual(moment.id, septemberIDs.last)
        XCTAssertEqual(report.bestMomentAxis, .measure(.fillers))
    }

    func testAnEmptyMonthHasNothingToShow() throws {
        let db = try makeDatabase()
        try save(db, "Fix the paste delay after switching apps and tell me when the overlay test passes.", at: now)
        try CoachIndexer.catchUp(database: db, skippingKeys: [])
        let report = CoachMonthReportBuilder.build(
            month: september,
            inputs: try db.fetchCoachInputs(),
            habits: [],
            reps: [],
            scores: [:],
            overrides: [:],
            quotes: { _ in [:] },
            now: now,
            calendar: calendar
        )
        XCTAssertTrue(report.isEmpty)
        XCTAssertNil(report.topGain)
        XCTAssertNil(report.bestMoment)
        XCTAssertEqual(report.firstMonth, calendar.dateInterval(of: .month, for: now)?.start)

        let current = CoachMonthReportBuilder.build(
            month: now,
            inputs: try db.fetchCoachInputs(),
            habits: [],
            reps: [],
            scores: [:],
            overrides: [:],
            quotes: { _ in [:] },
            now: now,
            calendar: calendar
        )
        XCTAssertTrue(current.isCurrent)
        XCTAssertEqual(current.dictations, 1)
    }
}
