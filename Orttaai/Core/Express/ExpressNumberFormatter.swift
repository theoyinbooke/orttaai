// ExpressNumberFormatter.swift
// Orttaai

import Foundation

/// Writes the numbers Fluid Speech Mini spells out the way Whisper writes
/// them: "five five five zero one four three" -> "555-0143", "two thousand
/// four hundred and fifty dollars" -> "$2,450", "6.45 a.m." -> "6:45 a.m.".
/// Runs on Express output only: Whisper already writes digits, so these rules
/// could only add risk there. Small counts stay words ("twelve of the fifteen
/// pairs") because that is how people write them too.
nonisolated enum ExpressNumberFormatter {
    private static let units: [String: Int] = [
        "zero": 0, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6,
        "seven": 7, "eight": 8, "nine": 9, "ten": 10, "eleven": 11, "twelve": 12,
        "thirteen": 13, "fourteen": 14, "fifteen": 15, "sixteen": 16,
        "seventeen": 17, "eighteen": 18, "nineteen": 19
    ]

    private static let tens: [String: Int] = [
        "twenty": 20, "thirty": 30, "forty": 40, "fifty": 50, "sixty": 60,
        "seventy": 70, "eighty": 80, "ninety": 90
    ]

    private static let scales: [String: Int] = [
        "hundred": 100, "thousand": 1_000, "million": 1_000_000, "billion": 1_000_000_000
    ]

    private static let ordinals: [String: Int] = [
        "first": 1, "second": 2, "third": 3, "fourth": 4, "fifth": 5, "sixth": 6,
        "seventh": 7, "eighth": 8, "ninth": 9, "tenth": 10, "eleventh": 11,
        "twelfth": 12, "thirteenth": 13, "fourteenth": 14, "fifteenth": 15,
        "sixteenth": 16, "seventeenth": 17, "eighteenth": 18, "nineteenth": 19,
        "twentieth": 20, "thirtieth": 30
    ]

    private static let months: Set<String> = [
        "january", "february", "march", "april", "may", "june", "july",
        "august", "september", "october", "november", "december"
    ]

    /// "6.45 a.m." and "10.30pm": a dotted time is only rewritten when a
    /// meridiem follows, so decimals ("4.25%", "26.2 miles") are left alone.
    private static let dottedTimeRegex = try? NSRegularExpression(
        pattern: #"(?<![\p{N}.])(1[0-2]|0?[1-9])\.([0-5][0-9])(?=[ \t]*(?:[ap]\.?[ \t]?m\b\.?))"#,
        options: [.caseInsensitive]
    )

    /// "at 8.05 local time", "until 6.30 tonight": without a meridiem a dotted
    /// time needs a time preposition before it and a time word after it.
    private static let prepositionTimeRegex = try? NSRegularExpression(
        pattern: #"(?<=\b(?:at|around|until|till|before|after)[ \t])(1[0-2]|0?[1-9])\.([0-5][0-9])(?=[ \t]+(?:local|sharp|tonight|tomorrow|today|this|on|o['’]clock|in[ \t]+the[ \t]+(?:morning|afternoon|evening))\b)"#,
        options: [.caseInsensitive]
    )

    private static let wordRegex = try? NSRegularExpression(pattern: #"[\p{L}]+(?:['’][\p{L}]+)?"#)

    static func format(_ text: String) -> String {
        var value = text
        for regex in [dottedTimeRegex, prepositionTimeRegex].compactMap({ $0 }) {
            let range = NSRange(value.startIndex..<value.endIndex, in: value)
            value = regex.stringByReplacingMatches(in: value, options: [], range: range, withTemplate: "$1:$2")
        }
        return formatNumberWords(in: value)
    }

    // MARK: - Number words

    private struct Word {
        let text: String
        let lowercased: String
        let range: Range<String.Index>
    }

    private static func formatNumberWords(in text: String) -> String {
        let words = tokenize(text)
        guard words.contains(where: { isNumberWord($0.lowercased) }) else { return text }

        var replacements: [(Range<String.Index>, String)] = []
        var index = 0
        while index < words.count {
            if let match = match(at: index, in: words, text: text) {
                replacements.append((match.range, match.replacement))
                index = match.nextIndex
            } else {
                index += 1
            }
        }

        var result = text
        for (range, replacement) in replacements.reversed() {
            result.replaceSubrange(range, with: replacement)
        }
        return result
    }

    private struct Match {
        let range: Range<String.Index>
        let replacement: String
        let nextIndex: Int
    }

    private static func match(at index: Int, in words: [Word], text: String) -> Match? {
        guard isNumberWord(words[index].lowercased) else { return nil }

        if let digits = digitSequence(at: index, in: words, text: text) {
            return digits
        }
        if let time = spokenTime(at: index, in: words, text: text) {
            return time
        }
        if let ordinal = dateOrdinal(at: index, in: words, text: text) {
            return ordinal
        }
        guard let cardinal = cardinal(at: index, in: words, text: text) else { return nil }
        return contextualCardinal(cardinal, in: words, text: text)
    }

    /// Four or more single digits read one by one: a phone number, PIN or
    /// code. Seven digits read as a local phone number (555-0143), ten as a
    /// full one (415-555-0143).
    private static func digitSequence(at index: Int, in words: [Word], text: String) -> Match? {
        var digits = ""
        var end = index
        while end < words.count,
              let digit = singleDigit(words[end].lowercased, isFirst: end == index),
              end == index || isAdjacent(words[end - 1], words[end], in: text, allowing: " -") {
            digits += String(digit)
            end += 1
        }
        guard digits.count >= 4 else { return nil }

        let formatted: String
        switch digits.count {
        case 7: formatted = "\(digits.prefix(3))-\(digits.suffix(4))"
        case 10: formatted = "\(digits.prefix(3))-\(digits.dropFirst(3).prefix(3))-\(digits.suffix(4))"
        default: formatted = digits
        }
        return Match(range: words[index].range.lowerBound..<words[end - 1].range.upperBound, replacement: formatted, nextIndex: end)
    }

    /// "three pm" -> "3 pm", "ten thirty a.m." -> "10:30 a.m.", "six oh five
    /// pm" -> "6:05 pm". Needs a meridiem, so "at ten thirty" stays words.
    private static func spokenTime(at index: Int, in words: [Word], text: String) -> Match? {
        guard let hour = units[words[index].lowercased], (1...12).contains(hour) else { return nil }
        var next = index + 1
        var minutes: Int?

        if next < words.count, isAdjacent(words[next - 1], words[next], in: text, allowing: " ") {
            let word = words[next].lowercased
            if word == "oh" || word == "o", next + 1 < words.count,
               let unit = units[words[next + 1].lowercased], (1...9).contains(unit),
               isAdjacent(words[next], words[next + 1], in: text, allowing: " ") {
                minutes = unit
                next += 2
            } else if let parsed = minuteValue(at: next, in: words, text: text) {
                minutes = parsed.value
                next = parsed.nextIndex
            }
        }

        guard isFollowedByMeridiem(words[next - 1], in: text) else { return nil }
        let hourText = minutes.map { "\(hour):" + String(format: "%02d", $0) } ?? "\(hour)"
        return Match(range: words[index].range.lowerBound..<words[next - 1].range.upperBound, replacement: hourText, nextIndex: next)
    }

    private static func minuteValue(at index: Int, in words: [Word], text: String) -> (value: Int, nextIndex: Int)? {
        let word = words[index].lowercased
        if let unit = units[word], (10...19).contains(unit) {
            return (unit, index + 1)
        }
        guard let ten = tens[word], ten <= 50 else { return nil }
        if index + 1 < words.count, let unit = units[words[index + 1].lowercased], (1...9).contains(unit),
           isAdjacent(words[index], words[index + 1], in: text, allowing: " -") {
            return (ten + unit, index + 2)
        }
        return (ten, index + 1)
    }

    /// "a.m.", "am", "p.m", "PM" directly after a word.
    private static func isFollowedByMeridiem(_ word: Word, in text: String) -> Bool {
        text[word.range.upperBound...].range(
            of: #"^[ \t]+[ap]\.?[ \t]?m\b"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil
    }

    /// "March fifteenth" -> "March 15th", "the seventeenth of April" -> "the
    /// 17th of April". Ordinals elsewhere ("the first few sessions") stay.
    private static func dateOrdinal(at index: Int, in words: [Word], text: String) -> Match? {
        guard let parsed = ordinalValue(at: index, in: words, text: text), (1...31).contains(parsed.value) else { return nil }
        let afterMonth = index > 0 && isMonth(words[index - 1])
            && isAdjacent(words[index - 1], words[index], in: text, allowing: " ")
        let beforeMonth = parsed.nextIndex + 1 < words.count
            && words[parsed.nextIndex].lowercased == "of"
            && isMonth(words[parsed.nextIndex + 1])
        guard afterMonth || beforeMonth else { return nil }
        return Match(
            range: words[index].range.lowerBound..<words[parsed.nextIndex - 1].range.upperBound,
            replacement: "\(parsed.value)\(ordinalSuffix(parsed.value))",
            nextIndex: parsed.nextIndex
        )
    }

    /// Capitalized only: "you may first check" is not a date.
    private static func isMonth(_ word: Word) -> Bool {
        months.contains(word.lowercased) && word.text.first?.isUppercase == true
    }

    private static func ordinalValue(at index: Int, in words: [Word], text: String) -> (value: Int, nextIndex: Int)? {
        let word = words[index].lowercased
        if let value = ordinals[word] {
            return (value, index + 1)
        }
        guard let ten = tens[word], index + 1 < words.count,
              let unit = ordinals[words[index + 1].lowercased], (1...9).contains(unit),
              isAdjacent(words[index], words[index + 1], in: text, allowing: " -") else { return nil }
        return (ten + unit, index + 2)
    }

    private static func ordinalSuffix(_ value: Int) -> String {
        if (11...13).contains(value % 100) { return "th" }
        switch value % 10 {
        case 1: return "st"
        case 2: return "nd"
        case 3: return "rd"
        default: return "th"
        }
    }

    private struct Cardinal {
        let value: Int
        let hasScale: Bool
        let startIndex: Int
        let nextIndex: Int
    }

    /// Parses "two thousand four hundred and fifty" or "forty-five". Stops
    /// where a second number would begin ("one two" is two numbers).
    private static func cardinal(at index: Int, in words: [Word], text: String) -> Cardinal? {
        var total = 0
        var current = 0
        var hasScale = false
        var lastKind: Character = " "
        var end = index

        while end < words.count {
            if end > index, !isAdjacent(words[end - 1], words[end], in: text, allowing: " -") { break }
            let word = words[end].lowercased
            if let unit = units[word] {
                if lastKind == "u" || (lastKind == "t" && unit >= 10) || (unit == 0 && end > index) { break }
                current += unit
                lastKind = "u"
            } else if let ten = tens[word] {
                if lastKind == "u" || lastKind == "t" { break }
                current += ten
                lastKind = "t"
            } else if let scale = scales[word], end > index, lastKind != "s" || scale > 100 {
                current = max(current, 1) * scale
                if scale >= 1_000 {
                    total += current
                    current = 0
                }
                hasScale = true
                lastKind = "s"
            } else if word == "and", lastKind == "s", end + 1 < words.count,
                      units[words[end + 1].lowercased] != nil || tens[words[end + 1].lowercased] != nil {
                end += 1
                continue
            } else {
                break
            }
            end += 1
        }

        guard end > index else { return nil }
        return Cardinal(value: total + current, hasScale: hasScale, startIndex: index, nextIndex: end)
    }

    /// Rewrites a parsed number only where Whisper would write digits: money,
    /// percentages and anything with a scale word ("two hundred and fifty").
    private static func contextualCardinal(_ cardinal: Cardinal, in words: [Word], text: String) -> Match? {
        let start = words[cardinal.startIndex].range.lowerBound
        let last = words[cardinal.nextIndex - 1]
        let next = cardinal.nextIndex < words.count ? words[cardinal.nextIndex] : nil
        let nextIsAdjacent = next.map { isAdjacent(last, $0, in: text, allowing: " ") } ?? false

        if let next, nextIsAdjacent, next.lowercased == "dollars" || next.lowercased == "dollar" {
            return Match(range: start..<next.range.upperBound, replacement: "$" + grouped(cardinal.value), nextIndex: cardinal.nextIndex + 1)
        }
        if let next, nextIsAdjacent, next.lowercased == "percent" {
            return Match(range: start..<next.range.upperBound, replacement: "\(cardinal.value)%", nextIndex: cardinal.nextIndex + 1)
        }
        guard cardinal.hasScale else { return nil }
        return Match(range: start..<last.range.upperBound, replacement: grouped(cardinal.value), nextIndex: cardinal.nextIndex)
    }

    // MARK: - Helpers

    private static func tokenize(_ text: String) -> [Word] {
        guard let wordRegex else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return wordRegex.matches(in: text, options: [], range: range).compactMap { match in
            guard let range = Range(match.range, in: text) else { return nil }
            let word = String(text[range])
            return Word(text: word, lowercased: word.lowercased(), range: range)
        }
    }

    private static func isNumberWord(_ word: String) -> Bool {
        units[word] != nil || tens[word] != nil || ordinals[word] != nil
    }

    private static func singleDigit(_ word: String, isFirst: Bool) -> Int? {
        if word == "oh", !isFirst { return 0 }
        guard let unit = units[word], unit <= 9 else { return nil }
        return unit
    }

    /// True when only characters from `separators` sit between two words.
    private static func isAdjacent(_ first: Word, _ second: Word, in text: String, allowing separators: String) -> Bool {
        let gap = text[first.range.upperBound..<second.range.lowerBound]
        return !gap.isEmpty && gap.allSatisfy { separators.contains($0) }
    }

    private static func grouped(_ value: Int) -> String {
        let digits = String(value)
        guard digits.count > 3 else { return digits }
        var result = ""
        for (offset, character) in digits.enumerated() {
            if offset > 0, (digits.count - offset) % 3 == 0 { result.append(",") }
            result.append(character)
        }
        return result
    }
}
