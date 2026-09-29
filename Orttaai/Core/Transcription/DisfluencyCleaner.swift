// DisfluencyCleaner.swift
// Orttaai

import Foundation

/// Deterministic cleanup of what Whisper transcribes verbatim: filler words,
/// stuttered function words and a lowercase "i". English only, and
/// deliberately narrow: every rule has a closed list or a guard so real
/// repetition ("no no no", "had had") and code ("for i in range") survive.
enum DisfluencyCleaner {
    /// Not preceded or followed by anything that makes it part of another
    /// word ("um-brella", "uh-oh", "don't").
    private static let boundaryBefore = #"(?<![\p{L}\p{N}_'’\-])"#
    private static let boundaryAfter = #"(?![\p{L}\p{N}_'’]|-[\p{L}\p{N}])"#

    private static let fillerRegex = try? NSRegularExpression(
        pattern: boundaryBefore + #"(?:um|uhm|umm|erm|uh(?![ \t]+(?:huh|oh)\b))"# + boundaryAfter,
        options: [.caseInsensitive]
    )

    /// Words that are never legitimately doubled in speech. "that", "had",
    /// "is", "very", "no" and "you" are excluded on purpose.
    private static let repeatedWordRegex = try? NSRegularExpression(
        pattern: boundaryBefore + #"(the|to|and|a|of|in|for)(?:[ \t]*,)?[ \t]+\1"# + boundaryAfter,
        options: [.caseInsensitive]
    )

    private static let contractionRegex = try? NSRegularExpression(
        pattern: #"(?<![\p{L}\p{N}_'’.\-/@#$])i(?=['’](?:m|ll|ve|d)(?![\p{L}\p{N}_]))"#
    )

    private static let bareIRegex = try? NSRegularExpression(
        pattern: #"(?<![\p{L}\p{N}_'’.\-/@#$])i(?![\p{L}\p{N}_'’])"#
    )

    /// "section i", "chapter i" and friends: a roman numeral, not a pronoun.
    private static let numeralIntroducers: Set<String> = [
        "section", "chapter", "part", "item", "appendix", "article", "figure", "table",
        "volume", "page", "clause", "book", "act", "scene", "level", "tier"
    ]

    static func clean(_ text: String) -> (text: String, changes: [String]) {
        let fillerResult = removeFillers(from: text)
        // A lone "Um." would otherwise paste as nothing at all.
        guard !fillerResult.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return (text, [])
        }

        var value = fillerResult.text
        var changes: [String] = []
        if fillerResult.count > 0 {
            changes.append("Disfluency: removed \(fillerResult.count) filler\(fillerResult.count == 1 ? "" : "s")")
        }

        let repeated = collapseRepeatedWords(in: value)
        value = repeated.text
        if repeated.count > 0 {
            changes.append("Disfluency: collapsed \(repeated.count) repeated word\(repeated.count == 1 ? "" : "s")")
        }

        let capitalized = capitalizePronounI(in: value)
        value = capitalized.text
        if capitalized.count > 0 {
            changes.append("Disfluency: capitalized \(capitalized.count) 'i'")
        }

        return (value, changes)
    }

    // MARK: - Fillers

    private static func removeFillers(from text: String) -> (text: String, count: Int) {
        var value = text
        var count = 0
        // Back to front so a run like "um um" resolves one filler at a time.
        while let range = lastFillerRange(in: value) {
            value = removing(fillerAt: range, from: value)
            count += 1
        }
        return (value, count)
    }

    private static func lastFillerRange(in text: String) -> Range<String.Index>? {
        guard let fillerRegex else { return nil }
        let matches = fillerRegex.matches(in: text, range: NSRange(text.startIndex..., in: text))
        for match in matches.reversed() {
            guard let range = Range(match.range, in: text) else { continue }
            let filler = text[range]
            // "UM" is an initialism, not a hesitation.
            if filler.uppercased() == filler { continue }
            return range
        }
        return nil
    }

    /// Drops the filler with the commas Whisper wraps it in, then rejoins the
    /// neighbours. Recapitalizes the next word when the filler opened a
    /// sentence.
    private static func removing(fillerAt range: Range<String.Index>, from text: String) -> String {
        var left = String(text[..<range.lowerBound])
        var right = String(text[range.upperBound...])

        while let last = left.last, last == " " || last == "\t" { left.removeLast() }
        if left.last == "," { left.removeLast() }
        while let last = left.last, last == " " || last == "\t" { left.removeLast() }

        while let first = right.first, first == " " || first == "\t" { right.removeFirst() }
        if right.first == "," { right.removeFirst() }
        while let first = right.first, first == " " || first == "\t" { right.removeFirst() }

        let opensSentence = left.isEmpty || ".!?\n".contains(left.last!)
        // "Um." on its own is a whole sentence of hesitation.
        if opensSentence {
            while let first = right.first, ".!?…".contains(first) { right.removeFirst() }
            while let first = right.first, first == " " || first == "\t" { right.removeFirst() }
        }

        let fillerIsCapitalized = text[range].first?.isUppercase == true
        if opensSentence, fillerIsCapitalized || !left.isEmpty {
            right = capitalizedFirstLetter(right)
        }

        let needsSpace = !left.isEmpty && !right.isEmpty
            && left.last != "\n" && !",.;:!?)".contains(right.first!)
        return left + (needsSpace ? " " : "") + right
    }

    /// Leaves mixed-case tokens such as "iPhone" alone.
    private static func capitalizedFirstLetter(_ text: String) -> String {
        guard let first = text.first, first.isLowercase else { return text }
        let second = text.dropFirst().first
        if let second, second.isUppercase { return text }
        return first.uppercased() + text.dropFirst()
    }

    // MARK: - Repeated function words

    private static func collapseRepeatedWords(in text: String) -> (text: String, count: Int) {
        guard let repeatedWordRegex else { return (text, 0) }
        var value = text
        var count = 0
        // A triple ("the the the") needs a second pass.
        while true {
            let range = NSRange(value.startIndex..., in: value)
            let matches = repeatedWordRegex.numberOfMatches(in: value, range: range)
            guard matches > 0 else { break }
            count += matches
            value = repeatedWordRegex.stringByReplacingMatches(in: value, range: range, withTemplate: "$1")
        }
        return (value, count)
    }

    // MARK: - Pronoun I

    private static func capitalizePronounI(in text: String) -> (text: String, count: Int) {
        var ranges: [Range<String.Index>] = []
        let fullRange = NSRange(text.startIndex..., in: text)

        if let contractionRegex {
            ranges += contractionRegex.matches(in: text, range: fullRange).compactMap { Range($0.range, in: text) }
        }
        if let bareIRegex {
            ranges += bareIRegex.matches(in: text, range: fullRange)
                .compactMap { Range($0.range, in: text) }
                .filter { isPronoun($0, in: text) }
        }
        guard !ranges.isEmpty else { return (text, 0) }

        var value = text
        for range in ranges.sorted(by: { $0.lowerBound > $1.lowerBound }) {
            value.replaceSubrange(range, with: "I")
        }
        return (value, ranges.count)
    }

    /// Rejects a bare "i" that is a list marker, roman numeral, loop counter
    /// or a member of a run of one-letter names ("i, j, k").
    private static func isPronoun(_ range: Range<String.Index>, in text: String) -> Bool {
        let before = text[..<range.lowerBound]
        let after = text[range.upperBound...]

        if after.first == "." { return false }
        let afterSpaces = after.drop(while: { $0 == " " || $0 == "\t" })
        if let next = afterSpaces.first {
            if "=<>+*/%&|^~[](){}:-".contains(next) { return false }
            if next == "!", afterSpaces.dropFirst().first == "=" { return false }
        }

        let previousWord = word(endingAt: before)
        let nextWord = word(startingAt: afterSpaces.drop(while: { $0 == "," || $0 == " " || $0 == "\t" }))
        if numeralIntroducers.contains(previousWord.lowercased()) { return false }
        if previousWord.lowercased() == "for", nextWord.lowercased() == "in" { return false }
        return ![previousWord, nextWord].contains(where: isSingleLetterNameOrNumeral)
    }

    private static func isSingleLetterNameOrNumeral(_ word: String) -> Bool {
        let lowered = word.lowercased()
        if lowered.count == 1, lowered != "a", lowered != "i", lowered.first!.isLetter { return true }
        return lowered.count > 1 && lowered.allSatisfy { "ivx".contains($0) }
    }

    private static func word(endingAt text: Substring) -> String {
        let trimmed = text.reversed().drop(while: { $0 == " " || $0 == "\t" || $0 == "," })
        return String(trimmed.prefix(while: { $0.isLetter || $0.isNumber }).reversed())
    }

    private static func word(startingAt text: Substring) -> String {
        String(text.prefix(while: { $0.isLetter || $0.isNumber }))
    }
}
