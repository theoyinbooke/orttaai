// EditCorrectionFinder.swift
// Orttaai

import Foundation

/// A word the user fixed by hand after a dictation was inserted: what the
/// dictation wrote and what the user changed it to.
nonisolated struct EditCorrection: Equatable, Sendable {
    let heard: String
    let corrected: String
}

/// Finds dictionary-worthy corrections by comparing a text field right after
/// a dictation was inserted with the same field a little later. Deliberately
/// narrow: only small replacements inside the dictated text count, the new
/// spelling must look like a name or term (an unusual word, inner capitals,
/// or a capital in mid-sentence) and sound like what was heard, and a
/// rewrite of the dictation is ignored. Ordinary edits (a synonym, a
/// reworded sentence, text typed after the dictation) never become
/// suggestions.
nonisolated enum EditCorrectionFinder {
    /// At most this many dictated words replaced by one correction
    /// ("for lash a day" -> "Folasade").
    static let maxHeardWords = 4
    static let maxCorrectedWords = 2
    static let maxCorrectionsPerEdit = 3
    /// Word lists longer than this are not aligned (a huge rewrite).
    private static let maxAlignedWords = 400

    private struct Word {
        let text: String
        let range: Range<String.Index>
    }

    /// `before` is the field right after the dictation `inserted` went in,
    /// with the caret at `insertionEndUTF16` (the end of the inserted text);
    /// `after` is the same field later.
    static func corrections(
        inserted: String,
        before rawBefore: String,
        insertionEndUTF16 rawCaret: Int?,
        after rawAfter: String
    ) -> [EditCorrection] {
        let inserted = comparable(inserted)
        let before = comparable(rawBefore)
        let after = comparable(rawAfter)
        let insertionEndUTF16 = rawCaret.map { caret -> Int in
            let end = String.Index(utf16Offset: min(max(0, caret), rawBefore.utf16.count), in: rawBefore)
            return comparable(String(rawBefore[..<end])).utf16.count
        }
        guard before != after,
              let insertedRange = locate(inserted, in: before, endingNearUTF16: insertionEndUTF16) else { return [] }

        // Only the stretch that differs needs aligning: trim what the two
        // texts share at both ends, but keep the whole dictated text in view.
        let sharedPrefix = commonPrefixCount(before, after)
        let sharedSuffix = commonSuffixCount(before, after, limit: min(before.count, after.count) - sharedPrefix)
        let insertedStart = before.distance(from: before.startIndex, to: insertedRange.lowerBound)
        let insertedEnd = before.distance(from: before.startIndex, to: insertedRange.upperBound)
        let windowStart = min(sharedPrefix, insertedStart)
        let keptSuffix = min(sharedSuffix, before.count - insertedEnd)

        let beforeWindow = before.index(before.startIndex, offsetBy: windowStart)..<before.index(before.endIndex, offsetBy: -keptSuffix)
        let afterWindow = after.index(after.startIndex, offsetBy: windowStart)..<after.index(after.endIndex, offsetBy: -keptSuffix)
        let beforeWords = words(in: before, range: beforeWindow)
        let afterWords = words(in: after, range: afterWindow)
        guard beforeWords.count <= maxAlignedWords, afterWords.count <= maxAlignedWords else { return [] }

        let insertedWordCount = words(in: before, range: insertedRange).count
        var corrections: [EditCorrection] = []
        var changedInsertedWords = 0
        for block in replacementBlocks(beforeWords.map(\.text), afterWords.map(\.text)) {
            let heardWords = Array(beforeWords[block.before])
            let correctedWords = Array(afterWords[block.after])
            guard let first = heardWords.first, let last = heardWords.last,
                  first.range.lowerBound >= insertedRange.lowerBound,
                  last.range.upperBound <= insertedRange.upperBound else { continue }
            changedInsertedWords += heardWords.count
            guard heardWords.count <= maxHeardWords, (1...maxCorrectedWords).contains(correctedWords.count),
                  let correctedFirst = correctedWords.first, let correctedLast = correctedWords.last else { continue }

            let heard = String(before[first.range.lowerBound..<last.range.upperBound])
            let corrected = String(after[correctedFirst.range.lowerBound..<correctedLast.range.upperBound])
            if isDictionaryWorthy(
                heard: heard,
                corrected: corrected,
                correctedWords: correctedWords.map(\.text),
                joinsWords: heardWords.count > correctedWords.count,
                // A fix that starts a new sentence capitalizes for that reason.
                atSentenceStart: startsSentence(at: first.range.lowerBound, in: before)
                    || startsSentence(at: correctedFirst.range.lowerBound, in: after)
            ) {
                corrections.append(EditCorrection(heard: heard, corrected: corrected))
            }
        }

        // Rewording more than half of the dictation is a rewrite, not a fix
        // (short dictations still allow one full misheard name).
        guard changedInsertedWords <= max(maxHeardWords, insertedWordCount / 2) else { return [] }
        return Array(corrections.prefix(maxCorrectionsPerEdit))
    }

    // MARK: - Rules

    private static func isDictionaryWorthy(
        heard: String,
        corrected: String,
        correctedWords: [String],
        joinsWords: Bool,
        atSentenceStart: Bool
    ) -> Bool {
        let heardLetters = letters(of: heard)
        let correctedLetters = letters(of: corrected)
        guard !correctedLetters.isEmpty, heard != corrected else { return false }
        // Capitals in mid-sentence mark a name ("tanya" -> "Tania",
        // "x code" -> "Xcode") even when the word list holds the word.
        let capitalizedName = !atSentenceStart && correctedWords.allSatisfy { $0.first?.isUppercase == true }

        if heardLetters == correctedLetters {
            // A case-only fix is worth keeping for terms like GitHub or GRDB,
            // and for a name capitalized in mid-sentence (ola -> Ola,
            // x code -> Xcode), not for capitalizing the start of a sentence
            // or an ordinary word.
            if correctedWords.contains(where: hasInnerUppercase) { return true }
            return capitalizedName && (joinsWords || correctedWords.contains(where: looksLikeTerm))
        }
        guard capitalizedName || correctedWords.contains(where: looksLikeTerm) else { return false }
        // The fix has to sound like what was heard: a misspelled or misheard
        // name, not a different word chosen on reflection.
        return soundsAlike(heardLetters, correctedLetters)
    }

    /// Close in spelling, or the same consonants in the same order
    /// ("or tie" -> "Orttaai"), which a different word chosen on reflection
    /// rarely is ("cat" -> "kubectl").
    static func soundsAlike(_ heard: String, _ corrected: String) -> Bool {
        let distance = WordBoostGuard.editDistance(heard, corrected)
        if distance <= max(2, max(heard.count, corrected.count) / 2) { return true }
        let heardKey = consonantKey(heard)
        let correctedKey = consonantKey(corrected)
        guard min(heardKey.count, correctedKey.count) >= 2 else { return false }
        let allowed = max(heardKey.count, correctedKey.count) >= 4 ? 1 : 0
        return WordBoostGuard.editDistance(heardKey, correctedKey) <= allowed
    }

    /// Lowercase letters reduced to their consonant sounds: vowels and
    /// silent-prone h/w dropped, letters that sound alike folded, doubles
    /// collapsed ("orttaai" -> "rt", "kubernetes" -> "kbrnts").
    static func consonantKey(_ letters: String) -> String {
        var key = ""
        var previous: Character?
        for letter in letters.replacingOccurrences(of: "ph", with: "f") {
            let folded: Character
            switch letter {
            case "a", "e", "i", "o", "u", "y", "h", "w":
                previous = nil
                continue
            case "c", "q": folded = "k"
            case "z": folded = "s"
            default: folded = letter
            }
            if folded != previous { key.append(folded) }
            previous = folded
        }
        return key
    }

    /// Contractions and possessives are judged by the word they're built on
    /// (isn't, they're, Folasade's).
    private static let contractionEndings: Set<String> = ["t", "re", "ve", "ll", "d", "m", "s"]

    /// A name, product or code term rather than an ordinary English word.
    private static func looksLikeTerm(_ word: String) -> Bool {
        let lowered = word.lowercased()
        if hasInnerUppercase(word) { return true }
        if word.contains(where: \.isNumber), word.contains(where: \.isLetter) { return true }
        let parts = lowered.split(whereSeparator: { "'’".contains($0) }).map(String.init)
        if parts.count == 2, contractionEndings.contains(parts[1]) {
            // "isn't" splits as "isn" + "t": the base is "is".
            let bases = parts[1] == "t" ? [parts[0], String(parts[0].dropLast())] : [parts[0]]
            return !bases.contains(where: EnglishLexicon.isRealWord)
        }
        return word.contains(where: \.isLetter) && !EnglishLexicon.isRealWord(lowered)
    }

    /// Whether the word starting at `index` begins a sentence: the start of
    /// the field, or after . ! or ? (skipping spaces and opening quotes).
    private static func startsSentence(at index: String.Index, in text: String) -> Bool {
        var position = index
        while position > text.startIndex {
            position = text.index(before: position)
            let character = text[position]
            if character.isWhitespace || "\"'([“‘".contains(character) { continue }
            return ".!?".contains(character)
        }
        return true
    }

    private static func hasInnerUppercase(_ word: String) -> Bool {
        word.dropFirst().contains(where: \.isUppercase)
    }

    private static func letters(of text: String) -> String {
        String(text.lowercased().filter { $0.isLetter || $0.isNumber })
    }

    // MARK: - Whitespace

    /// Text as compared: whitespace as `normalizedWhitespace` does it, and
    /// curly quotes as straight ones, since many editors curl them as the
    /// text goes in. Every character maps to one, so offsets stay put.
    static func comparable(_ text: String) -> String {
        String(normalizedWhitespace(text).map { character -> Character in
            switch character {
            case "‘", "’": return "'"
            case "“", "”": return "\""
            default: return character
            }
        })
    }

    /// Editors keep spaces and line breaks their own way: a chat box may
    /// store a non-breaking space, or turn a line break into a paragraph.
    /// Text is compared with every run of whitespace as one plain space.
    static func normalizedWhitespace(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.count)
        var inWhitespace = false
        for character in text {
            if character.isWhitespace {
                if !inWhitespace { result.append(" ") }
                inWhitespace = true
            } else {
                result.append(character)
                inWhitespace = false
            }
        }
        return result
    }

    /// Whether a field's text holds the dictation, ignoring how the editor
    /// stored its whitespace and quotes, and a capital it added or removed
    /// (a chat box that capitalizes the first word).
    static func fieldText(_ text: String, contains inserted: String) -> Bool {
        let needle = comparable(inserted).trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return false }
        return comparable(text).range(of: needle, options: .caseInsensitive) != nil
    }

    // MARK: - Locating and aligning

    /// The occurrence of `inserted` that ends at, or closest to, the caret.
    private static func locate(_ inserted: String, in text: String, endingNearUTF16 caret: Int?) -> Range<String.Index>? {
        let trimmed = inserted.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var ranges: [Range<String.Index>] = []
        var searchStart = text.startIndex
        while let range = text.range(of: trimmed, options: .caseInsensitive, range: searchStart..<text.endIndex) {
            ranges.append(range)
            searchStart = range.upperBound
        }
        guard let caret else { return ranges.last }
        return ranges.min { lhs, rhs in
            abs(lhs.upperBound.utf16Offset(in: text) - caret) < abs(rhs.upperBound.utf16Offset(in: text) - caret)
        }
    }

    private static func words(in text: String, range: Range<String.Index>) -> [Word] {
        var words: [Word] = []
        var index = range.lowerBound
        while index < range.upperBound {
            guard text[index].isLetter || text[index].isNumber else {
                index = text.index(after: index)
                continue
            }
            let start = index
            while index < range.upperBound, text[index].isLetter || text[index].isNumber || "'’-".contains(text[index]) {
                index = text.index(after: index)
            }
            var end = index
            while end > start, "'’-".contains(text[text.index(before: end)]) {
                end = text.index(before: end)
            }
            words.append(Word(text: String(text[start..<end]), range: start..<end))
        }
        return words
    }

    /// Runs of words removed from `a` and added in `b` between the words the
    /// two lists share (longest common subsequence).
    private static func replacementBlocks(_ a: [String], _ b: [String]) -> [(before: Range<Int>, after: Range<Int>)] {
        var lengths = [[Int]](repeating: [Int](repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            for j in stride(from: b.count - 1, through: 0, by: -1) {
                lengths[i][j] = a[i] == b[j] ? lengths[i + 1][j + 1] + 1 : max(lengths[i + 1][j], lengths[i][j + 1])
            }
        }

        var blocks: [(before: Range<Int>, after: Range<Int>)] = []
        var i = 0, j = 0
        var blockStart: (Int, Int)?
        func closeBlock() {
            if let (startA, startB) = blockStart, i > startA, j > startB {
                blocks.append((startA..<i, startB..<j))
            }
            blockStart = nil
        }
        while i < a.count || j < b.count {
            if i < a.count, j < b.count, a[i] == b[j] {
                closeBlock()
                i += 1
                j += 1
            } else {
                if blockStart == nil { blockStart = (i, j) }
                if j < b.count, i == a.count || lengths[i][j + 1] >= lengths[i + 1][j] {
                    j += 1
                } else {
                    i += 1
                }
            }
        }
        closeBlock()
        return blocks
    }

    private static func commonPrefixCount(_ a: String, _ b: String) -> Int {
        zip(a, b).prefix { $0 == $1 }.count
    }

    private static func commonSuffixCount(_ a: String, _ b: String, limit: Int) -> Int {
        guard limit > 0 else { return 0 }
        return zip(a.reversed(), b.reversed()).prefix(limit).prefix { $0 == $1 }.count
    }
}
