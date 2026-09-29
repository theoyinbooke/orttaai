// FuzzyDictionaryMatcher.swift
// Orttaai

import Foundation
import os

/// Common English words, used to keep the fuzzy dictionary pass away from
/// ordinary vocabulary (verse must never become Vercel). Loaded once, lazily,
/// from the bundled english-words.txt; provenance and the size trade-offs are
/// documented in scripts/build_english_wordlist.py (public-domain Webster's
/// Second, trimmed, plus a few modern words). Inflected forms are not listed:
/// lookups strip common suffixes instead.
enum EnglishLexicon {
    private final class BundleToken {}

    private static let words: Set<String> = {
        guard let url = Bundle(for: BundleToken.self).url(forResource: "english-words", withExtension: "txt"),
              let contents = try? String(contentsOf: url, encoding: .utf8) else {
            Logger.transcription.error("english-words.txt missing from bundle; fuzzy dictionary matching disabled")
            return []
        }
        return Set(contents.split(separator: "\n").map(String.init))
    }()

    /// Words under three letters are not in the file.
    private static let shortWords: Set<String> = [
        "a", "i", "am", "an", "as", "at", "be", "by", "do", "go", "he", "hi", "if", "in", "is", "it",
        "me", "my", "no", "of", "oh", "ok", "on", "or", "so", "to", "up", "us", "we"
    ]

    private static let suffixRules: [(suffix: String, restorations: [String])] = [
        ("ies", ["y"]), ("es", [""]), ("s", [""]), ("ed", ["", "e"]), ("d", [""]),
        ("ing", ["", "e"]), ("ly", [""]), ("er", ["", "e"]), ("ers", ["", "e"]),
        ("est", ["", "e"]), ("ness", [""])
    ]

    /// False when the resource could not be loaded, in which case callers
    /// must not assume an unlisted word is unusual.
    static var isAvailable: Bool { !words.isEmpty }

    /// `word` must already be lowercase. Accepts listed words and their
    /// regular inflections (verses, codes, stopped, running).
    static func isRealWord(_ word: String) -> Bool {
        if word.count < 3 { return shortWords.contains(word) }
        if words.contains(word) { return true }
        return stems(of: word).contains(where: words.contains)
    }

    /// The base forms `word` could be a regular inflection of, with the
    /// suffix stripped and any dropped letter restored (stopped -> stop,
    /// coded -> code, parties -> party). Not checked against the word list.
    static func stems(of word: String) -> [String] {
        var stems: [String] = []
        for rule in suffixRules where word.hasSuffix(rule.suffix) {
            let stem = String(word.dropLast(rule.suffix.count))
            guard stem.count >= 3 else { continue }
            stems.append(contentsOf: rule.restorations.map { stem + $0 })
            if let last = stem.last, stem.dropLast().last == last {
                stems.append(String(stem.dropLast()))
            }
        }
        return stems
    }
}

/// Second dictionary pass: corrects recognizer near-misses of dictionary
/// *targets* (Tematope -> Temitope, chat GPT -> ChatGPT). The live decode path
/// carries no vocabulary prompt, so this is what catches names and brands the
/// recognizer spelled by ear. Runs after the literal source/target rows and
/// is deliberately conservative: a wrong rewrite of a real word or of a
/// different person's name costs more than a missed correction. English only
/// (the word list is): callers skip it for any other dictation language.
///
/// A window is 1-3 consecutive words separated only by spaces. It is
/// rewritten to the target's exact spelling when either
///  - compound-exact: its letters-only skeleton equals the target's
///    (no speech threshold -> noSpeechThreshold, app cast -> appcast); or
///  - near-miss: same first letter and a small, vowel-only spelling drift
///    (Postgar SQL -> PostgreSQL, see `nearMiss` for the exact rules).
/// A window that is only a regular inflection of the target, or the other way
/// round (websockets / WebSocket, codebases / Codebase), is never touched: the
/// rewrite would change the grammar. A single word that is a valid English
/// word is never touched, a multi-word window of real words matches only as
/// an exact compound, and windows with stopwords are skipped unless the
/// target itself contains that word.
///
/// The exact-compound rule is deliberate even when the window is ordinary
/// prose: the target is the user's own chosen spelling, so "tail wind speed"
/// becomes "Tailwind speed" and "open AI" becomes "OpenAI" when those are in
/// the dictionary.
struct FuzzyDictionaryMatcher {
    static let minimumTargetLength = 6

    struct Replacement: Equatable {
        let original: String
        let target: String
    }

    private struct Target {
        let text: String
        let skeleton: [Character]
        let spelling: String
        let stems: Set<String>
        let consonants: [Character]
        let mergedVowels: [Character]
        let words: Set<String>
        /// "WebSocket", "GitHub": the user spelled it with a brand casing, so
        /// even a lowercase spelling that is a listed word is recased.
        let hasInternalCapital: Bool
    }

    private struct Token {
        let range: Range<String.Index>
        let word: String
        let skeleton: [Character]
        let isBlocked: Bool
        let isRealWord: Bool
    }

    private struct Candidate {
        let length: Int
        let range: Range<String.Index>
        let target: Target
        let isExact: Bool
        let distance: Int
    }

    private static let maximumWindowLength = 3
    private static let minimumWindowSkeleton = 5
    /// Targets shorter than this tolerate one vowel edit, longer ones two.
    private static let longTargetLength = 8

    private static let stopwords: Set<String> = [
        "a", "an", "the", "and", "or", "but", "nor", "so", "yet", "if", "then", "than", "that", "this",
        "these", "those", "of", "to", "in", "on", "at", "by", "for", "with", "from", "into", "onto",
        "about", "as", "is", "are", "was", "were", "be", "been", "being", "am", "do", "does", "did",
        "done", "has", "have", "had", "having", "will", "would", "can", "could", "shall", "should",
        "may", "might", "must", "i", "me", "my", "mine", "you", "your", "yours", "he", "him", "his",
        "she", "her", "hers", "it", "its", "we", "us", "our", "ours", "they", "them", "their", "theirs",
        "not", "no", "yes", "there", "here", "who", "whom", "what", "which", "when", "where", "why",
        "how", "all", "any", "some", "each", "every", "up", "out", "off", "over", "just", "very",
        "also", "too", "again", "more", "most", "much", "many", "only", "own", "same", "such", "both",
        "few", "other", "another", "because", "while", "after", "before", "during", "through",
        "between", "against", "under", "above", "below", "via", "per"
    ]

    private let targetsByFirstLetter: [Character: [Target]]
    private let exactTexts: Set<String>

    /// Precomputes every per-target cache, so the per-dictation pass only
    /// compares. Targets shorter than `minimumTargetLength` letters are
    /// ignored: short names collide with too many real words.
    init(targets targetTexts: [String]) {
        var seen = Set<String>()
        var byFirstLetter: [Character: [Target]] = [:]
        var exact = Set<String>()
        for text in targetTexts {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            let skeleton = Self.skeleton(of: trimmed)
            guard skeleton.count >= Self.minimumTargetLength, let first = skeleton.first,
                  seen.insert(trimmed.lowercased()).inserted else { continue }
            let spelling = String(skeleton)
            let merged = Self.mergingRepeatedVowels(skeleton)
            byFirstLetter[first, default: []].append(
                Target(
                    text: trimmed,
                    skeleton: skeleton,
                    spelling: spelling,
                    stems: Set(EnglishLexicon.stems(of: spelling)),
                    consonants: skeleton.filter { !Self.isVowel($0) },
                    mergedVowels: merged,
                    words: Set(Self.words(in: trimmed)),
                    hasInternalCapital: trimmed.dropFirst().contains(where: \.isUppercase)
                )
            )
            exact.insert(trimmed)
        }
        targetsByFirstLetter = byFirstLetter
        exactTexts = exact
    }

    var isEmpty: Bool { targetsByFirstLetter.isEmpty }

    func apply(to text: String) -> (text: String, replacements: [Replacement]) {
        guard !isEmpty, EnglishLexicon.isAvailable else { return (text, []) }
        let tokens = Self.tokenize(text)
        var edits: [(range: Range<String.Index>, replacement: Replacement)] = []

        var index = 0
        while index < tokens.count {
            if let match = bestCandidate(startingAt: index, tokens: tokens, in: text) {
                edits.append((match.range, Replacement(original: String(text[match.range]), target: match.target.text)))
                index += match.length
            } else {
                index += 1
            }
        }

        guard !edits.isEmpty else { return (text, []) }
        var result = ""
        var cursor = text.startIndex
        for edit in edits {
            result += text[cursor..<edit.range.lowerBound]
            result += edit.replacement.target
            cursor = edit.range.upperBound
        }
        result += text[cursor...]
        return (result, edits.map(\.replacement))
    }

    // MARK: - Matching

    private func bestCandidate(startingAt start: Int, tokens: [Token], in text: String) -> Candidate? {
        var best: Candidate?
        for length in 1...Self.maximumWindowLength where start + length <= tokens.count {
            let window = tokens[start..<(start + length)]
            guard window.allSatisfy({ !$0.isBlocked }) else { break }
            if length > 1, !Self.isSeparatedBySpaces(window, in: text) { break }

            let skeleton = window.flatMap(\.skeleton)
            guard skeleton.count >= Self.minimumWindowSkeleton, let first = skeleton.first,
                  let targets = targetsByFirstLetter[first] else { continue }
            let range = window.first!.range.lowerBound..<window.last!.range.upperBound
            let windowText = String(text[range])
            // Already spelled exactly as a target: nothing to correct.
            if exactTexts.contains(windowText) { continue }

            let words = window.map(\.word)
            let stopwordsInWindow = Set(words.filter(Self.stopwords.contains))
            let allReal = window.allSatisfy(\.isRealWord)
            let spelling = String(skeleton)
            let stems = Set(EnglishLexicon.stems(of: spelling))

            for target in targets {
                if stems.contains(target.spelling) || target.stems.contains(spelling) { continue }
                let candidate: Candidate?
                if skeleton == target.skeleton {
                    let mayRecase = !allReal || target.hasInternalCapital
                    let allowed = length > 1 || (mayRecase && !Self.hasOwnCasing(windowText, of: target))
                    candidate = allowed && stopwordsInWindow.isSubset(of: target.words)
                        ? Candidate(length: length, range: range, target: target, isExact: true, distance: 0)
                        : nil
                } else if !allReal, stopwordsInWindow.isEmpty {
                    candidate = nearMiss(length: length, range: range, skeleton: skeleton, target: target)
                } else {
                    candidate = nil
                }
                if let candidate, Self.isBetter(candidate, than: best) {
                    best = candidate
                }
            }
        }
        return best
    }

    /// True when the window differs from the target only by capitalization
    /// and is mixed case, like "ChatGPT" against a dictionary's "ChatGpt":
    /// that is the recognizer's own deliberate spelling, so it is left alone.
    /// Plain lowercase or first-letter-capitalized words are still recased
    /// (websocket -> WebSocket).
    private static func hasOwnCasing(_ window: String, of target: Target) -> Bool {
        guard window.lowercased() == target.text.lowercased() else { return false }
        return window.dropFirst() != window.dropFirst().lowercased()
    }

    /// A near-miss must look like the same word heard by ear, and never like
    /// a different real name (Michelle, Michaela, Claudia, Sophie and Olumide
    /// are not "Michael", "Claude", "Sophia" or "Olamide"). All of these hold:
    ///  - the same consonants in the same order (y, h and w count as
    ///    consonants), so only the vowels were guessed;
    ///  - the same last letter: a name's ending marks a different name
    ///    (Sophia/Sophie, Claude/Claudio);
    ///  - the same length once a repeated vowel counts as one (Meetumo is
    ///    Metumo), so no syllable was added or dropped (Michael/Michaela);
    ///  - a vowel edit budget of one for targets under eight letters and two
    ///    for longer ones. Swapping a vowel within {a, e, i} or within {o, u}
    ///    costs one (Tematope/Temitope); crossing between the two groups or
    ///    moving a vowel past a consonant costs two, which keeps Olumide away
    ///    from Olamide.
    /// Where this rule and a mis-heard name conflict, the rule wins.
    private func nearMiss(length: Int, range: Range<String.Index>, skeleton: [Character], target: Target) -> Candidate? {
        guard skeleton.last == target.skeleton.last,
              skeleton.filter({ !Self.isVowel($0) }) == target.consonants else { return nil }

        let merged = Self.mergingRepeatedVowels(skeleton)
        guard merged.count == target.mergedVowels.count else { return nil }

        let budget = target.skeleton.count < Self.longTargetLength ? 1 : 2
        let distance = Self.vowelEditDistance(merged, target.mergedVowels)
        return distance <= budget
            ? Candidate(length: length, range: range, target: target, isExact: false, distance: distance)
            : nil
    }

    /// Exact compounds beat near-misses, longer windows beat shorter ones
    /// (so "Mitomo app" is not split), then the smaller edit distance wins.
    private static func isBetter(_ candidate: Candidate, than best: Candidate?) -> Bool {
        guard let best else { return true }
        if candidate.isExact != best.isExact { return candidate.isExact }
        if candidate.length != best.length { return candidate.length > best.length }
        return candidate.distance < best.distance
    }

    // MARK: - Tokenizing

    /// Characters that make a word part of a URL, path, email, tag or
    /// identifier rather than prose.
    private static let codeAdjacentCharacters: Set<Character> = ["@", "/", "\\", "`", "#", "$", "_"]

    private static func tokenize(_ text: String) -> [Token] {
        var tokens: [Token] = []
        var index = text.startIndex
        while index < text.endIndex {
            guard isTokenCharacter(text[index]) else {
                index = text.index(after: index)
                continue
            }
            let start = index
            while index < text.endIndex, isTokenCharacter(text[index]) {
                index = text.index(after: index)
            }
            let range = start..<index
            let raw = String(text[range])
            let skeleton = skeleton(of: raw)
            let word = String(skeleton)
            tokens.append(
                Token(
                    range: range,
                    word: word,
                    skeleton: skeleton,
                    isBlocked: raw.contains("_") || isCodeAdjacent(range, in: text),
                    isRealWord: !raw.contains(where: \.isNumber) && EnglishLexicon.isRealWord(word)
                )
            )
        }
        return tokens
    }

    private static func isTokenCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "_"
    }

    private static func isCodeAdjacent(_ range: Range<String.Index>, in text: String) -> Bool {
        if range.lowerBound > text.startIndex {
            let before = text.index(before: range.lowerBound)
            if codeAdjacentCharacters.contains(text[before]) { return true }
            // "file.mitomo": a dot glued to a word on the left.
            if text[before] == ".", before > text.startIndex,
               text[text.index(before: before)].isLetter || text[text.index(before: before)].isNumber {
                return true
            }
        }
        if range.upperBound < text.endIndex {
            let after = text[range.upperBound]
            if codeAdjacentCharacters.contains(after) { return true }
            // "mitomo.com": a dot glued to a word on the right.
            let afterDot = text.index(after: range.upperBound)
            if after == ".", afterDot < text.endIndex, text[afterDot].isLetter || text[afterDot].isNumber {
                return true
            }
        }
        return false
    }

    private static func isSeparatedBySpaces(_ window: ArraySlice<Token>, in text: String) -> Bool {
        zip(window, window.dropFirst()).allSatisfy { previous, next in
            let gap = text[previous.range.upperBound..<next.range.lowerBound]
            return !gap.isEmpty && gap.allSatisfy { $0 == " " || $0 == "\t" }
        }
    }

    // MARK: - Normal forms

    /// Lowercase, diacritic-free letters and digits only.
    private static func skeleton(of text: String) -> [Character] {
        Array(
            text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
                .filter { $0.isLetter || $0.isNumber }
        )
    }

    private static func isVowel(_ character: Character) -> Bool {
        "aeiou".contains(character)
    }

    /// Vowels are told apart by ear within {a, e, i} and within {o, u}, far
    /// less across the two.
    private static func vowelGroup(_ character: Character) -> Int {
        "aei".contains(character) ? 0 : 1
    }

    /// "meetumo" -> "metumo": a doubled vowel is one long vowel sound.
    private static func mergingRepeatedVowels(_ skeleton: [Character]) -> [Character] {
        var merged: [Character] = []
        for character in skeleton where !(isVowel(character) && merged.last == character) {
            merged.append(character)
        }
        return merged
    }

    /// Splits "noSpeechThreshold", "PostgreSQL", "Meetumo-app" into lowercase
    /// words.
    private static func words(in text: String) -> [String] {
        var words: [String] = []
        var current = ""
        let characters = Array(text)
        for (offset, character) in characters.enumerated() {
            guard character.isLetter || character.isNumber else {
                if !current.isEmpty { words.append(current); current = "" }
                continue
            }
            if let previous = current.last {
                let startsUppercaseRun = character.isUppercase && previous.isLowercase
                let endsUppercaseRun = character.isUppercase && previous.isUppercase
                    && offset + 1 < characters.count && characters[offset + 1].isLowercase
                let switchesKind = character.isNumber != previous.isNumber
                if startsUppercaseRun || endsUppercaseRun || switchesKind {
                    words.append(current)
                    current = ""
                }
            }
            current.append(character)
        }
        if !current.isEmpty { words.append(current) }
        return words.map { String(skeleton(of: $0)) }
    }

    /// Levenshtein distance where swapping two vowels of the same group
    /// costs one and any other substitution costs two (a delete plus an
    /// insert), so a consonant can never be traded for a vowel cheaply.
    private static func vowelEditDistance(_ lhs: [Character], _ rhs: [Character]) -> Int {
        if lhs.isEmpty { return rhs.count }
        if rhs.isEmpty { return lhs.count }
        var previous = Array(0...rhs.count)
        var current = [Int](repeating: 0, count: rhs.count + 1)
        for (row, left) in lhs.enumerated() {
            current[0] = row + 1
            for (column, right) in rhs.enumerated() {
                let substitution: Int
                if left == right {
                    substitution = 0
                } else if isVowel(left), isVowel(right), vowelGroup(left) == vowelGroup(right) {
                    substitution = 1
                } else {
                    substitution = 2
                }
                current[column + 1] = min(
                    previous[column + 1] + 1,
                    current[column] + 1,
                    previous[column] + substitution
                )
            }
            swap(&previous, &current)
        }
        return previous[rhs.count]
    }
}
