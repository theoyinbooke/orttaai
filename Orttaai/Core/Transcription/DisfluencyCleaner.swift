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

    /// A filler is a standalone spoken word: delimited on the left by
    /// whitespace or the start of the text, and on the right by whitespace,
    /// the end, or sentence punctuation that is itself followed by
    /// whitespace or the end. That keeps "um@x.com", "um.txt", "file.um",
    /// "um: hello", "\"um\"" and "(um)" intact.
    private static let fillerRegex = try? NSRegularExpression(
        pattern: #"(?<!\S)(?:um|uhm|umm|erm|uh(?![ \t]+(?:huh|oh)\b))(?=[,.?!;…]*(?:\s|$))"#,
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

    /// One pass over the fillers, left to right. Each removal drops only the
    /// filler, the commas Whisper wraps it in and the spaces adjoining it;
    /// newlines, indentation and everything else in between is copied as is.
    private static func removeFillers(from text: String) -> (text: String, count: Int) {
        guard let fillerRegex else { return (text, 0) }
        var output = ""
        var cursor = text.startIndex
        var count = 0
        // Set when a filler opened a sentence: the next word kept is recapitalized.
        var capitalizeNext = false

        for match in fillerRegex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let range = Range(match.range, in: text) else { continue }
            let filler = text[range]
            // "UM" is an initialism, not a hesitation.
            if filler.uppercased() == filler { continue }

            let kept = text[cursor..<range.lowerBound]
            if capitalizeNext, !kept.isEmpty {
                output += capitalizedFirstLetter(String(kept))
                capitalizeNext = false
            } else {
                output += kept
            }

            let leftGap = removeTrailingBlanks(from: &output)
            if output.last == "," {
                output.removeLast()
                removeTrailingBlanks(from: &output)
            }
            let hasTextBefore = !output.isEmpty
            let atLineStart = !hasTextBefore || output.last?.isNewline == true
            let endsSentence = atLineStart || ".!?…".contains(output.last!)
            let endsWithEllipsis = output.hasSuffix("…") || output.hasSuffix("...")

            cursor = skipBlanks(in: text, from: range.upperBound)
            let rightGapEnd = cursor
            if cursor < text.endIndex, text[cursor] == "," {
                cursor = skipBlanks(in: text, from: text.index(after: cursor))
            }
            // "Um." on its own is a whole sentence of hesitation; so is the
            // "..." trailing a filler that follows an ellipsis.
            if endsSentence {
                while cursor < text.endIndex, ".!?…".contains(text[cursor]) { cursor = text.index(after: cursor) }
                cursor = skipBlanks(in: text, from: cursor)
            }

            if atLineStart {
                output += leftGap
            } else if cursor < text.endIndex, !text[cursor].isNewline, !",.;:!?)".contains(text[cursor]) {
                output += leftGap.isEmpty ? String(text[range.upperBound..<rightGapEnd]) : leftGap
            }

            let fillerIsCapitalized = filler.first?.isUppercase == true
            // Only . ? ! and a line start open a sentence, never an ellipsis.
            if endsSentence, !endsWithEllipsis, fillerIsCapitalized || hasTextBefore {
                capitalizeNext = true
            }
            count += 1
        }

        let tail = String(text[cursor...])
        output += capitalizeNext ? capitalizedFirstLetter(tail) : tail
        return (output, count)
    }

    /// Removes and returns the spaces and tabs at the end of `text`.
    @discardableResult
    private static func removeTrailingBlanks(from text: inout String) -> String {
        var removed = ""
        while let last = text.last, last == " " || last == "\t" {
            removed.insert(text.removeLast(), at: removed.startIndex)
        }
        return removed
    }

    private static func skipBlanks(in text: String, from index: String.Index) -> String.Index {
        var index = index
        while index < text.endIndex, text[index] == " " || text[index] == "\t" { index = text.index(after: index) }
        return index
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
