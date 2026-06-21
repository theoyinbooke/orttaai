// SemanticMemoryServiceTests.swift
// OrttaaiTests

import XCTest
import GRDB
@testable import Orttaai

@MainActor
final class SemanticMemoryServiceTests: XCTestCase {
    private var db: DatabaseManager!
    private var settings: AppSettings!
    private var previousSemanticMemoryEnabled = true
    private var previousSemanticMemoryAutoIndexEnabled = true
    private var previousSemanticEmbeddingFallbackEnabled = true
    private var previousSemanticEmbeddingModel = "all-minilm"
    private var previousSemanticActiveIndexModelID = ""
    private var previousSemanticInsightSummaryEnabled = true
    private var previousSemanticInsightSummaryModel = "qwen3.5:0.8b"

    override func setUpWithError() throws {
        db = try DatabaseManager(dbQueue: DatabaseQueue(path: ":memory:"))
        settings = AppSettings()
        previousSemanticMemoryEnabled = settings.semanticMemoryEnabled
        previousSemanticMemoryAutoIndexEnabled = settings.semanticMemoryAutoIndexEnabled
        previousSemanticEmbeddingFallbackEnabled = settings.semanticEmbeddingFallbackEnabled
        previousSemanticEmbeddingModel = settings.semanticEmbeddingModel
        previousSemanticActiveIndexModelID = settings.semanticActiveIndexModelID
        previousSemanticInsightSummaryEnabled = settings.semanticInsightSummaryEnabled
        previousSemanticInsightSummaryModel = settings.semanticInsightSummaryModel
        settings.semanticMemoryEnabled = true
        settings.semanticMemoryAutoIndexEnabled = false
        settings.semanticEmbeddingFallbackEnabled = true
        settings.semanticEmbeddingModel = "lexical-fallback-v1"
        settings.semanticActiveIndexModelID = ""
        settings.semanticInsightSummaryEnabled = false
        settings.semanticInsightSummaryModel = "qwen3.5:0.8b"
    }

    override func tearDownWithError() throws {
        settings.semanticMemoryEnabled = previousSemanticMemoryEnabled
        settings.semanticMemoryAutoIndexEnabled = previousSemanticMemoryAutoIndexEnabled
        settings.semanticEmbeddingFallbackEnabled = previousSemanticEmbeddingFallbackEnabled
        settings.semanticEmbeddingModel = previousSemanticEmbeddingModel
        settings.semanticActiveIndexModelID = previousSemanticActiveIndexModelID
        settings.semanticInsightSummaryEnabled = previousSemanticInsightSummaryEnabled
        settings.semanticInsightSummaryModel = previousSemanticInsightSummaryModel
        settings = nil
        db = nil
    }

    func testVectorCodecRoundTripsFloatVectors() {
        let vector: [Float] = [0.25, -0.5, 1.25, 0]
        let data = SemanticVectorCodec.encode(vector)
        let decoded = SemanticVectorCodec.decode(data, expectedDimension: vector.count)

        XCTAssertEqual(decoded, vector)
        XCTAssertNil(SemanticVectorCodec.decode(data, expectedDimension: vector.count + 1))
    }

    func testIndexBuildsChunksEmbeddingsAndGraph() async throws {
        try seedTranscription(
            text: "Project Atlas onboarding needs a customer research plan and migration notes.",
            appName: "Cursor"
        )
        try seedTranscription(
            text: "Project Atlas pricing work connects to customer onboarding and support follow ups.",
            appName: "Slack"
        )

        let service = makeService()
        let result = await service.indexPendingTranscriptions(limit: 50)
        let stats = service.stats()
        let graph = service.graph()

        XCTAssertNil(result.errorMessage)
        XCTAssertEqual(result.sourceCount, 2)
        XCTAssertGreaterThan(result.chunkCount, 0)
        XCTAssertGreaterThan(result.embeddedCount, 0)
        XCTAssertEqual(stats.chunkCount, result.chunkCount)
        XCTAssertEqual(stats.embeddedChunkCount, stats.chunkCount)
        XCTAssertFalse(graph.nodes.isEmpty)
        XCTAssertFalse(graph.edges.isEmpty)
        XCTAssertTrue(graph.nodes.contains { $0.kind == "topic" || $0.kind == "app" })
        XCTAssertTrue(graph.nodes.contains { $0.kind == "entity" && $0.title == "Project Atlas" })
    }

    func testRetrieveContextRanksRelatedTranscript() async throws {
        try seedTranscription(
            text: "Project Atlas onboarding needs a customer research plan and migration notes.",
            appName: "Cursor"
        )
        try seedTranscription(
            text: "Buy bananas and detergent after lunch.",
            appName: "Notes"
        )

        let service = makeService()
        _ = await service.indexPendingTranscriptions(limit: 50)

        let results = await service.retrieveContext(
            for: "customer onboarding migration for atlas",
            limit: 2,
            minimumScore: 0.01
        )

        XCTAssertFalse(results.isEmpty)
        XCTAssertTrue(results[0].text.lowercased().contains("atlas"))
    }

    func testGenerateInsightsProducesEvidenceBackedCards() async throws {
        let now = Date()
        try seedTranscription(
            text: "Project Atlas onboarding needs a customer research plan and migration notes. I need to follow up with the launch owner.",
            appName: "Cursor",
            createdAt: now.addingTimeInterval(-3_600)
        )
        try seedTranscription(
            text: "Project Atlas pricing work connects to customer onboarding and support follow ups across launch planning.",
            appName: "Slack",
            createdAt: now
        )
        try seedTranscription(
            text: "Customer research should become a reusable checklist for Project Atlas onboarding decisions.",
            appName: "Notes",
            createdAt: now.addingTimeInterval(-1_800)
        )

        let service = makeService()
        _ = await service.indexPendingTranscriptions(limit: 50)

        let report = await service.generateInsights()

        XCTAssertFalse(report.summary.isEmpty)
        XCTAssertGreaterThan(report.sourceNodeCount, 0)
        XCTAssertGreaterThan(report.sourceEdgeCount, 0)
        XCTAssertGreaterThan(report.sourceChunkCount, 0)
        XCTAssertFalse(report.cards.isEmpty)
        XCTAssertTrue(report.cards.allSatisfy { !$0.title.isEmpty && !$0.body.isEmpty && !$0.actionText.isEmpty })
        XCTAssertTrue(report.cards.contains { $0.kind == "Open Loops" })
        XCTAssertTrue(report.cards.contains { !$0.evidence.isEmpty })
    }

    func testGenerateInsightsHandlesEmptyGraph() async {
        let service = makeService()
        let report = await service.generateInsights()

        XCTAssertTrue(report.cards.isEmpty)
        XCTAssertFalse(report.summary.isEmpty)
        XCTAssertEqual(report.sourceNodeCount, 0)
        XCTAssertEqual(report.sourceEdgeCount, 0)
        XCTAssertEqual(report.sourceChunkCount, 0)
    }

    func testClearIndexRemovesDerivedSemanticRows() async throws {
        try seedTranscription(
            text: "Project Atlas onboarding needs a customer research plan and migration notes.",
            appName: "Cursor"
        )

        let service = makeService()
        _ = await service.indexPendingTranscriptions(limit: 50)
        XCTAssertGreaterThan(service.stats().chunkCount, 0)

        try service.clearIndex()

        let stats = service.stats()
        XCTAssertEqual(stats.chunkCount, 0)
        XCTAssertEqual(stats.embeddedChunkCount, 0)
        XCTAssertEqual(stats.nodeCount, 0)
        XCTAssertEqual(stats.edgeCount, 0)
    }

    private func makeService() -> SemanticMemoryService {
        SemanticMemoryService(
            databaseManager: db,
            settings: settings,
            primaryProvider: LexicalSemanticEmbeddingProvider()
        )
    }

    private func seedTranscription(text: String, appName: String, createdAt: Date = Date()) throws {
        try db.saveTranscription(
            text: text,
            appName: appName,
            recordingMs: 1_000,
            processingMs: 500,
            modelId: "test",
            createdAt: createdAt
        )
    }
}
