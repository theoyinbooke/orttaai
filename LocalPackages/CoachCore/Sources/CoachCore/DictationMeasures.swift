// DictationMeasures.swift
// CoachCore

import Foundation

/// One dictation, as Coach needs it.
public struct CoachDictation: Sendable {
    public var createdAt: Date
    /// What the speech model heard, before Polish: fillers and all.
    public var heard: String
    /// What landed in the app.
    public var written: String
    public var recordingMs: Int
    /// False on old rows where only the polished text was kept, whose
    /// fillers, repeats and sentences can't be told.
    public var rawKnown: Bool

    public init(createdAt: Date, heard: String, written: String, recordingMs: Int, rawKnown: Bool) {
        self.createdAt = createdAt
        self.heard = heard
        self.written = written
        self.recordingMs = recordingMs
        self.rawKnown = rawKnown
    }
}

/// The counts for one dictation. Numbers only: no text is kept.
public struct DictationMeasures: Sendable, Equatable, Codable {
    /// Bumped whenever a rule changes, so stored counts are redone.
    public static let version = 1

    public var words: Int
    public var umUh: Int
    public var phraseFillers: Int
    public var wpm: Int?
    public var sentenceLengths: [Int]
    public var repeats: Int
    /// nil when what was heard isn't known.
    public var polishChangeRatio: Double?
    public var rawKnown: Bool

    public init(
        words: Int,
        umUh: Int,
        phraseFillers: Int,
        wpm: Int?,
        sentenceLengths: [Int],
        repeats: Int,
        polishChangeRatio: Double?,
        rawKnown: Bool
    ) {
        self.words = words
        self.umUh = umUh
        self.phraseFillers = phraseFillers
        self.wpm = wpm
        self.sentenceLengths = sentenceLengths
        self.repeats = repeats
        self.polishChangeRatio = polishChangeRatio
        self.rawKnown = rawKnown
    }

    public init(measuring dictation: CoachDictation) {
        let heard = dictation.heard
        words = CoachCounting.wordCount(heard)
        umUh = CoachCounting.umUhCount(in: heard)
        phraseFillers = CoachCounting.phraseFillerCount(in: heard)
        wpm = CoachCounting.pace(heard, recordingMs: dictation.recordingMs)
        sentenceLengths = CoachCounting.sentenceLengths(in: heard)
        repeats = CoachCounting.repeatCount(in: heard)
        polishChangeRatio = dictation.rawKnown
            ? CoachCounting.polishChangeRatio(heard: heard, written: dictation.written)
            : nil
        rawKnown = dictation.rawKnown
    }

    /// The upper middle length, as Orttakey takes it.
    public var medianSentence: Int? {
        let sorted = sentenceLengths.sorted()
        return sorted.isEmpty ? nil : sorted[sorted.count / 2]
    }

    public var longestSentence: Int? { sentenceLengths.max() }
}
