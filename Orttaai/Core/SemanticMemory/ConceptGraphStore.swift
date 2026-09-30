// ConceptGraphStore.swift
// Orttaai

import Foundation
import CryptoKit
import os

/// One dictation that mentions a concept, trimmed to the sentence that does.
nonisolated struct ConceptMention: Identifiable, Sendable {
    let dictationID: Int64
    let date: Date
    let appName: String?
    let excerpt: String

    var id: Int64 { dictationID }
}

/// Builds the concept graph straight from dictation text. Extraction is
/// cached per dictation in the database, so after the first pass only new or
/// edited dictations are analyzed; building a graph for any time range is
/// then a pure aggregation. Needs no model and no search index.
///
/// Database access stays on the main actor with the rest of the app; the
/// language analysis and graph building run in parallel background tasks.
final class ConceptGraphStore {
    static let shared = ConceptGraphStore()

    private let databaseManager: DatabaseManager?
    private var dictations: [DictationConcepts] = []
    private var sources: [ConceptSource] = []
    /// The user's dictionary spellings, preferred when merging variants.
    private var preferredKeys: Set<String> = []
    private var sourceSignature = ""
    private var refreshTask: Task<Void, Error>?

    init(databaseManager: DatabaseManager? = nil) {
        self.databaseManager = databaseManager ?? (try? DatabaseManager())
    }

    /// Brings the per-dictation cache up to date (reporting progress for the
    /// first, larger pass) and returns the graph for `range`.
    func graph(
        range: ConceptTimeRange,
        now: Date = Date(),
        progress: @escaping (_ done: Int, _ total: Int) -> Void = { _, _ in }
    ) async throws -> ConceptGraph {
        try await refreshIfNeeded(progress: progress)
        let dictations = self.dictations
        let preferredKeys = self.preferredKeys
        return await Task.detached(priority: .userInitiated) {
            ConceptGraphBuilder.build(dictations: dictations, range: range, now: now, preferredKeys: preferredKeys)
        }.value
    }

    /// Dictation text and extracted concepts, up to date. Used by the
    /// activity view to form and describe working sessions.
    func prepared(progress: @escaping (Int, Int) -> Void = { _, _ in }) async throws -> (sources: [ConceptSource], concepts: [Int64: [ExtractedConcept]]) {
        try await refreshIfNeeded(progress: progress)
        let concepts = Dictionary(dictations.map { ($0.dictationID, $0.concepts) }) { first, _ in first }
        return (sources, concepts)
    }

    /// Named things (projects, products, organizations) across all time,
    /// strongest first, for attributing sessions to projects.
    func projectCatalog() async throws -> (projects: [ProjectCandidate], aliases: [String: String]) {
        let graph = try await graph(range: .all)
        let projects = graph.nodes
            .filter { $0.kind == .product || $0.kind == .organization }
            .map { ProjectCandidate(key: $0.id, title: $0.title, salience: $0.salience) }
        return (projects, graph.aliases)
    }

    /// The dictations behind a concept, each cut to the sentence that names it.
    func mentions(of node: ConceptNode, limit: Int = 4) -> [ConceptMention] {
        guard let databaseManager else { return [] }
        let ids = Array(node.dictationIDs.prefix(limit))
        let sources = (try? databaseManager.fetchTranscriptionTexts(ids: ids)) ?? [:]
        return ids.compactMap { id in
            guard let source = sources[id] else { return nil }
            return ConceptMention(
                dictationID: id,
                date: source.createdAt,
                appName: source.targetAppName,
                excerpt: Self.excerpt(of: source.text, mentioning: node.title)
            )
        }
    }

    // MARK: - Refresh

    /// Concurrent callers share one refresh instead of analyzing twice.
    private func refreshIfNeeded(progress: @escaping (Int, Int) -> Void) async throws {
        if let refreshTask {
            try await refreshTask.value
            return
        }
        let task = Task { try await self.performRefresh(progress: progress) }
        refreshTask = task
        defer { refreshTask = nil }
        try await task.value
    }

    private func performRefresh(progress: @escaping (Int, Int) -> Void) async throws {
        guard let databaseManager else { return }
        let sources = try databaseManager.fetchConceptSources()
        let dictionaryTerms = try databaseManager.fetchDictionaryEntries(includeInactive: false).map(\.target)
        let signature = Self.signature(sources: sources, dictionaryTerms: dictionaryTerms)
        guard signature != sourceSignature else { return }

        var cached = try databaseManager.fetchConceptExtractions()
        let hashes = Dictionary(uniqueKeysWithValues: sources.map { ($0.id, Self.hash($0.text)) })
        let pending = sources.filter { source in
            guard let record = cached[source.id] else { return true }
            return record.textHash != hashes[source.id] || record.extractorVersion != ConceptExtractor.version
        }

        if !pending.isEmpty {
            Logger.memory.info("Concept graph: analyzing \(pending.count) of \(sources.count) dictations")
            for record in try await extractInParallel(pending, hashes: hashes, progress: progress) {
                cached[record.transcriptionID] = record
            }
        }
        if cached.count > sources.count {
            try databaseManager.pruneConceptExtractions()
        }

        let extracted = sources.map { cached[$0.id]?.concepts ?? [] }
        dictations = await Task.detached(priority: .userInitiated) {
            let matcher = DictionaryTermMatcher(terms: dictionaryTerms)
            return zip(sources, extracted).map { source, concepts in
                DictationConcepts(
                    dictationID: source.id,
                    date: source.createdAt,
                    appName: source.targetAppName,
                    concepts: matcher.merging(into: concepts, text: source.text)
                )
            }
        }.value
        self.sources = sources
        preferredKeys = Set(dictionaryTerms.map {
            ConceptExtractor.normalizedKey(ConceptExtractor.displayTitle($0), kind: .product)
        })
        sourceSignature = signature
    }

    /// Analyzes dictations across all cores, saving each batch as it lands so
    /// an interrupted first pass resumes instead of restarting.
    private func extractInParallel(
        _ pending: [ConceptSource],
        hashes: [Int64: String],
        progress: @escaping (Int, Int) -> Void
    ) async throws -> [ConceptExtractionRecord] {
        guard let databaseManager else { return [] }
        let batchSize = 48
        let batches = stride(from: 0, to: pending.count, by: batchSize).map {
            Array(pending[$0..<min($0 + batchSize, pending.count)])
        }
        let width = max(1, ProcessInfo.processInfo.activeProcessorCount - 1)
        var results: [ConceptExtractionRecord] = []
        progress(0, pending.count)

        try await withThrowingTaskGroup(of: [ConceptExtractionRecord].self) { group in
            var nextBatch = 0
            for _ in 0..<min(width, batches.count) {
                let batch = batches[nextBatch]
                nextBatch += 1
                group.addTask(priority: .utility) { Self.extract(batch, hashes: hashes) }
            }
            for try await records in group {
                try databaseManager.saveConceptExtractions(records)
                results.append(contentsOf: records)
                progress(results.count, pending.count)
                if nextBatch < batches.count {
                    let batch = batches[nextBatch]
                    nextBatch += 1
                    group.addTask(priority: .utility) { Self.extract(batch, hashes: hashes) }
                }
            }
        }
        return results
    }

    nonisolated private static func extract(_ batch: [ConceptSource], hashes: [Int64: String]) -> [ConceptExtractionRecord] {
        let now = Date()
        return batch.map { source in
            ConceptExtractionRecord(
                transcriptionID: source.id,
                textHash: hashes[source.id] ?? "",
                extractorVersion: ConceptExtractor.version,
                concepts: ConceptExtractor.concepts(in: source.text),
                extractedAt: now
            )
        }
    }

    // MARK: - Helpers

    private static func signature(sources: [ConceptSource], dictionaryTerms: [String]) -> String {
        var hasher = Hasher()
        for source in sources {
            hasher.combine(source.id)
            hasher.combine(source.text.count)
        }
        hasher.combine(dictionaryTerms.sorted())
        hasher.combine(ConceptExtractor.version)
        return "\(sources.count)#\(hasher.finalize())"
    }

    private static func hash(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    /// The sentence that mentions `title`, or the opening of the dictation.
    nonisolated static func excerpt(of text: String, mentioning title: String, limit: Int = 220) -> String {
        let cleaned = text.replacingOccurrences(of: "\n", with: " ")
        var match: String?
        cleaned.enumerateSubstrings(in: cleaned.startIndex..<cleaned.endIndex, options: .bySentences) { sentence, _, _, stop in
            guard let sentence, sentence.range(of: title, options: [.caseInsensitive, .diacriticInsensitive]) != nil else { return }
            match = sentence
            stop = true
        }
        let chosen = (match ?? cleaned).trimmingCharacters(in: .whitespacesAndNewlines)
        guard chosen.count > limit else { return chosen }
        return String(chosen.prefix(limit - 1)).trimmingCharacters(in: .whitespaces) + "…"
    }
}

/// Finds the user's dictionary terms in dictation text. Those are the names
/// they cared enough to teach Orttaai, so they count as named concepts with
/// the canonical spelling, even when NER misses them.
nonisolated struct DictionaryTermMatcher: Sendable {
    private let patterns: [(concept: ExtractedConcept, regex: NSRegularExpression)]

    init(terms: [String]) {
        var seen = Set<String>()
        patterns = terms.compactMap { raw in
            let title = ConceptExtractor.displayTitle(raw)
            let key = ConceptExtractor.normalizedKey(title, kind: .product)
            guard key.count >= 3, seen.insert(key).inserted else { return nil }
            let escaped = NSRegularExpression.escapedPattern(for: raw.trimmingCharacters(in: .whitespacesAndNewlines))
            guard let regex = try? NSRegularExpression(pattern: "(?<![\\p{L}\\p{N}])\(escaped)(?![\\p{L}\\p{N}])", options: [.caseInsensitive]) else {
                return nil
            }
            return (ExtractedConcept(key: key, title: title, kind: .product), regex)
        }
    }

    func merging(into concepts: [ExtractedConcept], text: String) -> [ExtractedConcept] {
        guard !patterns.isEmpty else { return concepts }
        var result = concepts
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        for (concept, regex) in patterns where regex.firstMatch(in: text, range: range) != nil {
            if let index = result.firstIndex(where: { $0.key == concept.key }) {
                // The dictionary spelling and kind win over NER's guess.
                if result[index].kind.precedence < concept.kind.precedence || result[index].kind == .topic {
                    result[index] = concept
                }
            } else {
                result.append(concept)
            }
        }
        return result
    }
}

/// Writes a short plain-language brief about one concept from the user's
/// own dictations, using a local model only (Ollama or LM Studio).
enum ConceptBriefWriter {
    struct LocalModel {
        let client: any LocalLLMServing
        let endpoint: String
        let candidates: [String]
    }

    enum BriefError: LocalizedError {
        case noModel(provider: String)

        var errorDescription: String? {
            switch self {
            case .noModel(let provider):
                return "No local model is installed in \(provider). Install one in Model › AI Features."
            }
        }
    }

    static func localModel(settings: AppSettings) -> LocalModel {
        LocalModel(
            client: settings.polishLLMClient,
            endpoint: settings.polishLLMEndpoint,
            // The polish model first: it is proven on this kind of text and
            // usually already loaded, so reading adds no extra memory.
            candidates: [settings.normalizedLocalLLMPolishModel, settings.localSemanticInsightModel]
        )
    }

    static func brief(
        for node: ConceptNode,
        related: [String],
        mentions: [ConceptMention],
        using local: LocalModel
    ) async throws -> String {
        let installed = try await local.client.fetchModelNames(baseURLString: local.endpoint, timeoutMs: 4_000)
        let canonical = Set(installed.map(canonicalModelName))
        guard let model = local.candidates.first(where: { canonical.contains(canonicalModelName($0)) }) else {
            throw BriefError.noModel(provider: local.client.providerKind.displayName)
        }

        let response = try await local.client.generate(
            baseURLString: local.endpoint,
            model: model,
            prompt: prompt(for: node, related: related, mentions: mentions),
            timeoutMs: 60_000,
            think: false,
            format: nil,
            formatJSONSchema: nil,
            temperature: 0.2,
            numPredict: 220,
            numContext: 4_096,
            keepAlive: "5m"
        )
        return response
            .replacingOccurrences(of: #"<think>[\s\S]*?</think>"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func prompt(for node: ConceptNode, related: [String], mentions: [ConceptMention]) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        let excerpts = mentions.map { mention in
            "- [\(formatter.string(from: mention.date)), \(mention.appName ?? "dictation")] \(mention.excerpt)"
        }.joined(separator: "\n")
        return """
        These are excerpts from someone's own voice dictations that mention "\(node.title)".
        It came up in \(node.mentionCount) dictations over \(node.dayCount) days. It often comes up alongside: \(related.prefix(5).joined(separator: ", ")).

        Excerpts:
        \(excerpts)

        In 2 or 3 short sentences, addressed to them as "you", say what "\(node.title)" is to them, what they are doing or deciding about it, and anything that looks unresolved. Use only the excerpts. Be specific. No preamble, no bullet points.
        """
    }

    private static func canonicalModelName(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return trimmed.contains(":") ? trimmed : "\(trimmed):latest"
    }
}
