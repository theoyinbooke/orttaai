// CoachCounting.swift
// CoachCore
//
// The counts, from what was actually said (the transcript before Polish):
// um and uh, the phrases that fill a pause, pace, sentence length and words
// said twice. Counted, never guessed. Ported unchanged from Orttakey's
// CoachStats so both apps agree.

import Foundation

public enum CoachCounting {
    /// Below this a dictation is too short to tell a pace from.
    public static let minimumWordsForPace = 10
    public static let minimumMsForPace = 5_000

    static let umUhWords: Set<String> = ["um", "uh"]

    /// um, uh and their stretched spellings (umm, uhh, erm, hmm).
    static let umUhPattern = try! NSRegularExpression(
        pattern: #"\b(?:u+m+|u+h+m*|e+r+m+|h+m+)\b"#,
        options: .caseInsensitive
    )

    /// Phrases that fill a pause. "like" counts only beside a comma, where
    /// it's a filler rather than a word doing a job.
    static let phrasePatterns: [(word: String, pattern: NSRegularExpression)] = [
        ("you know", try! NSRegularExpression(pattern: #"\byou know\b(?!\s+(?:what|how|that|why|when|where|who|if)\b)"#, options: .caseInsensitive)),
        ("I mean", try! NSRegularExpression(pattern: #"\bI mean\b"#, options: .caseInsensitive)),
        ("like", try! NSRegularExpression(pattern: #"(?<=,\s)like\b|\blike(?=,)"#, options: .caseInsensitive)),
        ("basically", try! NSRegularExpression(pattern: #"\bbasically\b"#, options: .caseInsensitive)),
        ("actually", try! NSRegularExpression(pattern: #"\bactually\b"#, options: .caseInsensitive)),
    ]

    /// The same word twice in a row ("I I think").
    static let repeatPattern = try! NSRegularExpression(
        pattern: #"\b(\w+)[\s,]+\1\b"#,
        options: .caseInsensitive
    )

    /// Each filler found and how often: "um", "uh", then the phrases.
    public static func fillerCounts(in text: String) -> [String: Int] {
        var counts: [String: Int] = [:]
        let range = NSRange(text.startIndex..., in: text)
        for match in umUhPattern.matches(in: text, range: range) {
            guard let found = Range(match.range, in: text) else { continue }
            let word = text[found].lowercased()
            counts[word.hasPrefix("u") && word.contains("h") ? "uh" : "um", default: 0] += 1
        }
        for (word, pattern) in phrasePatterns {
            let found = pattern.numberOfMatches(in: text, range: range)
            if found > 0 { counts[word, default: 0] += found }
        }
        return counts
    }

    public static func umUhCount(in text: String) -> Int {
        fillerCounts(in: text).filter { umUhWords.contains($0.key) }.reduce(0) { $0 + $1.value }
    }

    public static func phraseFillerCount(in text: String) -> Int {
        fillerCounts(in: text).filter { !umUhWords.contains($0.key) }.reduce(0) { $0 + $1.value }
    }

    public static func repeatCount(in text: String) -> Int {
        repeatPattern.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text))
    }

    public static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: \.isWhitespace).count
    }

    /// Words a minute, or nil when the dictation is too short to tell.
    public static func pace(_ text: String, recordingMs: Int) -> Int? {
        let words = wordCount(text)
        guard words >= minimumWordsForPace, recordingMs >= minimumMsForPace else { return nil }
        return Int((Double(words) / (Double(recordingMs) / 60_000)).rounded())
    }

    /// Sentences as written, each keeping its closing punctuation. Orttakey's
    /// Paragrapher.sentences: "3.5" or "e.g. this" don't end a sentence; a
    /// capital, digit, quote or bracket after a space does.
    public static func sentences(in text: String) -> [String] {
        var result: [String] = []
        var current = ""
        let characters = Array(text)
        for (index, character) in characters.enumerated() {
            current.append(character)
            guard ".?!".contains(character) else { continue }
            let next = index + 1 < characters.count ? characters[index + 1] : nil
            if next == nil || next == " " {
                let after = characters.dropFirst(index + 1).first { $0 != " " }
                if after == nil || after!.isUppercase || after!.isNumber || "\"“'(".contains(after!) {
                    result.append(current.trimmingCharacters(in: .whitespaces))
                    current = ""
                }
            }
        }
        let rest = current.trimmingCharacters(in: .whitespaces)
        if !rest.isEmpty { result.append(rest) }
        return result
    }

    /// Word counts of each sentence, empty ones left out.
    public static func sentenceLengths(in text: String) -> [Int] {
        sentences(in: text).map(wordCount).filter { $0 > 0 }
    }

    // MARK: Polish fixes (Mac only)

    /// How much of what was said Polish or the dictionary rewrote, 0 to 1:
    /// a word-level edit distance between what was heard and what was
    /// written, after taking out the fillers and repeats that the cleaner
    /// removes anyway, so those aren't counted twice.
    public static func polishChangeRatio(heard: String, written: String) -> Double {
        let said = comparableWords(withoutDisfluencies(heard))
        let kept = comparableWords(written)
        let longest = max(said.count, kept.count)
        guard longest > 0 else { return 0 }
        return Double(editDistance(said, kept)) / Double(longest)
    }

    static func withoutDisfluencies(_ text: String) -> String {
        var result = text
        let all = [umUhPattern] + phrasePatterns.map(\.pattern)
        for pattern in all {
            result = pattern.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: " ")
        }
        result = repeatPattern.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: "$1")
        return result
    }

    /// Lowercased words without punctuation, so "Hello," and "hello" match.
    static func comparableWords(_ text: String) -> [String] {
        text.lowercased()
            .split { !($0.isLetter || $0.isNumber || $0 == "'" || $0 == "’") }
            .prefix(2_000)
            .map(String.init)
    }

    static func editDistance(_ a: [String], _ b: [String]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var previous = Array(0...b.count)
        var current = Array(repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            current[0] = i
            for j in 1...b.count {
                let substitution = previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1)
                current[j] = min(previous[j] + 1, current[j - 1] + 1, substitution)
            }
            swap(&previous, &current)
        }
        return previous[b.count]
    }
}
