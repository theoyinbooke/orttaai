// SemanticMemoryService.swift
// Orttaai

import CryptoKit
import Foundation
import os

struct SemanticIndexRunResult: Sendable {
    let sourceCount: Int
    let chunkCount: Int
    let embeddedCount: Int
    let skippedCount: Int
    let graphNodeCount: Int
    let graphEdgeCount: Int
    let providerName: String
    let modelID: String
    let usedFallback: Bool
    let errorMessage: String?
}

struct SemanticRetrievedContext: Identifiable, Sendable {
    let chunkID: Int64
    let text: String
    let score: Double
    let sourceCreatedAt: Date
    let targetAppName: String?
    let transcriptionID: Int64

    var id: Int64 { chunkID }
}

protocol SemanticEmbeddingProviding {
    var providerName: String { get }
    var modelID: String { get }
    func embed(texts: [String]) async throws -> [[Float]]
}

struct OllamaSemanticEmbeddingProvider: SemanticEmbeddingProviding {
    let providerName = "Ollama Embeddings"
    let modelID: String
    let baseURLString: String
    let timeoutMs: Int?
    let client: OllamaClient

    init(
        modelID: String,
        baseURLString: String,
        timeoutMs: Int? = nil,
        client: OllamaClient = OllamaClient()
    ) {
        self.modelID = modelID
        self.baseURLString = baseURLString
        self.timeoutMs = timeoutMs
        self.client = client
    }

    func embed(texts: [String]) async throws -> [[Float]] {
        try await client.embed(
            baseURLString: baseURLString,
            model: modelID,
            inputs: texts,
            timeoutMs: timeoutMs,
            keepAlive: "15m"
        )
    }
}

struct LexicalSemanticEmbeddingProvider: SemanticEmbeddingProviding {
    let providerName = "Lexical Fallback"
    let modelID = "lexical-fallback-v1"
    let dimension = 256

    func embed(texts: [String]) async throws -> [[Float]] {
        texts.map { normalizedHashedVector(for: $0) }
    }

    private func normalizedHashedVector(for text: String) -> [Float] {
        var vector = [Float](repeating: 0, count: dimension)
        let tokens = Self.tokens(in: text)
        guard !tokens.isEmpty else { return vector }

        for token in tokens {
            let index = abs(token.stableSemanticHash) % dimension
            vector[index] += token.count > 6 ? 1.35 : 1.0
        }

        return SemanticVectorMath.normalized(vector)
    }

    nonisolated static func tokens(in text: String) -> [String] {
        let stopWords = Self.stopWords
        return text
            .lowercased()
            .split { character in
                !(character.isLetter || character.isNumber || character == "'")
            }
            .map(String.init)
            .filter { $0.count > 2 && !stopWords.contains($0) }
    }

    nonisolated private static let stopWords: Set<String> = [
        "the", "and", "for", "that", "this", "with", "from", "have", "has", "had",
        "are", "was", "were", "you", "your", "but", "not", "can", "will", "just",
        "into", "about", "what", "when", "where", "they", "them", "then", "than",
        "our", "out", "get", "got", "all", "any", "one", "two", "use", "using",
        "there", "their", "would", "could", "should", "because", "really", "very"
    ]
}

enum SemanticVectorCodec {
    nonisolated static func encode(_ values: [Float]) -> Data {
        var mutableValues = values
        return Data(bytes: &mutableValues, count: mutableValues.count * MemoryLayout<Float>.stride)
    }

    nonisolated static func decode(_ data: Data, expectedDimension: Int) -> [Float]? {
        guard expectedDimension > 0 else { return nil }
        let byteCount = expectedDimension * MemoryLayout<Float>.stride
        guard data.count == byteCount else { return nil }

        var values = [Float](repeating: 0, count: expectedDimension)
        _ = values.withUnsafeMutableBytes { destination in
            data.copyBytes(to: destination)
        }
        return values
    }
}

enum SemanticVectorMath {
    nonisolated static func normalized(_ vector: [Float]) -> [Float] {
        let magnitude = sqrt(vector.reduce(Float(0)) { $0 + $1 * $1 })
        guard magnitude > 0 else { return vector }
        return vector.map { $0 / magnitude }
    }

    nonisolated static func cosineSimilarity(_ lhs: [Float], _ rhs: [Float]) -> Double {
        guard lhs.count == rhs.count, !lhs.isEmpty else { return 0 }
        var dot = Float(0)
        var lhsMagnitude = Float(0)
        var rhsMagnitude = Float(0)
        for index in lhs.indices {
            dot += lhs[index] * rhs[index]
            lhsMagnitude += lhs[index] * lhs[index]
            rhsMagnitude += rhs[index] * rhs[index]
        }
        guard lhsMagnitude > 0, rhsMagnitude > 0 else { return 0 }
        return Double(dot / (sqrt(lhsMagnitude) * sqrt(rhsMagnitude)))
    }
}

final class SemanticMemoryService {
    private let databaseManager: DatabaseManager?
    private let settings: AppSettings
    private let ollamaClient: OllamaClient
    private let primaryProviderOverride: (any SemanticEmbeddingProviding)?
    private let fallbackProvider = LexicalSemanticEmbeddingProvider()
    private let chunkWordLimit = 140
    private let chunkOverlapWords = 24

    init(
        databaseManager: DatabaseManager? = nil,
        settings: AppSettings = AppSettings(),
        ollamaClient: OllamaClient = OllamaClient(),
        primaryProvider: (any SemanticEmbeddingProviding)? = nil
    ) {
        self.databaseManager = databaseManager ?? (try? DatabaseManager())
        self.settings = settings
        self.ollamaClient = ollamaClient
        self.primaryProviderOverride = primaryProvider
    }

    var activeModelID: String {
        let stored = settings.semanticActiveIndexModelID.trimmingCharacters(in: .whitespacesAndNewlines)
        if !stored.isEmpty {
            return stored
        }
        return settings.normalizedSemanticEmbeddingModel
    }

    func stats() -> SemanticMemoryStats {
        do {
            let databaseManager = try requireDatabaseManager()
            return try databaseManager.fetchSemanticMemoryStats(modelID: activeModelID)
        } catch {
            Logger.memory.error("Failed to load semantic memory stats: \(error.localizedDescription)")
            return SemanticMemoryStats(
                chunkCount: 0,
                embeddedChunkCount: 0,
                nodeCount: 0,
                edgeCount: 0,
                activeModelID: activeModelID,
                latestIndexedAt: nil
            )
        }
    }

    func graph(limitNodes: Int = 180, limitEdges: Int = 360) -> SemanticMemoryGraph {
        do {
            let databaseManager = try requireDatabaseManager()
            return try databaseManager.fetchSemanticGraph(limitNodes: limitNodes, limitEdges: limitEdges)
        } catch {
            Logger.memory.error("Failed to load semantic graph: \(error.localizedDescription)")
            return SemanticMemoryGraph(nodes: [], edges: [])
        }
    }

    func generateInsights(limitCards: Int = 8) async -> SemanticInsightReport {
        do {
            let databaseManager = try requireDatabaseManager()
            let graph = try databaseManager.fetchSemanticGraph(limitNodes: 220, limitEdges: 480)
            let chunks = try databaseManager.fetchEmbeddedSemanticChunks(modelID: activeModelID, limit: 900)
            let report = Self.makeInsightReport(
                graph: graph,
                chunks: chunks,
                generatedAt: Date(),
                limitCards: limitCards
            )
            return await reportWithModelSummaryIfAvailable(report)
        } catch {
            Logger.memory.error("Failed to generate semantic insights: \(error.localizedDescription)")
            return SemanticInsightReport(
                generatedAt: Date(),
                graphSignature: "error",
                summary: ["Build or refresh the semantic index before generating graph insights."],
                summaryModelName: nil,
                cards: [],
                sourceNodeCount: 0,
                sourceEdgeCount: 0,
                sourceChunkCount: 0
            )
        }
    }

    func clearIndex() throws {
        let databaseManager = try requireDatabaseManager()
        try databaseManager.clearSemanticMemory()
        settings.semanticActiveIndexModelID = ""
    }

    func indexPendingTranscriptions(limit: Int = 500) async -> SemanticIndexRunResult {
        guard settings.semanticMemoryEnabled else {
            return SemanticIndexRunResult(
                sourceCount: 0,
                chunkCount: 0,
                embeddedCount: 0,
                skippedCount: 0,
                graphNodeCount: 0,
                graphEdgeCount: 0,
                providerName: "Disabled",
                modelID: activeModelID,
                usedFallback: false,
                errorMessage: nil
            )
        }

        do {
            let databaseManager = try requireDatabaseManager()
            let transcriptions = try databaseManager.fetchSemanticIndexSourceTranscriptions(limit: limit)
                .filter { ($0.id ?? 0) > 0 && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            guard !transcriptions.isEmpty else {
                return emptyRun(providerName: "No Data", modelID: activeModelID)
            }

            let initialProvider = makePrimaryProvider()
            var provider: any SemanticEmbeddingProviding = initialProvider
            var usedFallback = false
            var allChunks: [SemanticChunk] = []

            for record in transcriptions {
                guard record.id != nil else { continue }
                let drafts = makeChunks(from: record)
                let chunks = try databaseManager.upsertSemanticChunks(for: record, drafts: drafts)
                allChunks.append(contentsOf: chunks)
            }

            var embeddedChunkIDs = try databaseManager.fetchSemanticEmbeddingChunkIDs(modelID: provider.modelID)
            var chunksToEmbed = allChunks.filter { chunk in
                guard let id = chunk.id else { return false }
                return !embeddedChunkIDs.contains(id)
            }

            var embeddedCount = 0
            do {
                embeddedCount = try await embed(chunks: chunksToEmbed, using: provider)
                settings.semanticActiveIndexModelID = provider.modelID
            } catch {
                guard settings.semanticEmbeddingFallbackEnabled else {
                    throw error
                }
                Logger.memory.warning("Ollama semantic indexing failed; using lexical fallback: \(error.localizedDescription)")
                provider = fallbackProvider
                usedFallback = true
                settings.semanticActiveIndexModelID = fallbackProvider.modelID
                embeddedChunkIDs = try databaseManager.fetchSemanticEmbeddingChunkIDs(modelID: provider.modelID)
                chunksToEmbed = allChunks.filter { chunk in
                    guard let id = chunk.id else { return false }
                    return !embeddedChunkIDs.contains(id)
                }
                embeddedCount = try await embed(chunks: chunksToEmbed, using: provider)
            }

            let graph = try rebuildGraph(modelID: provider.modelID)
            return SemanticIndexRunResult(
                sourceCount: transcriptions.count,
                chunkCount: allChunks.count,
                embeddedCount: embeddedCount,
                skippedCount: max(0, allChunks.count - chunksToEmbed.count),
                graphNodeCount: graph.nodes.count,
                graphEdgeCount: graph.edges.count,
                providerName: provider.providerName,
                modelID: provider.modelID,
                usedFallback: usedFallback,
                errorMessage: nil
            )
        } catch {
            Logger.memory.error("Semantic memory indexing failed: \(error.localizedDescription)")
            return SemanticIndexRunResult(
                sourceCount: 0,
                chunkCount: 0,
                embeddedCount: 0,
                skippedCount: 0,
                graphNodeCount: 0,
                graphEdgeCount: 0,
                providerName: "Semantic Memory",
                modelID: activeModelID,
                usedFallback: false,
                errorMessage: error.localizedDescription
            )
        }
    }

    func retrieveContext(
        for query: String,
        limit: Int = 6,
        minimumScore: Double = 0.16
    ) async -> [SemanticRetrievedContext] {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard settings.semanticMemoryEnabled, !normalizedQuery.isEmpty else { return [] }

        do {
            let databaseManager = try requireDatabaseManager()
            if settings.semanticMemoryAutoIndexEnabled {
                _ = await indexPendingTranscriptions(limit: 500)
            }

            let modelID = activeModelID
            let provider = providerForRetrieval(modelID: modelID)
            guard let queryVector = try await provider.embed(texts: [normalizedQuery]).first else {
                return []
            }
            let chunks = try databaseManager.fetchEmbeddedSemanticChunks(modelID: provider.modelID, limit: 1_500)

            let scored = chunks.compactMap { chunk -> SemanticRetrievedContext? in
                guard let vector = SemanticVectorCodec.decode(chunk.vectorData, expectedDimension: chunk.dimension) else {
                    return nil
                }
                let score = SemanticVectorMath.cosineSimilarity(queryVector, vector)
                guard score >= minimumScore else { return nil }
                return SemanticRetrievedContext(
                    chunkID: chunk.chunkID,
                    text: chunk.text,
                    score: score,
                    sourceCreatedAt: chunk.sourceCreatedAt,
                    targetAppName: chunk.targetAppName,
                    transcriptionID: chunk.transcriptionID
                )
            }

            return scored
                .sorted {
                    if abs($0.score - $1.score) < 0.0001 {
                        return $0.sourceCreatedAt > $1.sourceCreatedAt
                    }
                    return $0.score > $1.score
                }
                .prefix(max(1, limit))
                .map { $0 }
        } catch {
            Logger.memory.warning("Semantic retrieval failed: \(error.localizedDescription)")
            return []
        }
    }

    func contextBlock(for query: String, limit: Int = 6) async -> String {
        let results = await retrieveContext(for: query, limit: limit)
        guard !results.isEmpty else { return "" }

        return results.enumerated().map { index, result in
            let app = result.targetAppName?.trimmingCharacters(in: .whitespacesAndNewlines)
            let appLabel = app?.isEmpty == false ? app! : "Unknown App"
            let date = Self.contextDateFormatter.string(from: result.sourceCreatedAt)
            let score = Int((result.score * 100).rounded())
            let text = result.text
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return "[\(index + 1)] \(appLabel), \(date), relevance \(score)%: \(text)"
        }
        .joined(separator: "\n")
    }

    private struct InsightNodeContext {
        let node: SemanticGraphNode
        let incidentEdges: [SemanticGraphEdge]
        let neighborIDs: Set<String>
        let neighborKinds: Set<String>
        let chunks: [SemanticEmbeddedChunk]
        let appNames: Set<String>
        let latestSeenAt: Date?
        let weightedDegree: Double

        var degree: Int { neighborIDs.count }
        var evidenceCount: Int { chunks.count }
        var importanceScore: Double {
            node.weight + weightedDegree + Double(degree) * 0.32 + Double(appNames.count) * 0.4
        }
        var bridgeScore: Double {
            Double(neighborKinds.count) * 1.4 + Double(appNames.count) * 1.1 + weightedDegree + Double(degree) * 0.18
        }
    }

    static func makeInsightReport(
        graph: SemanticMemoryGraph,
        chunks: [SemanticEmbeddedChunk],
        generatedAt: Date,
        limitCards: Int = 8
    ) -> SemanticInsightReport {
        let signature = graphSignature(for: graph)
        guard !graph.nodes.isEmpty, !graph.edges.isEmpty else {
            return SemanticInsightReport(
                generatedAt: generatedAt,
                graphSignature: signature,
                summary: ["Build the semantic index to generate insight cards from your writing graph."],
                summaryModelName: nil,
                cards: [],
                sourceNodeCount: graph.nodes.count,
                sourceEdgeCount: graph.edges.count,
                sourceChunkCount: chunks.count
            )
        }

        let nodeByID = Dictionary(uniqueKeysWithValues: graph.nodes.map { ($0.nodeID, $0) })
        let chunkByNodeID = Dictionary(uniqueKeysWithValues: chunks.map { ("chunk:\($0.chunkID)", $0) })
        let incidentEdges = incidentEdgesByNodeID(graph.edges)
        let contexts = graph.nodes
            .filter { $0.kind != "chunk" }
            .map { node in
                nodeContext(
                    for: node,
                    nodeByID: nodeByID,
                    chunkByNodeID: chunkByNodeID,
                    incidentEdgesByNodeID: incidentEdges
                )
            }

        var cards: [SemanticInsightCard] = []

        appendCard(dominantThemeCard(from: contexts), to: &cards)
        appendCard(activeProjectCard(from: contexts), to: &cards)
        appendCard(hiddenBridgeCard(from: contexts), to: &cards)
        appendCard(openLoopCard(from: chunks), to: &cards)
        appendCard(contextShiftCard(from: chunks), to: &cards)
        appendCard(recentMomentumCard(from: contexts), to: &cards)
        appendCard(underdevelopedThreadCard(from: contexts), to: &cards)

        let boundedCards = Array(cards.prefix(max(1, limitCards)))
        return SemanticInsightReport(
            generatedAt: generatedAt,
            graphSignature: signature,
            summary: summaryLines(
                graph: graph,
                chunks: chunks,
                contexts: contexts,
                cards: boundedCards
            ),
            summaryModelName: nil,
            cards: boundedCards,
            sourceNodeCount: graph.nodes.count,
            sourceEdgeCount: graph.edges.count,
            sourceChunkCount: chunks.count
        )
    }

    private func reportWithModelSummaryIfAvailable(_ report: SemanticInsightReport) async -> SemanticInsightReport {
        guard settings.semanticInsightSummaryEnabled, !report.cards.isEmpty else {
            return report
        }

        let modelName = settings.normalizedSemanticInsightSummaryModel
        guard !modelName.isEmpty else { return report }

        do {
            let installedModels = try await ollamaClient.fetchModelNames(
                baseURLString: settings.normalizedLocalLLMEndpoint,
                timeoutMs: 1_500
            )
            let canonicalSelection = Self.canonicalOllamaModelName(modelName)
            guard installedModels.contains(where: { Self.canonicalOllamaModelName($0) == canonicalSelection }) else {
                return report
            }

            let response = try await ollamaClient.chat(
                baseURLString: settings.normalizedLocalLLMEndpoint,
                model: modelName,
                messages: [
                    OllamaChatMessage(
                        role: .system,
                        content: """
                        You are a private local knowledge-graph analyst inside a macOS dictation app.
                        Write a sharp TLDR from the provided graph insights only.
                        Do not invent facts. Do not mention raw node/link counts unless they explain a decision.
                        Focus on what the user is working on, what may be unresolved, and the next useful action.
                        """
                    ),
                    OllamaChatMessage(
                        role: .user,
                        content: Self.modelSummaryPrompt(for: report)
                    ),
                ],
                timeoutMs: 45_000,
                think: settings.localLLMInsightsThinkingEnabled ? true : nil,
                temperature: 0.2,
                numPredict: 420,
                numContext: settings.clampedLocalLLMInsightsContextTokens,
                keepAlive: "10m"
            )
            let summary = Self.parseModelSummaryLines(response)
            guard !summary.isEmpty else { return report }
            return Self.replacingSummary(on: report, with: summary, modelName: modelName)
        } catch {
            Logger.memory.warning("Could not generate model semantic TLDR: \(error.localizedDescription)")
            return report
        }
    }

    nonisolated private static func replacingSummary(
        on report: SemanticInsightReport,
        with summary: [String],
        modelName: String?
    ) -> SemanticInsightReport {
        SemanticInsightReport(
            generatedAt: report.generatedAt,
            graphSignature: report.graphSignature,
            summary: summary,
            summaryModelName: modelName,
            cards: report.cards,
            sourceNodeCount: report.sourceNodeCount,
            sourceEdgeCount: report.sourceEdgeCount,
            sourceChunkCount: report.sourceChunkCount
        )
    }

    nonisolated private static func modelSummaryPrompt(for report: SemanticInsightReport) -> String {
        let cards = report.cards
            .prefix(6)
            .enumerated()
            .map { index, card in
                let evidence = card.evidence
                    .prefix(2)
                    .map { item in
                        let appName = item.sourceAppName?.isEmpty == false ? item.sourceAppName! : "Dictation"
                        return "- \(appName): \(item.excerpt)"
                    }
                    .joined(separator: "\n")

                return """
                \(index + 1). \(card.kind): \(card.title)
                Signal: \(card.body)
                Recommended action: \(card.actionText)
                Evidence:
                \(evidence.isEmpty ? "- No excerpt available." : evidence)
                """
            }
            .joined(separator: "\n\n")

        return """
        Create a TLDR insight summary for this personal knowledge graph.

        Required output:
        - Exactly 3 bullets.
        - Each bullet should be useful and specific, not generic.
        - Bullet 1: the main workstream or theme.
        - Bullet 2: the hidden risk, open loop, or scattered context.
        - Bullet 3: the best next action.
        - No heading. No markdown table.

        Graph insight cards and evidence:
        \(cards)
        """
    }

    nonisolated private static func parseModelSummaryLines(_ response: String) -> [String] {
        let withoutThinking = response.replacingOccurrences(
            of: #"(?s)<think>.*?</think>"#,
            with: "",
            options: .regularExpression
        )

        let lines = withoutThinking
            .components(separatedBy: .newlines)
            .flatMap { line -> [String] in
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty { return [] }
                if trimmed.contains(" - "), !trimmed.hasPrefix("-") {
                    return [trimmed]
                }
                return [trimmed]
            }
            .compactMap(cleanModelSummaryLine)

        if !lines.isEmpty {
            return Array(lines.prefix(4))
        }

        return withoutThinking
            .components(separatedBy: ". ")
            .compactMap(cleanModelSummaryLine)
            .prefix(4)
            .map { line in line.hasSuffix(".") ? line : "\(line)." }
    }

    nonisolated private static func cleanModelSummaryLine(_ line: String) -> String? {
        var cleaned = line
            .replacingOccurrences(of: #"^\s*[-*•]\s*"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"^\s*\d+[\.)]\s*"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"(?i)^tl;?dr[:\-\s]*"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "`", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let lowercased = cleaned.lowercased()
        if cleaned.isEmpty ||
            lowercased == "summary" ||
            lowercased == "executive summary" ||
            lowercased == "tldr" ||
            lowercased == "tl;dr" {
            return nil
        }

        if cleaned.count > 220 {
            cleaned = String(cleaned.prefix(217)).trimmingCharacters(in: .whitespacesAndNewlines) + "..."
        }
        return cleaned
    }

    private static func dominantThemeCard(from contexts: [InsightNodeContext]) -> SemanticInsightCard? {
        let candidate = contexts
            .filter({ ["topic", "entity"].contains($0.node.kind) && $0.evidenceCount > 0 })
            .sorted(by: { $0.importanceScore > $1.importanceScore })
            .first
        guard let context = candidate else {
            return nil
        }

        let appPhrase = appSummary(context.appNames)
        return SemanticInsightCard(
            id: "dominant-theme-\(context.node.nodeID)",
            kind: "Dominant Theme",
            title: "Dominant theme: \(context.node.title)",
            body: "\(context.node.title) is one of the strongest recurring concepts in the current memory graph, connected to \(context.evidenceCount) segment\(context.evidenceCount == 1 ? "" : "s")\(appPhrase).",
            confidence: confidence(base: 0.52, evidenceCount: context.evidenceCount, degree: context.degree),
            actionText: "Use this as a working thread: collect decisions, tasks, and follow-up notes around it.",
            relatedNodeIDs: [context.node.nodeID],
            evidence: evidenceItems(from: context.chunks, focus: context.node.title)
        )
    }

    private static func activeProjectCard(from contexts: [InsightNodeContext]) -> SemanticInsightCard? {
        let projectCandidates = contexts
            .filter { context in
                context.evidenceCount > 0 &&
                    (context.node.kind == "entity" || context.node.title.localizedCaseInsensitiveContains("project"))
            }
            .sorted { lhs, rhs in
                if lhs.appNames.count == rhs.appNames.count {
                    return lhs.importanceScore > rhs.importanceScore
                }
                return lhs.appNames.count > rhs.appNames.count
            }

        guard let context = projectCandidates.first else { return nil }
        return SemanticInsightCard(
            id: "active-project-\(context.node.nodeID)",
            kind: "Active Project",
            title: "Likely active project: \(context.node.title)",
            body: "\(context.node.title) appears across \(context.evidenceCount) segment\(context.evidenceCount == 1 ? "" : "s") and \(context.appNames.count) app context\(context.appNames.count == 1 ? "" : "s"), which makes it look like a live workstream rather than a one-off mention.",
            confidence: confidence(base: 0.48, evidenceCount: context.evidenceCount, degree: context.degree + context.appNames.count),
            actionText: "Create or update a project note with the latest decisions, blockers, and next steps.",
            relatedNodeIDs: [context.node.nodeID],
            evidence: evidenceItems(from: context.chunks, focus: context.node.title)
        )
    }

    private static func hiddenBridgeCard(from contexts: [InsightNodeContext]) -> SemanticInsightCard? {
        let candidate = contexts
            .filter { $0.degree >= 3 && $0.neighborKinds.count >= 2 && $0.evidenceCount > 0 }
            .sorted(by: { $0.bridgeScore > $1.bridgeScore })
            .first
        guard let context = candidate else {
            return nil
        }

        let kinds = context.neighborKinds.sorted().joined(separator: ", ")
        return SemanticInsightCard(
            id: "bridge-\(context.node.nodeID)",
            kind: "Hidden Bridge",
            title: "\(context.node.title) connects separate areas",
            body: "This node bridges \(context.neighborKinds.count) graph layer\(context.neighborKinds.count == 1 ? "" : "s") (\(kinds)), making it a useful place to inspect cross-project or cross-context overlap.",
            confidence: confidence(base: 0.5, evidenceCount: context.evidenceCount, degree: context.degree),
            actionText: "Review its connected evidence to find reusable ideas, dependencies, or duplicated effort.",
            relatedNodeIDs: [context.node.nodeID] + Array(context.neighborIDs.prefix(6)),
            evidence: evidenceItems(from: context.chunks, focus: context.node.title)
        )
    }

    private static func openLoopCard(from chunks: [SemanticEmbeddedChunk]) -> SemanticInsightCard? {
        let openLoopChunks = chunks
            .filter { containsOpenLoopCue($0.text) }
            .sorted { $0.sourceCreatedAt > $1.sourceCreatedAt }
            .prefix(5)
            .map { $0 }
        guard !openLoopChunks.isEmpty else { return nil }

        return SemanticInsightCard(
            id: "open-loops",
            kind: "Open Loops",
            title: "Open loops are showing up in recent dictation",
            body: "\(openLoopChunks.count) recent excerpt\(openLoopChunks.count == 1 ? "" : "s") contain follow-up, need-to, or action language. These are likely commitments or unresolved work hiding inside dictation.",
            confidence: confidence(base: 0.5, evidenceCount: openLoopChunks.count, degree: openLoopChunks.count),
            actionText: "Turn these excerpts into explicit tasks before they disappear into the transcript history.",
            relatedNodeIDs: openLoopChunks.map { "chunk:\($0.chunkID)" },
            evidence: evidenceItems(from: openLoopChunks, focus: "open loop", limit: 4)
        )
    }

    private static func contextShiftCard(from chunks: [SemanticEmbeddedChunk]) -> SemanticInsightCard? {
        let appGroups = Dictionary(grouping: chunks) { chunk in
            let appName = chunk.targetAppName?.trimmingCharacters(in: .whitespacesAndNewlines)
            return appName?.isEmpty == false ? appName! : "Unknown App"
        }
        let rankedApps = appGroups
            .map { (name: $0.key, chunks: $0.value) }
            .sorted { lhs, rhs in
                if lhs.chunks.count == rhs.chunks.count {
                    return lhs.name < rhs.name
                }
                return lhs.chunks.count > rhs.chunks.count
            }
        guard rankedApps.count >= 2 else { return nil }

        let topApps = rankedApps.prefix(3).map(\.name)
        let evidence = rankedApps
            .prefix(3)
            .flatMap { $0.chunks.prefix(1) }
            .sorted { $0.sourceCreatedAt > $1.sourceCreatedAt }

        return SemanticInsightCard(
            id: "context-shifts",
            kind: "Context Shifts",
            title: "Work is moving across \(rankedApps.count) app contexts",
            body: "The strongest app contexts are \(topApps.joined(separator: ", ")). This can signal useful cross-tool flow, but it can also hide fragmentation if the same project is spread across multiple places.",
            confidence: confidence(base: 0.46, evidenceCount: evidence.count, degree: rankedApps.count),
            actionText: "Check whether the same project has decisions or todos scattered across these apps.",
            relatedNodeIDs: topApps.map { "app:\(nodeKey($0))" },
            evidence: evidenceItems(from: evidence, focus: "app context", limit: 3)
        )
    }

    private static func recentMomentumCard(from contexts: [InsightNodeContext]) -> SemanticInsightCard? {
        let candidate = contexts
            .filter { $0.evidenceCount > 0 && $0.latestSeenAt != nil && $0.node.kind != "app" }
            .sorted { lhs, rhs in
                if lhs.latestSeenAt == rhs.latestSeenAt {
                    return lhs.importanceScore > rhs.importanceScore
                }
                return (lhs.latestSeenAt ?? .distantPast) > (rhs.latestSeenAt ?? .distantPast)
            }
            .first
        guard let context = candidate else {
            return nil
        }

        return SemanticInsightCard(
            id: "recent-momentum-\(context.node.nodeID)",
            kind: "Recent Momentum",
            title: "Recent momentum: \(context.node.title)",
            body: "\(context.node.title) is one of the freshest connected concepts in the graph. It is worth checking before older themes pull attention away from current work.",
            confidence: confidence(base: 0.44, evidenceCount: context.evidenceCount, degree: context.degree),
            actionText: "Ask what changed recently and whether this should become today's priority.",
            relatedNodeIDs: [context.node.nodeID],
            evidence: evidenceItems(from: context.chunks, focus: context.node.title)
        )
    }

    private static func underdevelopedThreadCard(from contexts: [InsightNodeContext]) -> SemanticInsightCard? {
        let candidate = contexts
            .filter { ["topic", "entity"].contains($0.node.kind) && $0.evidenceCount > 0 && $0.degree <= 2 && $0.node.weight >= 1.0 }
            .sorted {
                if $0.node.weight == $1.node.weight {
                    return $0.latestSeenAt ?? .distantPast > $1.latestSeenAt ?? .distantPast
                }
                return $0.node.weight > $1.node.weight
            }
            .first
        guard let context = candidate else {
            return nil
        }

        return SemanticInsightCard(
            id: "underdeveloped-\(context.node.nodeID)",
            kind: "Underdeveloped Area",
            title: "\(context.node.title) has signal but few connections",
            body: "This concept has enough weight to matter, but only \(context.degree) connection\(context.degree == 1 ? "" : "s"). It may be an idea that has not yet been linked to the right project, app, or next step.",
            confidence: confidence(base: 0.42, evidenceCount: context.evidenceCount, degree: max(1, 3 - context.degree)),
            actionText: "Expand this into a note or connect it to the project it belongs to.",
            relatedNodeIDs: [context.node.nodeID],
            evidence: evidenceItems(from: context.chunks, focus: context.node.title)
        )
    }

    private static func nodeContext(
        for node: SemanticGraphNode,
        nodeByID: [String: SemanticGraphNode],
        chunkByNodeID: [String: SemanticEmbeddedChunk],
        incidentEdgesByNodeID: [String: [SemanticGraphEdge]]
    ) -> InsightNodeContext {
        let edges = incidentEdgesByNodeID[node.nodeID] ?? []
        var neighborIDs = Set<String>()
        var neighborKinds = Set<String>()
        var chunks: [SemanticEmbeddedChunk] = []
        var seenChunkIDs = Set<Int64>()
        var appNames = Set<String>()
        var weightedDegree = 0.0

        for edge in edges {
            weightedDegree += edge.weight
            let otherID = edge.sourceNodeID == node.nodeID ? edge.targetNodeID : edge.sourceNodeID
            neighborIDs.insert(otherID)
            if let otherNode = nodeByID[otherID] {
                neighborKinds.insert(otherNode.kind)
            }
            if let chunk = chunkByNodeID[otherID], !seenChunkIDs.contains(chunk.chunkID) {
                seenChunkIDs.insert(chunk.chunkID)
                chunks.append(chunk)
                if let appName = chunk.targetAppName?.trimmingCharacters(in: .whitespacesAndNewlines), !appName.isEmpty {
                    appNames.insert(appName)
                }
            }
        }

        chunks.sort { $0.sourceCreatedAt > $1.sourceCreatedAt }
        let latestSeenAt = chunks.map(\.sourceCreatedAt).max() ?? node.lastSeenAt
        return InsightNodeContext(
            node: node,
            incidentEdges: edges,
            neighborIDs: neighborIDs,
            neighborKinds: neighborKinds,
            chunks: chunks,
            appNames: appNames,
            latestSeenAt: latestSeenAt,
            weightedDegree: weightedDegree
        )
    }

    private static func incidentEdgesByNodeID(_ edges: [SemanticGraphEdge]) -> [String: [SemanticGraphEdge]] {
        var result: [String: [SemanticGraphEdge]] = [:]
        for edge in edges {
            result[edge.sourceNodeID, default: []].append(edge)
            result[edge.targetNodeID, default: []].append(edge)
        }
        return result
    }

    private static func appendCard(_ card: SemanticInsightCard?, to cards: inout [SemanticInsightCard]) {
        guard let card, !cards.contains(where: { $0.id == card.id }) else { return }
        cards.append(card)
    }

    private static func summaryLines(
        graph: SemanticMemoryGraph,
        chunks: [SemanticEmbeddedChunk],
        contexts: [InsightNodeContext],
        cards: [SemanticInsightCard]
    ) -> [String] {
        var lines: [String] = []
        if let top = contexts
            .filter({ ["topic", "entity"].contains($0.node.kind) && $0.evidenceCount > 0 })
            .sorted(by: { $0.importanceScore > $1.importanceScore })
            .first {
            lines.append("\(top.node.title) is the current center of gravity in your dictated work, with enough repeated evidence to treat it as an active thread.")
        } else {
            lines.append("The graph has enough structure to inspect, but it needs more repeated dictation before a clear workstream emerges.")
        }

        if let openLoop = cards.first(where: { $0.kind == "Open Loops" }) {
            lines.append("\(openLoop.title): capture these as explicit tasks so commitments do not stay buried inside transcripts.")
        } else if let contextShift = cards.first(where: { $0.kind == "Context Shifts" }) {
            lines.append("\(contextShift.title), so check whether decisions and todos are scattered across tools.")
        }

        if let bridge = cards.first(where: { $0.kind == "Hidden Bridge" }) {
            lines.append("\(bridge.title); this is the best place to look for cross-project overlap or reusable ideas.")
        } else if let recent = cards.first(where: { $0.kind == "Recent Momentum" }) {
            lines.append("\(recent.title) is fresh enough to review before older themes pull attention away.")
        }

        if let nextAction = cards.first?.actionText {
            lines.append("Best next action: \(nextAction)")
        } else {
            lines.append("Best next action: build more semantic memory, then regenerate insights for stronger evidence.")
        }

        if lines.count == 1, graph.nodes.count > 0 || chunks.count > 0 {
            lines.append("There is signal here, but the summary will improve after more connected chunks are indexed.")
        }
        return Array(lines.prefix(4))
    }

    private static func evidenceItems(
        from chunks: [SemanticEmbeddedChunk],
        focus: String,
        limit: Int = 3
    ) -> [SemanticInsightEvidence] {
        chunks
            .sorted { $0.sourceCreatedAt > $1.sourceCreatedAt }
            .prefix(max(1, limit))
            .enumerated()
            .map { index, chunk in
                SemanticInsightEvidence(
                    id: "\(chunk.chunkID)-\(index)",
                    title: focus.isEmpty ? chunkTitle(chunk.text) : focus,
                    excerpt: excerpt(chunk.text),
                    sourceAppName: chunk.targetAppName,
                    sourceCreatedAt: chunk.sourceCreatedAt,
                    score: max(0.25, 1.0 - Double(index) * 0.12)
                )
            }
    }

    private static func confidence(base: Double, evidenceCount: Int, degree: Int) -> Double {
        min(0.95, max(0.25, base + Double(min(evidenceCount, 5)) * 0.07 + Double(min(degree, 8)) * 0.025))
    }

    private static func appSummary(_ appNames: Set<String>) -> String {
        guard !appNames.isEmpty else { return "" }
        let apps = appNames.sorted().prefix(3).joined(separator: ", ")
        return " across \(apps)"
    }

    private static func containsOpenLoopCue(_ text: String) -> Bool {
        let normalized = " \(text.lowercased()) "
        let cues = [
            " need to ", " i need ", " we need ", " should ", " have to ", " must ",
            " follow up", " following up", " reminder", " remind ", " todo", " to-do",
            " action item", " next step", " make sure", " don't forget", " unresolved",
            " still need", " need this", " need that"
        ]
        return cues.contains { normalized.contains($0) }
    }

    private static func excerpt(_ text: String, limit: Int = 180) -> String {
        let cleaned = text
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleaned.count > limit else { return cleaned }
        return String(cleaned.prefix(max(0, limit - 3))).trimmingCharacters(in: .whitespacesAndNewlines) + "..."
    }

    private static func graphSignature(for graph: SemanticMemoryGraph) -> String {
        let nodePart = graph.nodes
            .map { "\($0.nodeID):\($0.weight)" }
            .joined(separator: "|")
        let edgePart = graph.edges
            .enumerated()
            .map { "\($0.offset):\($0.element.sourceNodeID)>\($0.element.targetNodeID):\($0.element.weight)" }
            .joined(separator: "|")
        return "\(graph.nodes.count)#\(graph.edges.count)#\(nodePart)#\(edgePart)"
    }

    private func emptyRun(providerName: String, modelID: String) -> SemanticIndexRunResult {
        SemanticIndexRunResult(
            sourceCount: 0,
            chunkCount: 0,
            embeddedCount: 0,
            skippedCount: 0,
            graphNodeCount: 0,
            graphEdgeCount: 0,
            providerName: providerName,
            modelID: modelID,
            usedFallback: false,
            errorMessage: nil
        )
    }

    private func requireDatabaseManager() throws -> DatabaseManager {
        guard let databaseManager else {
            throw NSError(
                domain: "com.orttaai.semantic-memory",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Semantic memory database is unavailable."]
            )
        }
        return databaseManager
    }

    private func makePrimaryProvider() -> any SemanticEmbeddingProviding {
        if let primaryProviderOverride {
            return primaryProviderOverride
        }
        return OllamaSemanticEmbeddingProvider(
            modelID: settings.normalizedSemanticEmbeddingModel,
            baseURLString: settings.normalizedLocalLLMEndpoint,
            timeoutMs: nil,
            client: ollamaClient
        )
    }

    private func providerForRetrieval(modelID: String) -> any SemanticEmbeddingProviding {
        if modelID == fallbackProvider.modelID {
            return fallbackProvider
        }
        if let primaryProviderOverride, modelID == primaryProviderOverride.modelID {
            return primaryProviderOverride
        }
        return makePrimaryProvider()
    }

    private func embed(chunks: [SemanticChunk], using provider: any SemanticEmbeddingProviding) async throws -> Int {
        let databaseManager = try requireDatabaseManager()
        let chunksWithIDs = chunks.compactMap { chunk -> SemanticChunk? in
            guard chunk.id != nil else { return nil }
            return chunk
        }
        guard !chunksWithIDs.isEmpty else { return 0 }

        var embeddedCount = 0
        for batchStart in stride(from: 0, to: chunksWithIDs.count, by: 16) {
            let batch = Array(chunksWithIDs[batchStart..<min(batchStart + 16, chunksWithIDs.count)])
            let embeddings = try await provider.embed(texts: batch.map(\.text))
            guard embeddings.count == batch.count else {
                throw NSError(
                    domain: "com.orttaai.semantic-memory",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "Embedding count did not match chunk count."]
                )
            }

            for (chunk, vector) in zip(batch, embeddings) {
                guard let chunkID = chunk.id else { continue }
                let normalizedVector = SemanticVectorMath.normalized(vector)
                try databaseManager.saveSemanticEmbedding(
                    chunkID: chunkID,
                    modelID: provider.modelID,
                    providerName: provider.providerName,
                    dimension: normalizedVector.count,
                    vectorData: SemanticVectorCodec.encode(normalizedVector)
                )
                embeddedCount += 1
            }
        }
        return embeddedCount
    }

    private func makeChunks(from transcription: Transcription) -> [SemanticChunkDraft] {
        guard let transcriptionID = transcription.id else { return [] }
        let words = transcription.text
            .replacingOccurrences(of: "\n", with: " ")
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
        guard !words.isEmpty else { return [] }

        var chunks: [SemanticChunkDraft] = []
        var startIndex = 0
        var chunkIndex = 0

        while startIndex < words.count {
            let endIndex = min(startIndex + chunkWordLimit, words.count)
            let chunkText = words[startIndex..<endIndex]
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !chunkText.isEmpty {
                chunks.append(
                    SemanticChunkDraft(
                        transcriptionID: transcriptionID,
                        chunkIndex: chunkIndex,
                        text: chunkText,
                        textHash: Self.sha256(chunkText),
                        sourceCreatedAt: transcription.createdAt,
                        targetAppName: transcription.targetAppName,
                        targetAppBundleID: transcription.targetAppBundleID,
                        wordCount: endIndex - startIndex
                    )
                )
                chunkIndex += 1
            }

            if endIndex == words.count {
                break
            }
            startIndex = max(endIndex - chunkOverlapWords, startIndex + 1)
        }

        return chunks
    }

    @discardableResult
    private func rebuildGraph(modelID: String) throws -> SemanticMemoryGraph {
        let databaseManager = try requireDatabaseManager()
        let embeddedChunks = try databaseManager.fetchEmbeddedSemanticChunks(modelID: modelID, limit: 600)
        let now = Date()
        var nodesByID: [String: SemanticGraphNode] = [:]
        var edgesByKey: [String: SemanticGraphEdge] = [:]
        var vectorsByChunkID: [Int64: [Float]] = [:]

        func upsertNode(id: String, kind: String, title: String, subtitle: String?, weight: Double, lastSeenAt: Date?) {
            guard !id.isEmpty, !title.isEmpty else { return }
            if var existing = nodesByID[id] {
                existing.weight += weight
                if let lastSeenAt {
                    existing.lastSeenAt = max(existing.lastSeenAt ?? lastSeenAt, lastSeenAt)
                }
                nodesByID[id] = existing
            } else {
                nodesByID[id] = SemanticGraphNode(
                    nodeID: id,
                    kind: kind,
                    title: title,
                    subtitle: subtitle,
                    weight: weight,
                    lastSeenAt: lastSeenAt,
                    updatedAt: now
                )
            }
        }

        func upsertEdge(source: String, target: String, kind: String, weight: Double, evidence: String?) {
            guard source != target else { return }
            let ordered = source < target ? (source, target) : (target, source)
            let key = "\(ordered.0)|\(ordered.1)|\(kind)"
            if var existing = edgesByKey[key] {
                existing.weight = max(existing.weight, weight)
                edgesByKey[key] = existing
            } else {
                edgesByKey[key] = SemanticGraphEdge(
                    sourceNodeID: ordered.0,
                    targetNodeID: ordered.1,
                    kind: kind,
                    weight: weight,
                    evidence: evidence,
                    updatedAt: now
                )
            }
        }

        for chunk in embeddedChunks {
            let chunkNodeID = "chunk:\(chunk.chunkID)"
            let title = Self.chunkTitle(chunk.text)
            upsertNode(
                id: chunkNodeID,
                kind: "chunk",
                title: title,
                subtitle: chunk.targetAppName ?? "Dictation",
                weight: max(1, Double(chunk.wordCount) / 18.0),
                lastSeenAt: chunk.sourceCreatedAt
            )

            if let appName = chunk.targetAppName?.trimmingCharacters(in: .whitespacesAndNewlines), !appName.isEmpty {
                let appNodeID = "app:\(Self.nodeKey(appName))"
                upsertNode(
                    id: appNodeID,
                    kind: "app",
                    title: appName,
                    subtitle: "App context",
                    weight: 1.5,
                    lastSeenAt: chunk.sourceCreatedAt
                )
                upsertEdge(source: appNodeID, target: chunkNodeID, kind: "app-context", weight: 0.62, evidence: "Dictated in \(appName)")
            }

            for phrase in Self.topicPhrases(in: chunk.text, limit: 3) {
                let topicNodeID = "topic:\(Self.nodeKey(phrase))"
                upsertNode(
                    id: topicNodeID,
                    kind: "topic",
                    title: phrase.capitalized,
                    subtitle: "Recurring theme",
                    weight: 1.2,
                    lastSeenAt: chunk.sourceCreatedAt
                )
                upsertEdge(source: topicNodeID, target: chunkNodeID, kind: "mentions", weight: 0.56, evidence: phrase)
            }

            for entity in Self.entityPhrases(in: chunk.text, limit: 3) {
                let entityNodeID = "entity:\(Self.nodeKey(entity))"
                upsertNode(
                    id: entityNodeID,
                    kind: "entity",
                    title: entity,
                    subtitle: "Named context",
                    weight: 1.45,
                    lastSeenAt: chunk.sourceCreatedAt
                )
                upsertEdge(source: entityNodeID, target: chunkNodeID, kind: "entity", weight: 0.64, evidence: entity)
            }

            if let vector = SemanticVectorCodec.decode(chunk.vectorData, expectedDimension: chunk.dimension) {
                vectorsByChunkID[chunk.chunkID] = vector
            }
        }

        let similarityCandidates = embeddedChunks.prefix(100)
        for (leftOffset, left) in similarityCandidates.enumerated() {
            guard let leftVector = vectorsByChunkID[left.chunkID] else { continue }
            for right in similarityCandidates.dropFirst(leftOffset + 1) {
                guard let rightVector = vectorsByChunkID[right.chunkID] else { continue }
                let score = SemanticVectorMath.cosineSimilarity(leftVector, rightVector)
                guard score >= 0.74 else { continue }
                upsertEdge(
                    source: "chunk:\(left.chunkID)",
                    target: "chunk:\(right.chunkID)",
                    kind: "semantic",
                    weight: min(1.0, score),
                    evidence: "Semantic similarity \(Int((score * 100).rounded()))%"
                )
            }
        }

        let rankedNodes = nodesByID.values
            .sorted {
                if $0.weight == $1.weight { return $0.title < $1.title }
                return $0.weight > $1.weight
            }
            .prefix(180)
        let keptNodeIDs = Set(rankedNodes.map(\.nodeID))
        let rankedEdges = edgesByKey.values
            .filter { keptNodeIDs.contains($0.sourceNodeID) && keptNodeIDs.contains($0.targetNodeID) }
            .sorted { $0.weight > $1.weight }
            .prefix(360)

        let graph = SemanticMemoryGraph(nodes: Array(rankedNodes), edges: Array(rankedEdges))
        try databaseManager.replaceSemanticGraph(nodes: graph.nodes, edges: graph.edges)
        return graph
    }

    nonisolated private static func sha256(_ text: String) -> String {
        let digest = SHA256.hash(data: Data(text.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    nonisolated private static func chunkTitle(_ text: String) -> String {
        let words = text.split(whereSeparator: \.isWhitespace).prefix(7).joined(separator: " ")
        let trimmed = words.trimmingCharacters(in: .punctuationCharacters.union(.whitespacesAndNewlines))
        guard !trimmed.isEmpty else { return "Dictation chunk" }
        return trimmed.count > 64 ? String(trimmed.prefix(61)) + "..." : trimmed
    }

    nonisolated private static func topicPhrases(in text: String, limit: Int) -> [String] {
        var counts: [String: Int] = [:]
        let tokens = LexicalSemanticEmbeddingProvider.tokens(in: text)
        for token in tokens where token.count >= 4 {
            counts[token, default: 0] += 1
        }
        guard !counts.isEmpty else { return [] }
        return counts
            .sorted {
                if $0.value == $1.value { return $0.key < $1.key }
                return $0.value > $1.value
            }
            .prefix(max(1, limit))
            .map(\.key)
    }

    nonisolated private static func entityPhrases(in text: String, limit: Int) -> [String] {
        let rawWords = text
            .split { character in
                !(character.isLetter || character.isNumber || character == "'" || character == "-")
            }
            .map(String.init)

        var counts: [String: Int] = [:]
        var current: [String] = []

        func flushCurrent() {
            guard current.count >= 2 else {
                current.removeAll()
                return
            }
            let phrase = current.joined(separator: " ")
            guard phrase.count <= 64 else {
                current.removeAll()
                return
            }
            counts[phrase, default: 0] += 1
            current.removeAll()
        }

        for word in rawWords {
            guard let first = word.unicodeScalars.first else {
                flushCurrent()
                continue
            }
            let isCandidate = CharacterSet.uppercaseLetters.contains(first) && word.count > 2
            let isCommonSentenceStart = Self.entityStopWords.contains(word.lowercased())
            if isCandidate && !isCommonSentenceStart {
                current.append(word.trimmingCharacters(in: .punctuationCharacters))
            } else {
                flushCurrent()
            }
        }
        flushCurrent()

        return counts
            .sorted {
                if $0.value == $1.value { return $0.key < $1.key }
                return $0.value > $1.value
            }
            .prefix(max(1, limit))
            .map(\.key)
    }

    nonisolated private static func nodeKey(_ value: String) -> String {
        let key = value
            .lowercased()
            .replacingOccurrences(of: #"[^a-z0-9]+"#, with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return key.isEmpty ? sha256(value).prefix(12).description : key
    }

    nonisolated private static func canonicalOllamaModelName(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return "" }
        return trimmed.contains(":") ? trimmed : "\(trimmed):latest"
    }

    nonisolated private static let contextDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    nonisolated private static let entityStopWords: Set<String> = [
        "the", "this", "that", "these", "those", "when", "where", "what", "please",
        "today", "tomorrow", "yesterday", "after", "before", "because"
    ]
}

private extension String {
    var stableSemanticHash: Int {
        var hash = 5381
        for scalar in unicodeScalars {
            hash = ((hash << 5) &+ hash) &+ Int(scalar.value)
        }
        return hash
    }
}
