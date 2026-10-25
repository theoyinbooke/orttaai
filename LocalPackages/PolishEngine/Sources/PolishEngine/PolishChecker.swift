// PolishChecker.swift
// PolishEngine
//
// Decides whether a polished dictation can replace the rules text. Polish may
// punctuate, capitalise, paragraph, make lists, drop fillers and false starts,
// and write spoken numbers as digits. It may not add words the person didn't
// say, lose a number they said, or shrink or grow the text out of all
// proportion. Anything else falls back to the rules text, which is always
// safe to type in.
//
// Copied from Orttakey (Packages/OrttakeySpeech/Sources/OrttakeyPolish), with
// its tests, so S1-mini's answers are judged the same way on iPhone and Mac.

import Foundation

public nonisolated enum PolishChecker {
    public enum Verdict: Equatable, Sendable {
        case accepted(String)
        case rejected(Reason)

        public var text: String? {
            if case .accepted(let text) = self { return text }
            return nil
        }
    }

    public enum Reason: Equatable, Sendable, CustomStringConvertible {
        case empty
        case tooShort
        case tooLong
        case lostNumber(String)
        case lostBreaks
        case inventedWords([String])
        case changedYourWord(String)

        public var description: String {
            switch self {
            case .empty: "empty"
            case .tooShort: "too short"
            case .tooLong: "too long"
            case .lostNumber(let number): "lost the number \(number)"
            case .lostBreaks: "lost a list or line break"
            case .inventedWords(let words): "added \(words.joined(separator: ", "))"
            case .changedYourWord(let word): "changed \(word), one of your words"
            }
        }
    }

    /// Words polish may add although they weren't said: the halves of
    /// contractions and colloquialisms it writes out ("gonna" → "going to"),
    /// and what spoken numbers and symbols become.
    static let allowedAdditions: Set<String> = [
        "i", "am", "is", "are", "was", "were", "be", "been", "will", "would", "have", "has", "had",
        "not", "do", "does", "did", "going", "to", "want", "got", "let", "us", "you", "it", "that",
        "and", "or", "of", "a", "an", "the", "percent", "dollars", "dollar", "pounds", "euros",
        "naira", "am", "pm", "st", "nd", "rd", "th", "okay", "ok",
    ]

    /// How many unspoken words a polish may add before it's treated as making
    /// things up: a couple, or one in twelve for long dictations.
    static func addedWordAllowance(outputWords: Int) -> Int {
        max(2, outputWords / 12)
    }

    /// - Parameter protected: your words (Words tab) found in the input,
    ///   spelled your way; each must come through exactly as written.
    public static func check(_ candidate: String, against input: String, protecting protected: [String] = []) -> Verdict {
        let output = cleaned(candidate, input: input)
        guard !output.isEmpty else { return .rejected(.empty) }

        let inputLength = max(1, input.count)
        guard output.count >= Int(Double(inputLength) * 0.45) else { return .rejected(.tooShort) }
        guard output.count <= Int(Double(inputLength) * 1.6) + 24 else { return .rejected(.tooLong) }

        // Lists and breaks the person dictated ("number one", "new paragraph")
        // are already in the input; polish may add breaks, never remove them.
        if output.filter({ $0 == "\n" }).count < input.filter({ $0 == "\n" }).count {
            return .rejected(.lostBreaks)
        }

        // Every number said as digits must survive (formatting aside).
        var produced = numbers(in: output)
        for number in numbers(in: input) {
            guard let index = produced.firstIndex(of: number) else { return .rejected(.lostNumber(number)) }
            produced.remove(at: index)
        }

        for word in protected where !output.contains(word) {
            return .rejected(.changedYourWord(word))
        }

        let said = Set(words(in: input))
        // A name it brings in (capitalised mid-sentence, never said) is
        // something it made up or looked up: an answer, not a clean-up.
        let names = capitalisedWords(in: output).filter { !said.contains($0) && !allowedAdditions.contains($0) }
        if !names.isEmpty { return .rejected(.inventedWords(Array(names.prefix(5)))) }

        let outputWords = words(in: output)
        let added = outputWords.filter { !said.contains($0) && !allowedAdditions.contains($0) && !isNumberWord($0) }
        if added.count > addedWordAllowance(outputWords: outputWords.count) {
            return .rejected(.inventedWords(Array(added.prefix(5))))
        }
        return .accepted(output)
    }

    /// The model's answer without wrapping it sometimes adds: code fences,
    /// quotes around the whole text, typographic quotes the input didn't use.
    static func cleaned(_ candidate: String, input: String) -> String {
        var value = candidate
            .replacingOccurrences(of: "\r\n", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("```") {
            value = value.replacingOccurrences(of: "```", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if !input.contains("\u{2019}") && !input.contains("\u{2018}") {
            value = value.replacingOccurrences(of: "\u{2019}", with: "'").replacingOccurrences(of: "\u{2018}", with: "'")
        }
        if !input.contains("\u{201C}") && !input.contains("\u{201D}") {
            value = value.replacingOccurrences(of: "\u{201C}", with: "\"").replacingOccurrences(of: "\u{201D}", with: "\"")
        }
        if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\""), !input.hasPrefix("\"") {
            value = String(value.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return value
    }

    /// Lowercased words with apostrophes dropped ("I'm" → "im"), so a
    /// contraction matches however it was transcribed. Digits are left to
    /// `numbers(in:)`.
    static func words(in text: String) -> [String] {
        text.lowercased()
            .replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: "\u{2019}", with: "")
            .split { !$0.isLetter }
            .map(String.init)
    }

    /// Words written with a capital away from the start of a sentence or line,
    /// lowercased the way `words(in:)` writes them.
    static func capitalisedWords(in text: String) -> [String] {
        var result: [String] = []
        var sentenceStart = true
        for token in text.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }) {
            let core = token.drop { !$0.isLetter && !$0.isNumber }
            let isListMarker = core.isEmpty || core.allSatisfy(\.isNumber)
            if let first = core.first, first.isUppercase, !sentenceStart {
                result += words(in: String(core))
            }
            if isListMarker {
                sentenceStart = true
            } else {
                sentenceStart = token.last.map { ".?!:".contains($0) } ?? false
            }
        }
        return result
    }

    /// Each run of digits, with thousands separators removed: "4,200" and
    /// "4200" are the same number; "3.5" keeps its point.
    static func numbers(in text: String) -> [String] {
        var result: [String] = []
        var current = ""
        func flush() {
            var number = current
            while let last = number.last, last == "." || last == "," { number.removeLast() }
            if !number.isEmpty { result.append(number.replacingOccurrences(of: ",", with: "")) }
            current = ""
        }
        for character in text {
            if character.isNumber {
                current.append(character)
            } else if (character == "," || character == "."), !current.isEmpty {
                current.append(character)
            } else {
                flush()
            }
        }
        flush()
        return result
    }

    /// Spoken numbers polish turns into digits ("forty two" → "42"), so when
    /// they appear in the output they were said, not invented.
    static func isNumberWord(_ word: String) -> Bool {
        numberWords.contains(word)
    }

    private static let numberWords: Set<String> = [
        "zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten",
        "eleven", "twelve", "thirteen", "fourteen", "fifteen", "sixteen", "seventeen", "eighteen",
        "nineteen", "twenty", "thirty", "forty", "fifty", "sixty", "seventy", "eighty", "ninety",
        "hundred", "thousand", "million", "billion", "first", "second", "third", "fourth", "fifth",
        "half", "quarter",
    ]
}
