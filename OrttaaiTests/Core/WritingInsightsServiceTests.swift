// WritingInsightsServiceTests.swift
// OrttaaiTests

import XCTest
import GRDB
@testable import Orttaai

final class WritingInsightsServiceTests: XCTestCase {
    private var db: DatabaseManager!

    override func setUpWithError() throws {
        let dbQueue = try DatabaseQueue(path: ":memory:")
        db = try DatabaseManager(dbQueue: dbQueue)
    }

    override func tearDownWithError() throws {
        db = nil
    }

    func testGenerateInsightsReturnsEmptyWhenNoHistory() async throws {
        let service = WritingInsightsService(
            databaseManager: db,
            appleAnalyzer: MockWritingAnalyzer(name: "Apple", available: true, payload: nil),
            heuristicAnalyzer: MockWritingAnalyzer(name: "Heuristic", available: true, payload: nil)
        )

        let result = await service.generateInsights()

        XCTAssertNil(result.snapshot)
        XCTAssertEqual(result.sampleCount, 0)
        XCTAssertNil(result.errorMessage)
    }

    func testGenerateInsightsUsesAppleAnalyzerWhenAvailable() async throws {
        try seedTranscription(text: "Here is a useful writing sample.")
        let applePayload = samplePayload(summary: "Apple summary")

        let service = WritingInsightsService(
            databaseManager: db,
            appleAnalyzer: MockWritingAnalyzer(name: "Apple Foundation Models", available: true, payload: applePayload),
            heuristicAnalyzer: MockWritingAnalyzer(name: "Heuristic Analyzer", available: true, payload: samplePayload(summary: "Heuristic"))
        )

        let result = await service.generateInsights()

        XCTAssertEqual(result.analyzerName, "Apple Foundation Models")
        XCTAssertFalse(result.usedFallback)
        XCTAssertEqual(result.snapshot?.summary, "Apple summary")
        XCTAssertTrue(result.snapshot?.recommendations.isEmpty == true)
        XCTAssertNotNil(result.persistedSnapshotID)
    }

    func testGenerateInsightsFallsBackToHeuristicWhenAppleReturnsNil() async throws {
        try seedTranscription(text: "Another test sample for fallback.")
        let heuristicPayload = samplePayload(summary: "Fallback summary")

        let service = WritingInsightsService(
            databaseManager: db,
            appleAnalyzer: MockWritingAnalyzer(name: "Apple Foundation Models", available: true, payload: nil),
            heuristicAnalyzer: MockWritingAnalyzer(name: "Heuristic Analyzer", available: true, payload: heuristicPayload)
        )

        let result = await service.generateInsights()

        XCTAssertEqual(result.analyzerName, "Heuristic Analyzer")
        XCTAssertTrue(result.usedFallback)
        XCTAssertEqual(result.snapshot?.summary, "Fallback summary")
        XCTAssertNil(result.errorMessage)
    }

    func testGenerateInsightsAppliesTimeAndAppFilters() async throws {
        let now = Date()
        try db.saveTranscription(
            text: "Recent cursor entry",
            appName: "Cursor",
            recordingMs: 2_000,
            processingMs: 900,
            modelId: "test",
            createdAt: now.addingTimeInterval(-2 * 60 * 60)
        )
        try db.saveTranscription(
            text: "Old chrome entry",
            appName: "Google Chrome",
            recordingMs: 2_000,
            processingMs: 900,
            modelId: "test",
            createdAt: now.addingTimeInterval(-40 * 24 * 60 * 60)
        )

        let service = WritingInsightsService(
            databaseManager: db,
            appleAnalyzer: MockWritingAnalyzer(name: "Apple", available: false, payload: nil),
            heuristicAnalyzer: MockWritingAnalyzer(name: "Heuristic", available: true, payload: samplePayload(summary: "Filtered"))
        )

        let result = await service.generateInsights(
            request: WritingInsightsRequest(
                timeRange: .days7,
                generationMode: .balanced,
                appFilterMode: .includeOnly,
                selectedApps: ["Cursor"]
            )
        )

        XCTAssertEqual(result.sampleCount, 1)
        XCTAssertEqual(result.snapshot?.sampleCount, 1)
        XCTAssertEqual(result.snapshot?.summary, "Filtered")
    }

    func testApplyRecommendationCreatesDictionaryAndSnippet() throws {
        let service = WritingInsightsService(
            databaseManager: db,
            appleAnalyzer: MockWritingAnalyzer(name: "Apple", available: false, payload: nil),
            heuristicAnalyzer: MockWritingAnalyzer(name: "Heuristic", available: true, payload: nil)
        )

        try service.applyRecommendation(
            WritingInsightRecommendation(
                kind: .dictionary,
                source: "wispr",
                target: "Wispr",
                rationale: "Common correction",
                confidence: 0.9
            )
        )
        try service.applyRecommendation(
            WritingInsightRecommendation(
                kind: .snippet,
                source: "intro email",
                target: "Hey, would love to connect this week.",
                rationale: "Repeated text",
                confidence: 0.8
            )
        )

        let dictionary = try db.fetchDictionaryEntries(includeInactive: false)
        let snippets = try db.fetchSnippetEntries(includeInactive: false)
        XCTAssertTrue(dictionary.contains(where: { $0.source == "wispr" && $0.target == "Wispr" }))
        XCTAssertTrue(snippets.contains(where: { $0.trigger == "intro email" }))
    }

    func testLoadRecentSnapshotsReturnsLatestFirstWithLimit() throws {
        let older = makeSnapshot(summary: "Older", at: Date().addingTimeInterval(-120))
        let newer = makeSnapshot(summary: "Newer", at: Date())
        _ = try db.saveWritingInsightSnapshot(older)
        _ = try db.saveWritingInsightSnapshot(newer)

        let service = WritingInsightsService(
            databaseManager: db,
            appleAnalyzer: MockWritingAnalyzer(name: "Apple", available: false, payload: nil),
            heuristicAnalyzer: MockWritingAnalyzer(name: "Heuristic", available: true, payload: nil)
        )

        let snapshots = service.loadRecentSnapshots(limit: 1)
        XCTAssertEqual(snapshots.count, 1)
        XCTAssertEqual(snapshots.first?.summary, "Newer")
    }

    func testPinAndDeleteSnapshotThroughService() throws {
        let snapshot = makeSnapshot(summary: "To pin", at: Date())
        let id = try db.saveWritingInsightSnapshot(snapshot)

        let service = WritingInsightsService(
            databaseManager: db,
            appleAnalyzer: MockWritingAnalyzer(name: "Apple", available: false, payload: nil),
            heuristicAnalyzer: MockWritingAnalyzer(name: "Heuristic", available: true, payload: nil)
        )

        try service.setSnapshotPinned(id: id, isPinned: true)
        var history = service.loadRecentHistoryItems(limit: 5)
        XCTAssertEqual(history.first?.id, id)
        XCTAssertTrue(history.first?.isPinned == true)

        let deleted = try service.deleteSnapshot(id: id)
        XCTAssertTrue(deleted)
        history = service.loadRecentHistoryItems(limit: 5)
        XCTAssertTrue(history.isEmpty)
    }

    func testFreshnessMarksStaleWhenManyNewSessionsExist() throws {
        let snapshotDate = Date(timeIntervalSince1970: 1_735_000_000)
        for index in 0..<22 {
            try seedTranscription(
                text: "Session \(index)",
                createdAt: snapshotDate.addingTimeInterval(TimeInterval(index + 1))
            )
        }

        let service = WritingInsightsService(
            databaseManager: db,
            appleAnalyzer: MockWritingAnalyzer(name: "Apple", available: false, payload: nil),
            heuristicAnalyzer: MockWritingAnalyzer(name: "Heuristic", available: true, payload: nil)
        )

        let snapshot = makeSnapshot(summary: "Baseline", at: snapshotDate)
        let freshness = service.freshness(for: snapshot)
        XCTAssertEqual(freshness.newSessionCount, 22)
        XCTAssertEqual(freshness.status, .stale)
        XCTAssertTrue(freshness.shouldAutoRefresh)
    }

    func testFreshnessMarksFreshWhenNoNewSessions() throws {
        let snapshotDate = Date(timeIntervalSince1970: 1_735_000_000)
        try seedTranscription(text: "Older only", createdAt: snapshotDate.addingTimeInterval(-60))

        let service = WritingInsightsService(
            databaseManager: db,
            appleAnalyzer: MockWritingAnalyzer(name: "Apple", available: false, payload: nil),
            heuristicAnalyzer: MockWritingAnalyzer(name: "Heuristic", available: true, payload: nil)
        )

        let snapshot = makeSnapshot(summary: "Baseline", at: snapshotDate)
        let freshness = service.freshness(for: snapshot)
        XCTAssertEqual(freshness.newSessionCount, 0)
        XCTAssertEqual(freshness.status, .fresh)
        XCTAssertFalse(freshness.shouldAutoRefresh)
    }

    private func seedTranscription(text: String, createdAt: Date = Date()) throws {
        try db.saveTranscription(
            text: text,
            appName: "Notes",
            recordingMs: 2_000,
            processingMs: 900,
            modelId: "openai_whisper-base.en",
            createdAt: createdAt
        )
    }

    private func samplePayload(summary: String) -> WritingInsightPayload {
        WritingInsightPayload(
            summary: summary,
            signals: [
                WritingInsightSignal(label: "Sessions", value: "5", detail: "Recent sessions")
            ],
            patterns: [
                WritingInsightPattern(title: "Pattern", detail: "Detail", evidence: "Evidence")
            ],
            strengths: ["Strength"],
            opportunities: ["Opportunity"]
        )
    }

    private func makeSnapshot(summary: String, at date: Date) -> WritingInsightSnapshot {
        WritingInsightSnapshot(
            generatedAt: date,
            sampleCount: 3,
            analyzerName: "Heuristic Analyzer",
            usedFallback: false,
            request: .default,
            summary: summary,
            signals: [WritingInsightSignal(label: "Sessions", value: "3", detail: "Recent")],
            patterns: [WritingInsightPattern(title: "Pattern", detail: "Detail", evidence: nil)],
            strengths: ["Strength"],
            opportunities: ["Opportunity"],
            recommendations: []
        )
    }
}

private final class MockWritingAnalyzer: WritingInsightAnalyzing {
    let name: String
    private let available: Bool
    private let payload: WritingInsightPayload?

    init(name: String, available: Bool, payload: WritingInsightPayload?) {
        self.name = name
        self.available = available
        self.payload = payload
    }

    func isAvailable() -> Bool {
        available
    }

    func analyze(transcriptions: [Transcription]) async -> WritingInsightPayload? {
        payload
    }
}
