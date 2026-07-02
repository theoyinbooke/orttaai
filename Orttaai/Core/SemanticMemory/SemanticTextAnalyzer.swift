// SemanticTextAnalyzer.swift
// Orttaai

import Foundation
import NaturalLanguage

/// A concept extracted from dictated text.
struct SemanticConcept: Hashable {
    /// Canonical key (lemmatized, lowercased) used for node identity so that
    /// surface variants ("insights", "Insight") merge into one concept.
    let key: String
    /// Human-readable display form.
    let title: String
}

/// A named entity extracted from dictated text.
struct SemanticNamedEntity: Hashable {
    let key: String
    let title: String
    /// "Person", "Place", "Organization", or "Name" when the source is the
    /// capitalized-run fallback.
    let category: String
}

/// On-device linguistic extraction built on Apple's NaturalLanguage framework.
/// Replaces raw word-frequency topics (which surfaced stopword-grade tokens
/// like "going"/"here") with lemmatized, part-of-speech-filtered concepts and
/// real named-entity recognition. Deterministic — no model download, no LLM.
enum SemanticTextAnalyzer {

    // MARK: - Topics

    /// Salient noun concepts, most salient first. Nouns and consecutive-noun
    /// phrases are counted by lemma; phrases outrank single nouns.
    static func topicConcepts(in text: String, limit: Int) -> [SemanticConcept] {
        guard limit > 0, !text.isEmpty else { return [] }

        let tagger = NLTagger(tagSchemes: [.lexicalClass, .lemma])
        tagger.string = text
        let options: NLTagger.Options = [.omitWhitespace, .omitPunctuation, .omitOther]

        struct Candidate {
            var score: Double
            var title: String
        }
        var candidates: [String: Candidate] = [:]
        var phraseLemmas: [String] = []
        var phraseSurfaces: [String] = []

        func register(lemmas: [String], surfaces: [String], score: Double) {
            let key = lemmas.joined(separator: " ")
            guard !key.isEmpty else { return }
            let title = surfaces.joined(separator: " ")
            if var existing = candidates[key] {
                existing.score += score
                candidates[key] = existing
            } else {
                candidates[key] = Candidate(score: score, title: title)
            }
        }

        func flushPhrase() {
            defer {
                phraseLemmas.removeAll(keepingCapacity: true)
                phraseSurfaces.removeAll(keepingCapacity: true)
            }
            guard !phraseLemmas.isEmpty else { return }
            // Each noun counts alone; consecutive nouns also count as a phrase
            // ("memory graph"), weighted above their parts so real concepts
            // outrank generic single nouns.
            for (lemma, surface) in zip(phraseLemmas, phraseSurfaces) {
                register(lemmas: [lemma], surfaces: [surface], score: 1.0)
            }
            if phraseLemmas.count >= 2 {
                let head = Array(phraseLemmas.suffix(2))
                let headSurfaces = Array(phraseSurfaces.suffix(2))
                register(lemmas: head, surfaces: headSurfaces, score: 1.8)
            }
        }

        tagger.enumerateTags(
            in: text.startIndex..<text.endIndex,
            unit: .word,
            scheme: .lexicalClass,
            options: options
        ) { tag, range in
            let surface = String(text[range])
            guard tag == .noun, surface.count >= 3 else {
                flushPhrase()
                return true
            }

            let lemmaTag = tagger.tag(at: range.lowerBound, unit: .word, scheme: .lemma).0
            let lemma = (lemmaTag?.rawValue ?? surface).lowercased()
            guard lemma.count >= 3, !genericNouns.contains(lemma) else {
                flushPhrase()
                return true
            }

            phraseLemmas.append(lemma)
            phraseSurfaces.append(surface.lowercased())
            return true
        }
        flushPhrase()

        return candidates
            .sorted {
                if $0.value.score == $1.value.score { return $0.key < $1.key }
                return $0.value.score > $1.value.score
            }
            .prefix(limit)
            .map { SemanticConcept(key: $0.key, title: $0.value.title.capitalized) }
    }

    // MARK: - Entities

    /// Named entities via on-device NER, with a capitalized-run fallback for
    /// product/tool names NER doesn't know. Most frequent first.
    static func namedEntities(in text: String, limit: Int) -> [SemanticNamedEntity] {
        guard limit > 0, !text.isEmpty else { return [] }

        struct Candidate {
            var count: Int
            var title: String
            var category: String
        }
        var candidates: [String: Candidate] = [:]

        func register(title: String, category: String) {
            let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            guard trimmed.count >= 3, trimmed.count <= 64 else { return }
            let key = trimmed.lowercased()
            guard !entitySentenceStarters.contains(key) else { return }
            if var existing = candidates[key] {
                existing.count += 1
                // Prefer the NER category over the fallback's generic "Name".
                if existing.category == "Name", category != "Name" {
                    existing.category = category
                }
                candidates[key] = existing
            } else {
                candidates[key] = Candidate(count: 1, title: trimmed, category: category)
            }
        }

        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = text
        tagger.enumerateTags(
            in: text.startIndex..<text.endIndex,
            unit: .word,
            scheme: .nameType,
            options: [.omitWhitespace, .omitPunctuation, .omitOther, .joinNames]
        ) { tag, range in
            guard let tag else { return true }
            switch tag {
            case .personalName:
                register(title: String(text[range]), category: "Person")
            case .placeName:
                register(title: String(text[range]), category: "Place")
            case .organizationName:
                register(title: String(text[range]), category: "Organization")
            default:
                break
            }
            return true
        }

        for run in capitalizedRuns(in: text) {
            register(title: run, category: "Name")
        }

        return candidates
            .sorted {
                if $0.value.count == $1.value.count { return $0.key < $1.key }
                return $0.value.count > $1.value.count
            }
            .prefix(limit)
            .map { SemanticNamedEntity(key: $0.key, title: $0.value.title, category: $0.value.category) }
    }

    /// Runs of 2+ capitalized words that are not sentence starts ("Whisper
    /// Large", "Memory Graph"). Catches tool/product names NER misses.
    private static func capitalizedRuns(in text: String) -> [String] {
        var runs: [String] = []
        var current: [String] = []
        var previousEndedSentence = true

        let words = text.split { !($0.isLetter || $0.isNumber || $0 == "'" || $0 == "-" || $0 == ".") }

        for rawWord in words {
            let endsSentence = rawWord.hasSuffix(".")
            let word = String(rawWord).trimmingCharacters(in: .punctuationCharacters)
            guard let first = word.unicodeScalars.first else {
                if current.count >= 2 { runs.append(current.joined(separator: " ")) }
                current.removeAll()
                previousEndedSentence = endsSentence
                continue
            }

            let isCapitalized = CharacterSet.uppercaseLetters.contains(first) && word.count > 2
            // A capitalized function word at sentence start ("Do", "Can",
            // "The") can't begin a run — that's what let junk like "Do you"
            // through in the old heuristic. A capitalized content word can,
            // so sentence-leading entities ("Project Atlas …") still count.
            let blockedStarter = previousEndedSentence && runFunctionWords.contains(word.lowercased())
            let canStartRun = isCapitalized && !blockedStarter

            if isCapitalized && (canStartRun || !current.isEmpty) {
                current.append(word)
            } else {
                if current.count >= 2 { runs.append(current.joined(separator: " ")) }
                current.removeAll()
            }
            previousEndedSentence = endsSentence
        }
        if current.count >= 2 { runs.append(current.joined(separator: " ")) }
        return runs
    }

    // MARK: - Vocabulary

    /// Nouns too generic to be a life concept in dictated speech.
    private static let genericNouns: Set<String> = [
        "thing", "things", "stuff", "way", "ways", "lot", "lots", "bit", "bits",
        "kind", "kinds", "sort", "sorts", "one", "ones", "something", "anything",
        "everything", "nothing", "someone", "anyone", "everyone", "guy", "guys",
        "part", "parts", "place", "case", "point", "fact", "idea", "example",
        "second", "seconds", "minute", "minutes", "moment", "today", "tomorrow",
        "yesterday", "tonight", "morning", "evening", "afternoon", "night",
        "day", "days", "week", "weeks", "hour", "hours", "time", "times",
        "okay", "yeah", "yes", "hmm"
    ]

    /// Common words that, when capitalized at a sentence start, are grammar
    /// rather than names.
    private static let runFunctionWords: Set<String> = [
        "the", "this", "that", "these", "those", "there", "then", "than",
        "and", "but", "for", "nor", "yet", "not", "now", "also", "just",
        "you", "your", "they", "them", "their", "she", "his", "her", "its",
        "our", "was", "were", "are", "will", "would", "could", "should",
        "can", "may", "might", "must", "shall", "did", "does", "doing",
        "have", "has", "had", "let", "lets", "please", "make", "makes",
        "take", "give", "come", "look", "what", "when", "where", "which",
        "who", "whom", "whose", "why", "how", "yes", "yeah", "okay", "well",
        "maybe", "because", "after", "before", "today", "tomorrow",
        "yesterday", "here", "some", "any", "all", "one", "two", "very",
        "with", "from", "into", "about", "over", "under", "again", "once"
    ]

    private static let entitySentenceStarters: Set<String> = [
        "the", "this", "that", "these", "those", "when", "where", "what",
        "please", "today", "tomorrow", "yesterday", "after", "before", "because",
        "do you", "can you", "i want", "i need", "let us", "make sure"
    ]
}
