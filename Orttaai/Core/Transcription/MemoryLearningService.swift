// MemoryLearningService.swift
// Orttaai

import Foundation
import os

#if canImport(FoundationModels)
import FoundationModels
#endif

struct MemoryLearningRunResult {
    let analyzerName: String
    let insertedCount: Int
    let historySampleCount: Int
    let usedFallback: Bool
}

protocol LearningAnalyzing {
    var name: String { get }
    func isAvailable() -> Bool
    func analyze(
        transcriptions: [Transcription],
        existingDictionary: [DictionaryEntry],
        existingSnippets: [SnippetEntry]
    ) async -> [LearningSuggestionDraft]
}

final class HeuristicLearningAnalyzer: LearningAnalyzing {
    let name = "Heuristic Analyzer"

    func isAvailable() -> Bool {
        true
    }

    func analyze(
        transcriptions: [Transcription],
        existingDictionary: [DictionaryEntry],
        existingSnippets: [SnippetEntry]
    ) async -> [LearningSuggestionDraft] {
        let existingSnippetTriggers = Set(
            existingSnippets.map { PersonalMemoryNormalizer.normalizedKey($0.trigger) }
        )

        var normalizedTextCounts: [String: Int] = [:]
        var representativeTextByKey: [String: String] = [:]

        for record in transcriptions {
            let text = record.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard text.count >= 18, text.count <= 180 else { continue }
            let words = text.split(whereSeparator: \.isWhitespace)
            guard words.count >= 4, words.count <= 20 else { continue }

            let key = PersonalMemoryNormalizer.normalizedKey(text)
            guard !key.isEmpty else { continue }

            normalizedTextCounts[key, default: 0] += 1
            if representativeTextByKey[key] == nil {
                representativeTextByKey[key] = text
            }
        }

        let topRepeated = normalizedTextCounts
            .filter { $0.value >= 2 }
            .sorted {
                if $0.value == $1.value {
                    return $0.key < $1.key
                }
                return $0.value > $1.value
            }
            .prefix(8)

        var drafts: [LearningSuggestionDraft] = []
        for (key, count) in topRepeated {
            guard let expansion = representativeTextByKey[key] else { continue }
            let trigger = suggestedTrigger(from: key)
            let normalizedTrigger = PersonalMemoryNormalizer.normalizedKey(trigger)
            guard !normalizedTrigger.isEmpty else { continue }
            guard !existingSnippetTriggers.contains(normalizedTrigger) else { continue }

            let confidence = min(0.82, 0.45 + Double(count) * 0.08)
            drafts.append(
                LearningSuggestionDraft(
                    type: .snippet,
                    candidateSource: trigger,
                    candidateTarget: expansion,
                    confidence: confidence,
                    evidence: "Appeared \(count)x in recent dictations."
                )
            )
        }

        return drafts
    }

    private func suggestedTrigger(from normalizedText: String) -> String {
        let words = normalizedText.split(separator: " ")
        if words.isEmpty {
            return normalizedText
        }

        let targetCount = min(4, max(2, words.count / 3))
        return words.prefix(targetCount).joined(separator: " ")
    }
}

final class AppleFoundationLearningAnalyzer: LearningAnalyzing {
    let name = "Apple Foundation Models"

    func isAvailable() -> Bool {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            let model = SystemLanguageModel.default
            if case .available = model.availability {
                return true
            }
        }
        #endif
        return false
    }

    func analyze(
        transcriptions: [Transcription],
        existingDictionary: [DictionaryEntry],
        existingSnippets: [SnippetEntry]
    ) async -> [LearningSuggestionDraft] {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            let existingDictionaryTerms = existingDictionary.map { $0.source }.joined(separator: ", ")
            let existingSnippetTriggers = existingSnippets.map { $0.trigger }.joined(separator: ", ")

            let historyLines = transcriptions
                .prefix(120)
                .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .map { line -> String in
                    if line.count > 220 {
                        return String(line.prefix(220)) + "..."
                    }
                    return line
                }

            guard !historyLines.isEmpty else { return [] }

            let prompt = """
            You are helping build a personal on-device dictation assistant memory.
            Analyze the history and extract reusable suggestions.

            Return ONLY valid JSON with this exact shape:
            {
              "dictionary": [
                {"source": "misheard term", "target": "preferred term", "confidence": 0.0, "evidence": "short reason"}
              ],
              "snippets": [
                {"trigger": "short trigger", "expansion": "expanded text", "confidence": 0.0, "evidence": "short reason"}
              ]
            }

            Rules:
            - confidence must be between 0 and 1.
            - dictionary.source should be what user likely says/types; dictionary.target is preferred replacement.
            - snippets should be high-value reusable expansions.
            - avoid duplicates with existing entries.
            - keep output concise; maximum 8 dictionary items and 8 snippets.

            Existing dictionary terms:
            \(existingDictionaryTerms)

            Existing snippet triggers:
            \(existingSnippetTriggers)

            History:
            \(historyLines.enumerated().map { "[\($0.offset + 1)] \($0.element)" }.joined(separator: "\n"))
            """

            do {
                let session = LanguageModelSession()
                let response = try await session.respond(to: prompt)
                guard let jsonPayload = extractJSONObject(from: response.content) else {
                    Logger.memory.warning("Apple FM response did not include a JSON payload")
                    return []
                }

                let decoder = JSONDecoder()
                guard let data = jsonPayload.data(using: .utf8) else { return [] }
                let parsed = try decoder.decode(AppleLearningResponse.self, from: data)
                return sanitize(parsed: parsed, existingDictionary: existingDictionary, existingSnippets: existingSnippets)
            } catch {
                Logger.memory.error("Apple FM analysis failed: \(error.localizedDescription)")
                return []
            }
        }
        #endif
        return []
    }

    private func sanitize(
        parsed: AppleLearningResponse,
        existingDictionary: [DictionaryEntry],
        existingSnippets: [SnippetEntry]
    ) -> [LearningSuggestionDraft] {
        let existingDictionarySources = Set(
            existingDictionary.map { PersonalMemoryNormalizer.normalizedKey($0.source) }
        )
        let existingSnippetTriggers = Set(
            existingSnippets.map { PersonalMemoryNormalizer.normalizedKey($0.trigger) }
        )

        var drafts: [LearningSuggestionDraft] = []

        for item in parsed.dictionary.prefix(8) {
            let source = item.source.trimmingCharacters(in: .whitespacesAndNewlines)
            let target = item.target.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalizedSource = PersonalMemoryNormalizer.normalizedKey(source)

            guard !source.isEmpty, !target.isEmpty, source != target else { continue }
            guard !existingDictionarySources.contains(normalizedSource) else { continue }

            drafts.append(
                LearningSuggestionDraft(
                    type: .dictionary,
                    candidateSource: source,
                    candidateTarget: target,
                    confidence: min(max(item.confidence, 0), 1),
                    evidence: item.evidence
                )
            )
        }

        for item in parsed.snippets.prefix(8) {
            let trigger = item.trigger.trimmingCharacters(in: .whitespacesAndNewlines)
            let expansion = item.expansion.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalizedTrigger = PersonalMemoryNormalizer.normalizedKey(trigger)

            guard !trigger.isEmpty, !expansion.isEmpty, trigger != expansion else { continue }
            guard !existingSnippetTriggers.contains(normalizedTrigger) else { continue }

            drafts.append(
                LearningSuggestionDraft(
                    type: .snippet,
                    candidateSource: trigger,
                    candidateTarget: expansion,
                    confidence: min(max(item.confidence, 0), 1),
                    evidence: item.evidence
                )
            )
        }

        return drafts
    }

    private func extractJSONObject(from text: String) -> String? {
        guard let firstBrace = text.firstIndex(of: "{"),
              let lastBrace = text.lastIndex(of: "}") else {
            return nil
        }
        return String(text[firstBrace...lastBrace])
    }
}

final class MemoryLearningService {
    private let databaseManager: DatabaseManager
    private let settings: AppSettings
    private let appleAnalyzer: LearningAnalyzing
    private let heuristicAnalyzer: LearningAnalyzing

    init(
        databaseManager: DatabaseManager,
        settings: AppSettings = AppSettings(),
        appleAnalyzer: LearningAnalyzing = AppleFoundationLearningAnalyzer(),
        heuristicAnalyzer: LearningAnalyzing = HeuristicLearningAnalyzer()
    ) {
        self.databaseManager = databaseManager
        self.settings = settings
        self.appleAnalyzer = appleAnalyzer
        self.heuristicAnalyzer = heuristicAnalyzer
    }

    func analyzeRecentHistory(limit: Int = 120) async -> MemoryLearningRunResult {
        do {
            let history = try databaseManager.fetchRecent(limit: limit)
            guard !history.isEmpty else {
                return MemoryLearningRunResult(
                    analyzerName: heuristicAnalyzer.name,
                    insertedCount: 0,
                    historySampleCount: 0,
                    usedFallback: false
                )
            }

            let dictionaryEntries = try databaseManager.fetchDictionaryEntries()
            let snippetEntries = try databaseManager.fetchSnippetEntries()

            let wantsAppleAnalyzer = settings.aiSuggestionsEnabled
            let shouldUseApple = wantsAppleAnalyzer && appleAnalyzer.isAvailable()
            let primaryAnalyzer = shouldUseApple ? appleAnalyzer : heuristicAnalyzer

            var usedFallback = false
            var drafts = await primaryAnalyzer.analyze(
                transcriptions: history,
                existingDictionary: dictionaryEntries,
                existingSnippets: snippetEntries
            )

            if drafts.isEmpty, shouldUseApple {
                drafts = await heuristicAnalyzer.analyze(
                    transcriptions: history,
                    existingDictionary: dictionaryEntries,
                    existingSnippets: snippetEntries
                )
                usedFallback = true
            }

            let saved = try databaseManager.saveLearningSuggestions(drafts)
            return MemoryLearningRunResult(
                analyzerName: shouldUseApple && !usedFallback ? appleAnalyzer.name : heuristicAnalyzer.name,
                insertedCount: saved,
                historySampleCount: history.count,
                usedFallback: usedFallback
            )
        } catch {
            Logger.memory.error("Failed to analyze history: \(error.localizedDescription)")
            return MemoryLearningRunResult(
                analyzerName: heuristicAnalyzer.name,
                insertedCount: 0,
                historySampleCount: 0,
                usedFallback: false
            )
        }
    }
}

private struct AppleLearningResponse: Decodable {
    let dictionary: [AppleDictionarySuggestion]
    let snippets: [AppleSnippetSuggestion]
}

private struct AppleDictionarySuggestion: Decodable {
    let source: String
    let target: String
    let confidence: Double
    let evidence: String?
}

private struct AppleSnippetSuggestion: Decodable {
    let trigger: String
    let expansion: String
    let confidence: Double
    let evidence: String?
}
