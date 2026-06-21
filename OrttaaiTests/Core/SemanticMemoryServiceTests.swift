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

    func testGenerateInsightsPersistsLatestSnapshot() async throws {
        try seedTranscription(
            text: "Project Atlas onboarding needs a customer research plan and migration notes. I need to follow up with the launch owner.",
            appName: "Cursor"
        )
        try seedTranscription(
            text: "Project Atlas pricing work connects to customer onboarding and support follow ups across launch planning.",
            appName: "Slack"
        )

        let service = makeService()
        _ = await service.indexPendingTranscriptions(limit: 50)

        let report = await service.generateInsights()
        let loaded = service.loadLatestInsightReport()

        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded?.graphSignature, report.graphSignature)
        XCTAssertEqual(loaded?.cards.count, report.cards.count)
        XCTAssertEqual(loaded?.analyzerName, report.analyzerName)
    }

    func testSemanticInsightSnapshotFreshnessPreservesStaleReport() throws {
        let originalGraph = sampleGraph(weight: 1.0)
        let changedGraph = sampleGraph(weight: 2.0)
        let report = SemanticMemoryService.makeInsightReport(
            graph: originalGraph,
            chunks: [],
            generatedAt: Date(),
            limitCards: 4
        )

        try db.saveSemanticInsightSnapshot(report)
        let service = makeService()
        let loaded = try XCTUnwrap(service.loadLatestInsightReport())
        let freshness = service.freshness(for: loaded, currentGraph: changedGraph)

        XCTAssertEqual(loaded.graphSignature, report.graphSignature)
        XCTAssertEqual(freshness.status, .stale)
        XCTAssertTrue(freshness.isStale)
    }

    func testGenerateInsightsProducesDeepComparativeSections() async throws {
        let now = Date()
        try seedTranscription(
            text: "Project Atlas pricing review and customer onboarding plan needs a follow up with launch owner.",
            appName: "Cursor",
            createdAt: now
        )
        try seedTranscription(
            text: "Design review for Project Atlas should become a reusable checklist for onboarding decisions.",
            appName: "Figma",
            createdAt: now.addingTimeInterval(-2_000)
        )
        try seedTranscription(
            text: "Older finance planning focused on budget reconciliation and vendor invoice cleanup.",
            appName: "Numbers",
            createdAt: now.addingTimeInterval(-35 * 24 * 60 * 60)
        )
        try seedTranscription(
            text: "Previous operations work involved vendor support follow ups and invoice documentation.",
            appName: "Mail",
            createdAt: now.addingTimeInterval(-32 * 24 * 60 * 60)
        )

        let service = makeService()
        _ = await service.indexPendingTranscriptions(limit: 50)

        let report = await service.generateInsights()

        XCTAssertFalse(report.clusters.isEmpty)
        XCTAssertFalse(report.comparisons.isEmpty)
        XCTAssertFalse(report.coverageNotes.isEmpty)
        XCTAssertTrue(report.cards.contains { $0.kind == "Temporal Comparison" || $0.kind == "Recurring vs Fading" })
        XCTAssertTrue(report.clusters.allSatisfy { !$0.evidence.isEmpty })
        XCTAssertTrue(report.comparisons.allSatisfy { !$0.evidence.isEmpty })
    }

    func testModelInsightJSONDecoderRejectsMalformedPayload() {
        XCTAssertFalse(SemanticMemoryService.canDecodeModelInsightPayload(from: "not json"))
        XCTAssertFalse(SemanticMemoryService.canDecodeModelInsightPayload(from: #"{"summary":[],"cards":[]}"#))
        XCTAssertTrue(SemanticMemoryService.canDecodeModelInsightPayload(from: #"{"summary":["Specific backed claim"],"cards":[]}"#))
    }

    func testViewModelLoadDoesNotGenerateInsights() {
        let graph = sampleGraph(weight: 1.0)
        let report = SemanticMemoryService.makeInsightReport(
            graph: graph,
            chunks: [],
            generatedAt: Date(),
            limitCards: 4
        )
        let fakeService = FakeSemanticMemoryService(graph: graph, report: report)
        let viewModel = SemanticMemoryViewModel(service: fakeService)

        viewModel.load()

        XCTAssertEqual(fakeService.generateCallCount, 0)
        XCTAssertEqual(fakeService.latestReportCallCount, 1)
        XCTAssertEqual(viewModel.insightReport?.graphSignature, report.graphSignature)
        XCTAssertEqual(viewModel.insightFreshness?.status, .fresh)
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

    private func sampleGraph(weight: Double) -> SemanticMemoryGraph {
        let now = Date()
        let projectNode = SemanticGraphNode(
            nodeID: "entity:project-atlas",
            kind: "entity",
            title: "Project Atlas",
            subtitle: "Named context",
            weight: weight,
            lastSeenAt: now,
            updatedAt: now
        )
        let appNode = SemanticGraphNode(
            nodeID: "app:cursor",
            kind: "app",
            title: "Cursor",
            subtitle: "App context",
            weight: 1.0,
            lastSeenAt: now,
            updatedAt: now
        )
        let edge = SemanticGraphEdge(
            sourceNodeID: projectNode.nodeID,
            targetNodeID: appNode.nodeID,
            kind: "app-context",
            weight: 0.6,
            evidence: "Test graph",
            updatedAt: now
        )
        return SemanticMemoryGraph(nodes: [projectNode, appNode], edges: [edge])
    }
}

@MainActor
private final class FakeSemanticMemoryService: SemanticMemoryServiceProviding {
    private let storedGraph: SemanticMemoryGraph
    private let storedReport: SemanticInsightReport?
    private(set) var generateCallCount = 0
    private(set) var latestReportCallCount = 0

    init(graph: SemanticMemoryGraph, report: SemanticInsightReport?) {
        self.storedGraph = graph
        self.storedReport = report
    }

    func stats() -> SemanticMemoryStats {
        SemanticMemoryStats(
            chunkCount: 0,
            embeddedChunkCount: 0,
            nodeCount: storedGraph.nodes.count,
            edgeCount: storedGraph.edges.count,
            activeModelID: "test",
            latestIndexedAt: nil
        )
    }

    func graph(limitNodes: Int, limitEdges: Int) -> SemanticMemoryGraph {
        storedGraph
    }

    func loadLatestInsightReport() -> SemanticInsightReport? {
        latestReportCallCount += 1
        return storedReport
    }

    func freshness(for report: SemanticInsightReport, currentGraph: SemanticMemoryGraph) -> SemanticInsightFreshness {
        SemanticInsightFreshness(
            reportGraphSignature: report.graphSignature,
            currentGraphSignature: report.graphSignature,
            status: .fresh
        )
    }

    func generateInsights(limitCards: Int) async -> SemanticInsightReport {
        generateCallCount += 1
        return storedReport ?? SemanticMemoryService.makeInsightReport(
            graph: storedGraph,
            chunks: [],
            generatedAt: Date(),
            limitCards: limitCards
        )
    }

    func clearIndex() throws {}

    func indexPendingTranscriptions(limit: Int) async -> SemanticIndexRunResult {
        SemanticIndexRunResult(
            sourceCount: 0,
            chunkCount: 0,
            embeddedCount: 0,
            skippedCount: 0,
            graphNodeCount: storedGraph.nodes.count,
            graphEdgeCount: storedGraph.edges.count,
            providerName: "Fake",
            modelID: "test",
            usedFallback: false,
            errorMessage: nil
        )
    }

    func retrieveContext(for query: String, limit: Int, minimumScore: Double) async -> [SemanticRetrievedContext] {
        []
    }
}
