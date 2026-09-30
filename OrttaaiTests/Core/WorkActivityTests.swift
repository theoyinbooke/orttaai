// WorkActivityTests.swift
// OrttaaiTests

import XCTest
@testable import Orttaai

final class WorkActivityTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func source(_ id: Int64, minutesAgo: Double, app: String = "Code", _ text: String) -> ConceptSource {
        ConceptSource(id: id, text: text, createdAt: now.addingTimeInterval(-minutesAgo * 60), targetAppName: app)
    }

    func testSessionsSplitByAppAndGap() {
        let sessions = WorkSessionBuilder.sessions(sources: [
            source(1, minutesAgo: 120, "Add the export button."),
            source(2, minutesAgo: 110, "Wire it to the file picker."),
            source(3, minutesAgo: 105, app: "Mail", "Reply to the client."),
            source(4, minutesAgo: 10, "Now the settings page.")
        ])
        XCTAssertEqual(sessions.map(\.dictationIDs), [[1, 2], [3], [4]])
        XCTAssertTrue(sessions[0].text.contains("file picker"))
    }

    func testSessionKeyChangesWhenSessionGrows() {
        let before = WorkSessionBuilder.sessions(sources: [source(1, minutesAgo: 20, "Start the refactor.")])
        let after = WorkSessionBuilder.sessions(sources: [
            source(1, minutesAgo: 20, "Start the refactor."),
            source(2, minutesAgo: 5, "Now split the view.")
        ])
        XCTAssertNotEqual(before.first?.key, after.first?.key)
    }

    func testHeuristicsReadFixingAndFriction() {
        let session = WorkSessionBuilder.sessions(sources: [
            source(1, minutesAgo: 5, "The export is still broken. It crashes with an error when I click save. Fix the bug please.")
        ])[0]
        let analysis = SessionHeuristics.analyze(session)
        XCTAssertEqual(analysis.activity, .fixing)
        XCTAssertNotNil(analysis.friction)
        XCTAssertTrue(analysis.isEstimate)
    }

    func testHeuristicsDoNotInventFriction() {
        let session = WorkSessionBuilder.sessions(sources: [
            source(1, minutesAgo: 5, "The title should still show on one line, and you can't hide the icon. Make the card compact.")
        ])[0]
        XCTAssertNil(SessionHeuristics.analyze(session).friction)
    }

    func testDecodesModelResponse() {
        let response = """
        {"activity":"designing","subject":"Orttaai settings","goal":"Make the settings page compact.","friction":"Toggles misaligned","friction_type":"layout","decision":null,"open_question":"Should About move?"}
        """
        let analysis = SessionModelAnalyzer.decode(response, model: "gemma4:e2b")
        XCTAssertEqual(analysis?.activity, .designing)
        XCTAssertEqual(analysis?.goal, "Make the settings page compact")
        XCTAssertEqual(analysis?.frictionType, .layout)
        XCTAssertNil(analysis?.decision)
        XCTAssertEqual(analysis?.model, "gemma4:e2b")
        XCTAssertFalse(analysis?.isEstimate ?? true)
    }

    func testDecodeDropsFrictionTypeWithoutFriction() {
        let analysis = SessionModelAnalyzer.decode(
            #"{"activity":"planning","subject":"x","goal":"y","friction":"null","friction_type":"bugs","decision":null,"open_question":null}"#,
            model: "m"
        )
        XCTAssertNil(analysis?.friction)
        XCTAssertNil(analysis?.frictionType)
    }

    func testDecodeRejectsGarbage() {
        XCTAssertNil(SessionModelAnalyzer.decode("I could not do that.", model: "m"))
    }

    // MARK: - Report

    private func analyzed(
        _ id: Int64,
        daysAgo: Double,
        _ activity: WorkActivity,
        concepts: [String] = [],
        friction: FrictionType? = nil,
        decision: String? = nil
    ) -> AnalyzedSession {
        let date = now.addingTimeInterval(-daysAgo * 86_400)
        return AnalyzedSession(
            session: WorkSession(key: "s\(id)", dictationIDs: [id], start: date, end: date, appName: "Code", text: "", conceptKeys: concepts),
            analysis: SessionAnalysis(
                activity: activity,
                subject: nil,
                goal: "Goal \(id)",
                friction: friction == nil ? nil : "Something broke",
                frictionType: friction,
                decision: decision,
                openQuestion: nil,
                model: "m"
            )
        )
    }

    func testReportSharesProjectsAndFriction() {
        let sessions = [
            analyzed(1, daysAgo: 1, .fixing, concepts: ["orttaai"], friction: .bugs),
            analyzed(2, daysAgo: 2, .fixing, concepts: ["orttaai"], friction: .bugs),
            analyzed(3, daysAgo: 3, .designing, concepts: ["orttaai"], friction: .layout),
            analyzed(4, daysAgo: 4, .planning, concepts: ["meetumo"], decision: "Ship on Friday"),
            analyzed(5, daysAgo: 60, .writing)
        ]
        let report = ActivityReportBuilder.build(
            sessions: sessions,
            range: .month,
            projects: [ProjectCandidate(key: "orttaai", title: "Orttaai", salience: 5), ProjectCandidate(key: "meetumo", title: "Meetumo", salience: 3)],
            now: now
        )
        XCTAssertEqual(report.sessionCount, 4)
        XCTAssertEqual(report.activities.first?.activity, .fixing)
        XCTAssertEqual(report.activities.first?.share ?? 0, 0.5, accuracy: 0.001)
        XCTAssertEqual(report.frictions.first?.type, .bugs)
        XCTAssertEqual(report.frictions.first?.sessions, 2)
        XCTAssertEqual(report.projects.first?.title, "Orttaai")
        XCTAssertEqual(report.projects.first?.sessions, 3)
        XCTAssertEqual(report.projects.first?.topFriction, .bugs)
        XCTAssertEqual(report.decisions.first?.text, "Ship on Friday")
        XCTAssertEqual(report.decisions.first?.project, "Meetumo")
        XCTAssertTrue(report.headline.contains { $0.contains("fixing problems") })
    }

    func testReportResolvesAliasesToProjects() {
        let report = ActivityReportBuilder.build(
            sessions: [analyzed(1, daysAgo: 1, .building, concepts: ["mitumo"]), analyzed(2, daysAgo: 2, .building, concepts: ["meetumo"])],
            range: .month,
            projects: [ProjectCandidate(key: "meetumo", title: "Meetumo", salience: 3)],
            aliases: ["mitumo": "meetumo"],
            now: now
        )
        XCTAssertEqual(report.projects.first?.sessions, 2)
    }

    func testEmptyRangeGivesEmptyReport() {
        let report = ActivityReportBuilder.build(sessions: [analyzed(1, daysAgo: 60, .writing)], range: .week, projects: [], now: now)
        XCTAssertEqual(report.sessionCount, 0)
        XCTAssertTrue(report.headline.isEmpty)
    }
}
