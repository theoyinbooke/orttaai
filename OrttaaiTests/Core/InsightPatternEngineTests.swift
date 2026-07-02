// InsightPatternEngineTests.swift
// OrttaaiTests

import XCTest
@testable import Orttaai

final class InsightPatternEngineTests: XCTestCase {
    private var calendar: Calendar!
    private var now: Date!

    override func setUp() {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0)!
        calendar = utc
        now = utc.date(from: DateComponents(year: 2026, month: 7, day: 1, hour: 22))!
    }

    private func makeInput(
        activity: [InsightPatternEngine.ActivitySample] = [],
        nodes: [SemanticGraphNode] = [],
        edges: [SemanticGraphEdge] = [],
        chunkDates: [Int64: Date] = [:],
        signals: [SemanticSignalWithContext] = []
    ) -> InsightPatternEngine.Input {
        InsightPatternEngine.Input(
            activity: activity,
            graph: SemanticMemoryGraph(nodes: nodes, edges: edges),
            chunkDates: chunkDates,
            signals: signals,
            now: now,
            calendar: calendar
        )
    }

    private func sample(daysAgo: Int, hour: Int, words: Int = 40, ms: Int = 20_000) -> InsightPatternEngine.ActivitySample {
        let day = calendar.date(byAdding: .day, value: -daysAgo, to: calendar.startOfDay(for: now))!
        let date = calendar.date(byAdding: .hour, value: hour, to: day)!
        return .init(createdAt: date, wordCount: words, recordingMs: ms, appName: "Codex")
    }

    private func signalContext(
        family: SemanticSignalFamily,
        value: String,
        daysAgo: Int,
        chunkID: Int64,
        chunkText: String? = nil,
        confidence: Double = 0.9
    ) -> SemanticSignalWithContext {
        let date = calendar.date(byAdding: .day, value: -daysAgo, to: now)!
        return SemanticSignalWithContext(
            signal: SemanticSignal(
                chunkID: chunkID,
                family: family.rawValue,
                value: value,
                confidence: confidence,
                modelID: "heuristic-v1",
                extractedAt: date
            ),
            chunkText: chunkText ?? value,
            sourceCreatedAt: date,
            targetAppName: "Codex",
            transcriptionID: chunkID
        )
    }

    func testRhythmFindsPeakHours() {
        // 20 dictations, 14 of them between 21:00 and 23:59.
        var activity: [InsightPatternEngine.ActivitySample] = []
        for day in 0..<7 {
            activity.append(sample(daysAgo: day, hour: 21))
            activity.append(sample(daysAgo: day, hour: 22))
        }
        for day in 0..<6 {
            activity.append(sample(daysAgo: day, hour: 10))
        }

        let findings = InsightPatternEngine.computeFindings(makeInput(activity: activity))
        let rhythm = findings.first { $0.kind == .rhythm && $0.subjectKey == "peak-hours" }

        XCTAssertNotNil(rhythm)
        XCTAssertGreaterThanOrEqual(rhythm!.magnitude, 0.5)
        XCTAssertTrue(rhythm!.title.contains("9pm") || rhythm!.title.contains("8pm") || rhythm!.title.contains("10pm"),
                      "unexpected window: \(rhythm!.title)")
    }

    func testRhythmRequiresEnoughSamples() {
        let activity = (0..<5).map { sample(daysAgo: $0, hour: 21) }
        let findings = InsightPatternEngine.computeFindings(makeInput(activity: activity))
        XCTAssertTrue(findings.filter { $0.kind == .rhythm }.isEmpty)
    }

    func testOpenCommitmentSurvivesAndResolvedOneCloses() {
        let open = signalContext(
            family: .commitment,
            value: "I need to update the migration script for the beta build",
            daysAgo: 3,
            chunkID: 1
        )
        let resolvedCommitment = signalContext(
            family: .commitment,
            value: "I will configure the docker profile tonight",
            daysAgo: 5,
            chunkID: 2
        )
        // Later chunk that references the same content words with a completion cue.
        let resolution = signalContext(
            family: .question,
            value: "unrelated",
            daysAgo: 1,
            chunkID: 3,
            chunkText: "The docker profile is fixed and done now, configuration finished."
        )

        let findings = InsightPatternEngine.computeFindings(
            makeInput(signals: [open, resolvedCommitment, resolution])
        )
        let commitments = findings.filter { $0.kind == .openCommitment }

        XCTAssertEqual(commitments.count, 1)
        XCTAssertTrue(commitments[0].detail.contains("migration script"))
    }

    func testOpenQuestionsAreCollectedWithDedup() {
        let q1 = signalContext(family: .question, value: "How does the sync engine merge conflicts?", daysAgo: 2, chunkID: 10)
        let q1Dup = signalContext(family: .question, value: "How does the sync engine merge conflicts?", daysAgo: 1, chunkID: 11)
        let q2 = signalContext(family: .question, value: "Why is the countdown not turning red?", daysAgo: 4, chunkID: 12)

        let findings = InsightPatternEngine.computeFindings(makeInput(signals: [q1, q1Dup, q2]))
        XCTAssertEqual(findings.filter { $0.kind == .openQuestion }.count, 2)
    }

    func testEmergingThemeDetection() {
        var nodes: [SemanticGraphNode] = [
            SemanticGraphNode(nodeID: "topic:parakeet", kind: "topic", title: "Parakeet", subtitle: nil, weight: 4, lastSeenAt: now, updatedAt: now)
        ]
        var edges: [SemanticGraphEdge] = []
        var chunkDates: [Int64: Date] = [:]
        for index in 0..<4 {
            let chunkID = Int64(100 + index)
            let date = calendar.date(byAdding: .day, value: -index, to: now)!
            nodes.append(SemanticGraphNode(nodeID: "chunk:\(chunkID)", kind: "chunk", title: "c\(chunkID)", subtitle: nil, weight: 1, lastSeenAt: date, updatedAt: now))
            edges.append(SemanticGraphEdge(sourceNodeID: "chunk:\(chunkID)", targetNodeID: "topic:parakeet", kind: "mentions", weight: 0.56, evidence: nil, updatedAt: now))
            chunkDates[chunkID] = date
        }

        let findings = InsightPatternEngine.computeFindings(
            makeInput(nodes: nodes, edges: edges, chunkDates: chunkDates)
        )
        let emerging = findings.first { $0.kind == .emergingTheme }

        XCTAssertNotNil(emerging)
        XCTAssertTrue(emerging!.title.contains("Parakeet"))
        XCTAssertEqual(emerging!.evidenceChunkIDs.count, 4)
    }

    func testAnomalyDetectsQuietAndLoudDays() {
        // Baseline ~6/day for 28 days, today 20.
        var activity: [InsightPatternEngine.ActivitySample] = []
        for day in 1...28 {
            for slot in 0..<(4 + (day % 5)) {
                activity.append(sample(daysAgo: day, hour: 9 + slot))
            }
        }
        for slot in 0..<20 {
            activity.append(sample(daysAgo: 0, hour: slot % 23))
        }

        let findings = InsightPatternEngine.computeFindings(makeInput(activity: activity))
        let anomaly = findings.first { $0.kind == .anomaly }

        XCTAssertNotNil(anomaly)
        XCTAssertTrue(anomaly!.title.contains("vocal"), "expected loud-day anomaly: \(anomaly!.title)")
        XCTAssertGreaterThanOrEqual(anomaly!.magnitude, 2)
    }

    func testLifeAreasEmergeFromCommunities() {
        var nodes: [SemanticGraphNode] = []
        var edges: [SemanticGraphEdge] = []

        // Community A: topic "memory graph" + app Codex + 4 chunks.
        nodes.append(SemanticGraphNode(nodeID: "topic:memory-graph", kind: "topic", title: "Memory Graph", subtitle: nil, weight: 5, lastSeenAt: now, updatedAt: now))
        nodes.append(SemanticGraphNode(nodeID: "app:codex", kind: "app", title: "Codex", subtitle: nil, weight: 4, lastSeenAt: now, updatedAt: now))
        for chunkID in 1...4 {
            let id = "chunk:\(chunkID)"
            nodes.append(SemanticGraphNode(nodeID: id, kind: "chunk", title: "c\(chunkID)", subtitle: nil, weight: 1, lastSeenAt: now, updatedAt: now))
            edges.append(SemanticGraphEdge(sourceNodeID: id, targetNodeID: "topic:memory-graph", kind: "mentions", weight: 0.9, evidence: nil, updatedAt: now))
            edges.append(SemanticGraphEdge(sourceNodeID: id, targetNodeID: "app:codex", kind: "app-context", weight: 0.9, evidence: nil, updatedAt: now))
        }
        // Community B: topic "family dinner" + app Notes + 3 chunks.
        nodes.append(SemanticGraphNode(nodeID: "topic:family-dinner", kind: "topic", title: "Family Dinner", subtitle: nil, weight: 3, lastSeenAt: now, updatedAt: now))
        nodes.append(SemanticGraphNode(nodeID: "app:notes", kind: "app", title: "Notes", subtitle: nil, weight: 2, lastSeenAt: now, updatedAt: now))
        for chunkID in 10...13 {
            let id = "chunk:\(chunkID)"
            nodes.append(SemanticGraphNode(nodeID: id, kind: "chunk", title: "c\(chunkID)", subtitle: nil, weight: 1, lastSeenAt: now, updatedAt: now))
            edges.append(SemanticGraphEdge(sourceNodeID: id, targetNodeID: "topic:family-dinner", kind: "mentions", weight: 0.9, evidence: nil, updatedAt: now))
            edges.append(SemanticGraphEdge(sourceNodeID: id, targetNodeID: "app:notes", kind: "app-context", weight: 0.9, evidence: nil, updatedAt: now))
        }

        let findings = InsightPatternEngine.computeFindings(makeInput(nodes: nodes, edges: edges))
        let areas = findings.filter { $0.kind == .lifeArea }

        XCTAssertEqual(areas.count, 2, "expected two distinct communities: \(areas.map(\.title))")
        XCTAssertTrue(areas.contains { $0.title.contains("Memory Graph") })
        XCTAssertTrue(areas.contains { $0.title.contains("Family Dinner") })
    }
}
