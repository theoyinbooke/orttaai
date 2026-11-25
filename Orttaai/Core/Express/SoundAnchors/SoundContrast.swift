// SoundContrast.swift
// Orttaai (ported from Orttakey's OrttakeyPolish, same rules and numbers)
//
// Whether a word sounded like what the speech model wrote or like one of
// your words, judged from the sound itself rather than the spelling.
//
// The speech model writes "email" when you said "emailer". A text rule
// ("email" -> "emailer") would then rewrite every "email" you ever say, and
// Word Boost won't touch an ordinary word. So each candidate is scored
// against the recording: Word Boost's CTC model gives, for every 40 ms frame,
// how likely each sound piece is. The phrase with its neighbours,
// "open email and", and the same phrase with your word, "open emailer and",
// are each scored over the same stretch of sound with the CTC forward
// algorithm. The difference is how much better one explains what was said.
// Either explanation has to account for every frame, so an "-er" that isn't
// in the audio costs "emailer", and an "-er" that is there costs "email".
//
// Pure Swift: the transcriber supplies the frames, timings and token ids.

import Foundation

/// A word the speech model wrote, with when it was said.
nonisolated struct SoundWord: Sendable, Equatable {
    var text: String
    var start: TimeInterval
    var end: TimeInterval

    init(text: String, start: TimeInterval, end: TimeInterval) {
        self.text = text
        self.start = start
        self.end = end
    }

    /// Words from the speech model's token timings: a token that starts with
    /// SentencePiece's "▁" (or a space) starts a new word.
    static func words(fromTokens tokens: [(token: String, start: TimeInterval, end: TimeInterval)]) -> [SoundWord] {
        var words: [SoundWord] = []
        for timing in tokens {
            let token = timing.token
            guard !token.isEmpty, token != "<blank>", token != "<pad>" else { continue }
            let startsWord = token.hasPrefix("▁") || token.hasPrefix(" ") || words.isEmpty
            let piece = token.replacingOccurrences(of: "▁", with: "").trimmingCharacters(in: .whitespaces)
            if startsWord {
                guard !piece.isEmpty else { continue }
                words.append(SoundWord(text: piece, start: timing.start, end: timing.end))
            } else if !piece.isEmpty, !words.isEmpty {
                words[words.count - 1].text += piece
                words[words.count - 1].end = timing.end
            }
        }
        return words
    }
}

nonisolated enum SoundContrast {
    /// The speech model's word timings and the CTC model's frames can be a
    /// few frames apart (0.3 s was seen), so each side is scored with three
    /// words of context either way and this much sound around them. Both
    /// sides explain the same frames, so the context cancels out and only
    /// the phrase itself makes the difference.
    static let contextWords = 3
    static let paddingSeconds: TimeInterval = 0.4

    /// Lowercased letters, digits and apostrophes: how words are compared.
    static func key(_ text: String) -> [String] {
        text.lowercased()
            .replacingOccurrences(of: "\u{2019}", with: "'")
            .split { !($0.isLetter || $0.isNumber || $0 == "'") }
            .map(String.init)
    }

    /// Where `phrase` was written in `words`, as word ranges. Each written
    /// word counts by its letters alone, so "E-mail," is "email".
    static func occurrences(of phrase: String, in words: [SoundWord]) -> [Range<Int>] {
        let wanted = key(phrase).map(letters)
        guard !wanted.isEmpty, words.count >= wanted.count else { return [] }
        let written = words.map { letters($0.text) }
        var found: [Range<Int>] = []
        var index = 0
        while index + wanted.count <= written.count {
            if Array(written[index..<(index + wanted.count)]) == wanted {
                found.append(index..<(index + wanted.count))
                index += wanted.count
            } else {
                index += 1
            }
        }
        return found
    }

    static func letters(_ text: String) -> String {
        text.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    /// The stretch of sound to score `range` in, with one neighbouring word on
    /// each side, and the text of those neighbours.
    struct Window: Sendable, Equatable {
        var frames: Range<Int>
        var before: String
        var after: String
    }

    static func window(for range: Range<Int>, in words: [SoundWord], frameDuration: TimeInterval, frameCount: Int) -> Window? {
        guard frameDuration > 0, frameCount > 0, range.lowerBound >= 0, range.upperBound <= words.count, !range.isEmpty else { return nil }
        let first = max(0, range.lowerBound - contextWords)
        let last = min(words.count - 1, range.upperBound - 1 + contextWords)
        // Whole recording when the context reaches both ends.
        let start = first == 0 ? 0 : max(0, words[first].start - paddingSeconds)
        let lower = max(0, Int((start / frameDuration).rounded(.down)))
        let upper = last == words.count - 1 ? frameCount : min(frameCount, Int(((words[last].end + paddingSeconds) / frameDuration).rounded(.up)) + 1)
        guard lower < upper else { return nil }
        return Window(
            frames: lower..<upper,
            before: words[first..<range.lowerBound].map(\.text).joined(separator: " "),
            after: words[range.upperBound...last].map(\.text).joined(separator: " ")
        )
    }

    /// The text each side is scored as: the phrase with its neighbours.
    static func phrase(_ middle: String, in window: Window) -> String {
        [window.before, middle, window.after].filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// The words of `spelled` (the CTC model's own transcript) that line up
    /// with `range` of `words` (the speech model's): whatever lies between
    /// the matching words either side. How that stretch sounded, spelled
    /// the CTC model's way.
    static func spelling(of range: Range<Int>, in words: [SoundWord], spelled: [String]) -> String? {
        let ours = words.map { key($0.text).joined() }
        let theirs = spelled.map { key($0).joined() }
        guard !ours.isEmpty, !theirs.isEmpty else { return nil }
        // Longest common subsequence, as index pairs.
        var table = Array(repeating: Array(repeating: 0, count: theirs.count + 1), count: ours.count + 1)
        for i in stride(from: ours.count - 1, through: 0, by: -1) {
            for j in stride(from: theirs.count - 1, through: 0, by: -1) {
                table[i][j] = ours[i] == theirs[j] ? table[i + 1][j + 1] + 1 : max(table[i + 1][j], table[i][j + 1])
            }
        }
        var pairs: [(Int, Int)] = []
        var i = 0, j = 0
        while i < ours.count, j < theirs.count {
            if ours[i] == theirs[j] {
                pairs.append((i, j)); i += 1; j += 1
            } else if table[i + 1][j] >= table[i][j + 1] {
                i += 1
            } else {
                j += 1
            }
        }
        let before = pairs.last { $0.0 < range.lowerBound }?.1 ?? -1
        let after = pairs.first { $0.0 >= range.upperBound }?.1 ?? theirs.count
        // Words of the range that matched exactly are part of the answer too.
        guard before + 1 < after else { return nil }
        let middle = spelled[(before + 1)..<after].joined(separator: " ")
        return middle.isEmpty ? nil : middle
    }

    /// log P(tokens | frames) under CTC, summed over every alignment, with
    /// `blank` the blank token's index. -infinity when the frames are too few.
    static func logLikelihood(_ logProbs: [[Float]], frames: Range<Int>, tokens: [Int], blank: Int) -> Float {
        let count = frames.count
        guard count > 0 else { return -.infinity }
        guard !tokens.isEmpty else {
            return frames.reduce(Float(0)) { $0 + logProbs[$1][blank] }
        }
        // The extended label sequence: blank, t1, blank, t2, ..., blank.
        var labels = [blank]
        for token in tokens { labels += [token, blank] }
        let width = labels.count
        let negativeInfinity = -Float.infinity
        var alpha = [Float](repeating: negativeInfinity, count: width)
        let first = logProbs[frames.lowerBound]
        alpha[0] = first[blank]
        alpha[1] = labels[1] < first.count ? first[labels[1]] : negativeInfinity
        var next = alpha
        for frame in frames.dropFirst() {
            let row = logProbs[frame]
            for s in 0..<width {
                var total = alpha[s]
                if s >= 1 { total = logAdd(total, alpha[s - 1]) }
                if s >= 2, labels[s] != blank, labels[s] != labels[s - 2] { total = logAdd(total, alpha[s - 2]) }
                let emit = labels[s] < row.count ? row[labels[s]] : negativeInfinity
                next[s] = total == negativeInfinity ? negativeInfinity : total + emit
            }
            swap(&alpha, &next)
        }
        return logAdd(alpha[width - 1], alpha[width - 2])
    }

    static func logAdd(_ a: Float, _ b: Float) -> Float {
        if a == -.infinity { return b }
        if b == -.infinity { return a }
        let m = max(a, b)
        return m + logf(expf(a - m) + expf(b - m))
    }

    /// How much better `term` explains the sound than `heard`, in nats, over
    /// the same window: above zero it sounded more like your word.
    static func margin(
        _ logProbs: [[Float]],
        window: Window,
        heard: String,
        term: String,
        blank: Int,
        encode: (String) -> [Int]
    ) -> Float? {
        let heardScore = logLikelihood(logProbs, frames: window.frames, tokens: encode(phrase(heard, in: window)), blank: blank)
        let termScore = logLikelihood(logProbs, frames: window.frames, tokens: encode(phrase(term, in: window)), blank: blank)
        guard heardScore.isFinite, termScore.isFinite else { return nil }
        return termScore - heardScore
    }
}
