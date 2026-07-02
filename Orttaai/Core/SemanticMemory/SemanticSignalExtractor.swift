// SemanticSignalExtractor.swift
// Orttaai

import Foundation
import NaturalLanguage

/// Deterministic extraction of intent-bearing signals from dictated text:
/// commitments the user voiced, questions they asked, decisions they stated,
/// and tone. Always available (no LLM, no network); an LLM extractor can add
/// richer families later under its own modelID without touching these rows.
enum SemanticSignalExtractor {
    static let heuristicModelID = "heuristic-v1"

    struct ExtractedSignal: Hashable {
        let family: SemanticSignalFamily
        let value: String
        let confidence: Double
    }

    static func signals(in text: String) -> [ExtractedSignal] {
        let sentences = Self.sentences(in: text)
        guard !sentences.isEmpty else { return [] }

        var results: [ExtractedSignal] = []
        var frustrationCues = 0
        var excitementCues = 0
        var questionCount = 0
        var commitmentCount = 0
        var imperativeCount = 0

        for sentence in sentences {
            let lowered = sentence.lowercased()

            if let confidence = commitmentConfidence(for: lowered) {
                results.append(.init(family: .commitment, value: clipped(sentence), confidence: confidence))
                commitmentCount += 1
            }

            if let confidence = questionConfidence(for: sentence, lowered: lowered) {
                results.append(.init(family: .question, value: clipped(sentence), confidence: confidence))
                questionCount += 1
            }

            if decisionCues.contains(where: lowered.contains) {
                results.append(.init(family: .decision, value: clipped(sentence), confidence: 0.8))
            }

            frustrationCues += frustrationLexicon.filter(lowered.contains).count
            excitementCues += excitementLexicon.filter(lowered.contains).count
            if startsImperatively(lowered) {
                imperativeCount += 1
            }
        }

        // One tone signal per chunk, only when word-supported (never inferred).
        if frustrationCues > 0 || excitementCues > 0 {
            let dominant = frustrationCues >= excitementCues ? "frustrated" : "energized"
            let cueCount = max(frustrationCues, excitementCues)
            results.append(.init(
                family: .tone,
                value: dominant,
                confidence: min(0.9, 0.5 + 0.1 * Double(cueCount))
            ))
        }

        // One coarse intent per chunk, derived from the strongest evidence.
        let intent: String
        if imperativeCount >= max(1, sentences.count / 3) {
            intent = "instruct"
        } else if questionCount > 0, questionCount >= commitmentCount {
            intent = "ask"
        } else if commitmentCount > 0 {
            intent = "plan"
        } else {
            intent = "reflect"
        }
        results.append(.init(family: .intent, value: intent, confidence: 0.6))

        return results
    }

    // MARK: - Sentence classification

    private static func commitmentConfidence(for lowered: String) -> Double? {
        if strongCommitmentCues.contains(where: lowered.contains) { return 0.9 }
        if softCommitmentCues.contains(where: lowered.contains) { return 0.7 }
        return nil
    }

    private static func questionConfidence(for sentence: String, lowered: String) -> Double? {
        if sentence.hasSuffix("?") { return 0.95 }
        // ASR frequently drops question marks, so interrogative openers count.
        if interrogativeOpeners.contains(where: lowered.hasPrefix) { return 0.6 }
        return nil
    }

    private static func startsImperatively(_ lowered: String) -> Bool {
        if imperativeOpeners.contains(where: lowered.hasPrefix) { return true }
        guard let firstWord = lowered.split(whereSeparator: \.isWhitespace).first else { return false }
        return imperativeVerbs.contains(String(firstWord))
    }

    // MARK: - Helpers

    private static func sentences(in text: String) -> [String] {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { return [] }
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = trimmedText
        var sentences: [String] = []
        tokenizer.enumerateTokens(in: trimmedText.startIndex..<trimmedText.endIndex) { range, _ in
            let sentence = trimmedText[range].trimmingCharacters(in: .whitespacesAndNewlines)
            if sentence.count >= 8 {
                sentences.append(sentence)
            }
            return true
        }
        return sentences
    }

    private static func clipped(_ sentence: String, limit: Int = 200) -> String {
        guard sentence.count > limit else { return sentence }
        return String(sentence.prefix(limit - 1)) + "…"
    }

    // MARK: - Lexicons

    private static let strongCommitmentCues = [
        "i will ", "i'll ", "i am going to ", "i'm going to ", "i plan to ",
        "i promise", "i want us to ", "i am about to "
    ]

    private static let softCommitmentCues = [
        "i need to ", "i have to ", "i should ", "we need to ", "we should ",
        "we have to ", "let me ", "i want to ", "next step is "
    ]

    private static let interrogativeOpeners = [
        "do you", "can you", "can we", "could you", "could we", "should we",
        "should i", "would you", "what ", "what's", "why ", "how ", "where ",
        "when ", "which ", "who ", "is there", "are there", "is it", "are we",
        "did you", "does it", "will it", "am i"
    ]

    private static let imperativeOpeners = [
        "please ", "can you ", "i want you to ", "make sure ", "go ahead",
        "let's ", "let us "
    ]

    private static let imperativeVerbs: Set<String> = [
        "make", "add", "fix", "update", "create", "remove", "delete", "change",
        "build", "implement", "write", "generate", "check", "run", "test",
        "use", "move", "rename", "refactor", "install", "open", "close",
        "show", "give", "find", "search", "look", "try", "start", "stop",
        "ensure", "verify", "investigate", "review", "explain", "help"
    ]

    private static let decisionCues = [
        "let's go with", "let us go with", "we'll use", "we will use",
        "i decided", "we decided", "we agreed", "i've chosen", "i have chosen",
        "we're going with", "we are going with", "final decision",
        "i'm settling on", "go with the", "stick with"
    ]

    private static let frustrationLexicon = [
        "stuck", "blocked", "confusing", "frustrat", "annoying", "not working",
        "doesn't work", "does not work", "failed", "failing", "broken",
        "still broken", "wrong again", "keeps happening", "no idea why",
        "can't figure", "cannot figure", "glitch", "the bug", "this bug"
    ]

    private static let excitementLexicon = [
        "i love", "awesome", "amazing", "so fast", "perfect", "excellent",
        "fantastic", "well done", "great job", "beautiful", "works great",
        "so good", "impressive", "appreciate"
    ]
}
