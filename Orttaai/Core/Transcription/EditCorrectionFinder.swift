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
/// spelling must look like a name or term, and a rewrite of the dictation is
/// ignored. Ordinary edits (a synonym, a reworded sentence, text typed after
/// the dictation) never become suggestions.
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
        before: String,
        insertionEndUTF16: Int?,
        after: String
    ) -> [EditCorrection] {
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
            if isDictionaryWorthy(heard: heard, corrected: corrected, correctedWords: correctedWords.map(\.text)) {
                corrections.append(EditCorrection(heard: heard, corrected: corrected))
            }
        }

        // Rewording more than half of the dictation is a rewrite, not a fix
        // (short dictations still allow one full misheard name).
        guard changedInsertedWords <= max(maxHeardWords, insertedWordCount / 2) else { return [] }
        return Array(corrections.prefix(maxCorrectionsPerEdit))
    }

    // MARK: - Rules

    private static func isDictionaryWorthy(heard: String, corrected: String, correctedWords: [String]) -> Bool {
        let heardLetters = letters(of: heard)
        let correctedLetters = letters(of: corrected)
        guard !correctedLetters.isEmpty, heard != corrected else { return false }

        if heardLetters == correctedLetters {
            // A case-only fix is worth keeping for terms like GitHub or GRDB,
            // not for capitalizing the start of a sentence.
            return correctedWords.contains(where: hasInnerUppercase)
        }
        guard correctedWords.contains(where: looksLikeTerm) else { return false }
        // The fix has to sound like what was heard: a misspelled or misheard
        // name, not a different word chosen on reflection.
        let distance = WordBoostGuard.editDistance(heardLetters, correctedLetters)
        return distance <= max(2, max(heardLetters.count, correctedLetters.count) / 2)
    }

    /// A name, product or code term rather than an ordinary English word.
    private static func looksLikeTerm(_ word: String) -> Bool {
        let lowered = word.lowercased()
        if hasInnerUppercase(word) { return true }
        if word.contains(where: \.isNumber), word.contains(where: \.isLetter) { return true }
        return word.contains(where: \.isLetter) && !EnglishLexicon.isRealWord(lowered)
    }

    private static func hasInnerUppercase(_ word: String) -> Bool {
        word.dropFirst().contains(where: \.isUppercase)
    }

    private static func letters(of text: String) -> String {
        String(text.lowercased().filter { $0.isLetter || $0.isNumber })
    }

    // MARK: - Locating and aligning

    /// The occurrence of `inserted` that ends at, or closest to, the caret.
    private static func locate(_ inserted: String, in text: String, endingNearUTF16 caret: Int?) -> Range<String.Index>? {
        let trimmed = inserted.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var ranges: [Range<String.Index>] = []
        var searchStart = text.startIndex
        while let range = text.range(of: trimmed, range: searchStart..<text.endIndex) {
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
