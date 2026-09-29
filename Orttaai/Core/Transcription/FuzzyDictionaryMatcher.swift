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
        for rule in suffixRules where word.hasSuffix(rule.suffix) {
            let stem = String(word.dropLast(rule.suffix.count))
            guard stem.count >= 3 else { continue }
            for restoration in rule.restorations {
                if words.contains(stem + restoration) { return true }
            }
            // stopped -> stopp -> stop
            if let last = stem.last, stem.dropLast().last == last, words.contains(String(stem.dropLast())) {
                return true
            }
        }
        return false
    }
}

/// Second dictionary pass: corrects recognizer near-misses of dictionary
/// *targets* (Tematope -> Temitope, chat GPT -> ChatGPT). The live decode path
/// carries no vocabulary prompt, so this is what catches names and brands the
/// recognizer spelled by ear. Runs after the literal source/target rows and
/// is deliberately conservative: a wrong rewrite of a real word costs more
/// than a missed correction.
///
/// A window is 1-3 consecutive words separated only by spaces. It is
/// rewritten to the target's exact spelling when either
///  - compound-exact: its letters-only skeleton equals the target's
///    (no speech threshold -> noSpeechThreshold, app cast -> appcast); or
///  - near-miss: same first letter, at most two characters of length drift
///    (one for multi-word windows), and the same consonant skeleton or a
///    small edit distance (Postgar SQL -> PostgreSQL). Targets that are not
///    themselves English words (names, brands) need both the consonant
///    skeleton and a high similarity, so a different real person (Temitayo
///    for Temitope) is left alone.
/// A single word that is a valid English word is never touched, a multi-word
/// window of real words matches only as an exact compound, and windows with
/// stopwords are skipped unless the target itself contains that word.
struct FuzzyDictionaryMatcher {
    static let minimumTargetLength = 6

    struct Replacement: Equatable {
        let original: String
        let target: String
    }

    private struct Target {
        let text: String
        let skeleton: [Character]
        let consonantKey: [Character]
        let vowelFolded: [Character]
        let words: Set<String>
        let isNameLike: Bool
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
    private static let nameSimilarityLimit = 0.3
    private static let editSimilarityLimit = 0.2

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
            let words = Self.words(in: trimmed)
            byFirstLetter[first, default: []].append(
                Target(
                    text: trimmed,
                    skeleton: skeleton,
                    consonantKey: Self.consonantKey(of: skeleton),
                    vowelFolded: Self.vowelFolded(skeleton),
                    words: Set(words),
                    isNameLike: !words.allSatisfy(EnglishLexicon.isRealWord)
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

            for target in targets {
                let candidate: Candidate?
                if skeleton == target.skeleton {
                    let allowed = length > 1 || (!allReal && !Self.hasOwnCasing(windowText, of: target))
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

    private func nearMiss(length: Int, range: Range<String.Index>, skeleton: [Character], target: Target) -> Candidate? {
        let maximumDrift = length == 1 ? 2 : 1
        guard abs(skeleton.count - target.skeleton.count) <= maximumDrift else { return nil }

        let key = Self.consonantKey(of: skeleton)
        let sameConsonants = key.count >= 2 && key == target.consonantKey
        let distance = Self.editDistance(skeleton, target.skeleton)
        let largest = Double(max(skeleton.count, target.skeleton.count))

        let matches: Bool
        if target.isNameLike {
            let foldedDistance = Self.editDistance(Self.vowelFolded(skeleton), target.vowelFolded)
            matches = sameConsonants && Double(foldedDistance) / largest <= Self.nameSimilarityLimit
        } else {
            matches = sameConsonants || Double(distance) / largest <= Self.editSimilarityLimit
        }
        return matches
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

    /// Consonants that survive when the recognizer guesses the vowels by ear:
    /// vowels, y, h and w dropped, c/q folded to k, z to s, repeats collapsed.
    private static func consonantKey(of skeleton: [Character]) -> [Character] {
        var key: [Character] = []
        for character in skeleton where !"aeiouyhw".contains(character) {
            let folded: Character = "cq".contains(character) ? "k" : (character == "z" ? "s" : character)
            if key.last != folded {
                key.append(folded)
            }
        }
        return key
    }

    private static func vowelFolded(_ skeleton: [Character]) -> [Character] {
        skeleton.map { "aeiouy".contains($0) ? "a" : $0 }
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

    private static func editDistance(_ lhs: [Character], _ rhs: [Character]) -> Int {
        if lhs.isEmpty { return rhs.count }
        if rhs.isEmpty { return lhs.count }
        var previous = Array(0...rhs.count)
        var current = [Int](repeating: 0, count: rhs.count + 1)
        for (row, left) in lhs.enumerated() {
            current[0] = row + 1
            for (column, right) in rhs.enumerated() {
                current[column + 1] = min(
                    previous[column + 1] + 1,
                    current[column] + 1,
                    previous[column] + (left == right ? 0 : 1)
                )
            }
            swap(&previous, &current)
        }
        return previous[rhs.count]
    }
}
