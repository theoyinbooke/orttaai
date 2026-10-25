// WordBoost.swift
// Orttaai

import Foundation

/// One Personal Memory dictionary word for Express's Word Boost: the spelling
/// to produce, and the misheard spellings the user mapped to it.
nonisolated struct WordBoostTerm: Sendable, Equatable {
    let text: String
    let aliases: [String]
}

/// Supplies the Word Boost vocabulary, snapshotted once per dictation like the
/// recognizer bias terms; the database is never read on the audio path.
protocol WordBoostVocabularyProviding {
    func wordBoostTerms() -> [WordBoostTerm]
}

/// Decides which Word Boost replacements to keep. The CTC rescorer proposes
/// replacing a heard phrase with a dictionary term when the term sounds close
/// enough; on the gauntlet corpora one in five of those proposals turned an
/// ordinary word into a product name (code -> Xcode, release -> camelCase).
/// The rules below were fitted on 134 applied proposals across the clean,
/// realistic and real-voice corpora: they keep 103 of 104 correct ones and
/// none of the 27 wrong ones (gauntlet/asr_eval/word_boost_guard.json).
nonisolated enum WordBoostGuard {
    struct Candidate: Sendable, Equatable {
        /// The phrase the speech model heard, as it appears in the transcript.
        let heard: String
        let term: String
        /// CTC log-probability of the term minus that of the heard phrase.
        let acousticMargin: Float
    }

    /// Below this the term sounds clearly worse than what was heard.
    static let marginFloor: Float = -4.0
    /// Replacing ordinary English words needs the term to sound nearly as
    /// likely as the words themselves.
    static let ordinaryWordsMargin: Float = -0.75
    /// The heard phrase must be spelled at least this much like the term.
    /// Every correct proposal in the gauntlet set scores 0.56 or more; the
    /// swaps users reported score far lower (Mac mini -> Meetumo 0.14,
    /// space bar -> supabase 0.38, make a -> Arsenal 0.29), and they passed
    /// on margin alone because a word like "I'm" or "mini" was missing from
    /// the word list.
    static let minimumSpellingSimilarity: Float = 0.5
    /// A near-spelled join may differ by this many letters...
    static let nearSpelledMaxEdits = 2
    /// ...when the term is at least this long, so code -> Xcode never counts.
    static let nearSpelledMinLength = 12

    static func accepts(_ candidate: Candidate) -> Bool {
        let heardWords = words(in: candidate.heard)
        let termWords = words(in: candidate.term)
        let heardLetters = heardWords.joined()
        let termLetters = termWords.joined()
        guard !heardWords.isEmpty, !termLetters.isEmpty else { return false }

        // "use effect callback" -> useEffectCallback: the user's spelling of
        // exactly what was heard.
        if heardLetters == termLetters
            || (termLetters.count >= nearSpelledMinLength
                && editDistance(heardLetters, termLetters) <= nearSpelledMaxEdits) {
            return true
        }
        if spellingSimilarity(heardLetters, termLetters) < minimumSpellingSimilarity {
            return false
        }
        // "keep LM Studio" -> "LM Studio" would delete a spoken word.
        if heardWords.count > termWords.count, termWords.allSatisfy(heardWords.contains) {
            return false
        }
        if candidate.acousticMargin < marginFloor {
            return false
        }
        if EnglishLexicon.isAvailable, heardWords.allSatisfy(EnglishLexicon.isRealWord) {
            return candidate.acousticMargin >= ordinaryWordsMargin
        }
        return true
    }

    /// Lowercased letters, digits and apostrophes, punctuation dropped.
    static func words(in text: String) -> [String] {
        text.lowercased()
            .replacingOccurrences(of: "\u{2019}", with: "'")
            .split { !($0.isLetter || $0.isNumber || $0 == "'") }
            .map(String.init)
    }

    /// 1 for identical letters, 0 for nothing in common.
    static func spellingSimilarity(_ a: String, _ b: String) -> Float {
        let length = max(a.count, b.count)
        guard length > 0 else { return 1 }
        return 1 - Float(editDistance(a, b)) / Float(length)
    }

    static func editDistance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        guard !a.isEmpty else { return b.count }
        guard !b.isEmpty else { return a.count }
        var previous = Array(0...b.count)
        for i in 1...a.count {
            var current = [i] + [Int](repeating: 0, count: b.count)
            for j in 1...b.count {
                current[j] = min(
                    previous[j] + 1,
                    current[j - 1] + 1,
                    previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1)
                )
            }
            previous = current
        }
        return previous[b.count]
    }
}
