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
                {"source": "otta ai", "target": "Orttaai", "confidence": 0.8, "evidence": "Written as otta ai in 3 dictations"}
              ],
              "snippets": [
                {"trigger": "my address", "expansion": "12 Harbour Road, Lagos", "confidence": 0.7, "evidence": "Dictated word for word 4 times"}
              ]
            }

            Rules:
            - Write the values only. Never put labels such as "Misheard term:" inside a value.
            - dictionary.source must be copied exactly from the history: a name or term the speech recognizer got wrong.
            - dictionary.target is how it should be spelled, and must sound like the source. Never pair words that sound different, and never expand an acronym.
            - snippets.expansion must be text that appears word for word in the history more than once; the trigger is 2 to 4 words.
            - confidence must be between 0 and 1.
            - avoid duplicates with existing entries.
            - keep output concise; maximum 8 dictionary items and 8 snippets. Return empty lists when nothing qualifies.

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
                return Self.sanitize(
                    parsed: parsed,
                    history: transcriptions.map(\.text),
                    existingDictionary: existingDictionary,
                    existingSnippets: existingSnippets
                )
            } catch {
                Logger.memory.error("Apple FM analysis failed: \(error.localizedDescription)")
                return []
            }
        }
        #endif
        return []
    }

    /// Labels the model sometimes copies into a value ("Misheard term: X").
    private static let labelPrefix = try! NSRegularExpression(
        pattern: #"^\s*(misheard term|preferred term|short trigger|expanded text|source|target|trigger|expansion|heard as|suggested)\s*[:\-–]\s*"#,
        options: [.caseInsensitive]
    )

    nonisolated static func strippingLabel(_ value: String) -> String {
        var text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let range = NSRange(text.startIndex..., in: text)
        if let match = labelPrefix.firstMatch(in: text, range: range), let swiftRange = Range(match.range, in: text) {
            text.removeSubrange(swiftRange)
        }
        return text.trimmingCharacters(in: CharacterSet(charactersIn: "\"'“”‘’ ").union(.whitespacesAndNewlines))
    }

    /// A dictionary pair is kept only when the heard form was actually said
    /// and the replacement sounds like it: a misspelled name, not a different
    /// word or an expanded acronym.
    nonisolated static func isPlausibleDictionaryPair(source: String, target: String, history: String) -> Bool {
        guard history.contains(EditCorrectionFinder.normalizedWhitespace(source.lowercased())) else { return false }
        let heard = source.lowercased().filter { $0.isLetter || $0.isNumber }
        let wanted = target.lowercased().filter { $0.isLetter || $0.isNumber }
        guard !heard.isEmpty, !wanted.isEmpty, heard != wanted || source != target else { return false }
        let distance = WordBoostGuard.editDistance(heard, wanted)
        return distance <= max(2, max(heard.count, wanted.count) / 2)
    }

    static func sanitize(
        parsed: AppleLearningResponse,
        history: [String],
        existingDictionary: [DictionaryEntry],
        existingSnippets: [SnippetEntry]
    ) -> [LearningSuggestionDraft] {
        let historyText = EditCorrectionFinder.normalizedWhitespace(history.joined(separator: " \n ").lowercased())
        let existingDictionarySources = Set(
            existingDictionary.map { PersonalMemoryNormalizer.normalizedKey($0.source) }
        )
        let existingSnippetTriggers = Set(
            existingSnippets.map { PersonalMemoryNormalizer.normalizedKey($0.trigger) }
        )

        var drafts: [LearningSuggestionDraft] = []

        for item in parsed.dictionary.prefix(8) {
            let source = strippingLabel(item.source)
            let target = strippingLabel(item.target)
            let normalizedSource = PersonalMemoryNormalizer.normalizedKey(source)

            guard !source.isEmpty, !target.isEmpty, source != target else { continue }
            guard !existingDictionarySources.contains(normalizedSource) else { continue }
            guard isPlausibleDictionaryPair(source: source, target: target, history: historyText) else { continue }

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
            let trigger = strippingLabel(item.trigger)
            let expansion = strippingLabel(item.expansion)
            let normalizedTrigger = PersonalMemoryNormalizer.normalizedKey(trigger)

            guard !trigger.isEmpty, !expansion.isEmpty, trigger != expansion else { continue }
            // A snippet is for text the person really repeats, never one the
            // model wrote itself.
            guard trigger.split(separator: " ").count <= 5,
                  historyText.contains(EditCorrectionFinder.normalizedWhitespace(expansion.lowercased())) else { continue }
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

struct AppleLearningResponse: Decodable {
    let dictionary: [AppleDictionarySuggestion]
    let snippets: [AppleSnippetSuggestion]
}

struct AppleDictionarySuggestion: Decodable {
    let source: String
    let target: String
    let confidence: Double
    let evidence: String?
}

struct AppleSnippetSuggestion: Decodable {
    let trigger: String
    let expansion: String
    let confidence: Double
    let evidence: String?
}
