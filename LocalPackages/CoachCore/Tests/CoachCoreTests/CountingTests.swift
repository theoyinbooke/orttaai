// CountingTests.swift
// CoachCoreTests
//
// Pins every rule ported from Orttakey's CoachStats, so the two apps keep
// counting a dictation the same way.

import Foundation
import Testing
@testable import CoachCore

@Suite("Counting, as Orttakey counts")
struct CountingTests {
    @Test func umAndUhIncludingStretchedSpellings() {
        let counts = CoachCounting.fillerCounts(in: "Um, so umm I think uh the uhh thing, erm, hmm, uhm works")
        // "erm" and "hmm" file as um; "uhm" files as uh.
        #expect(counts["um"] == 4)
        #expect(counts["uh"] == 3)
        #expect(CoachCounting.umUhCount(in: "Umbrella and hum don't count, nor huh") == 0)
    }

    @Test func youKnowUnlessAQuestionFollows() {
        #expect(CoachCounting.fillerCounts(in: "It was, you know, fine")["you know"] == 1)
        #expect(CoachCounting.fillerCounts(in: "You know what I did? You know how it goes") ["you know"] == nil)
        #expect(CoachCounting.fillerCounts(in: "you know that, you know")["you know"] == 1)
    }

    @Test func likeOnlyBesideAComma() {
        // One "like" between two commas is one match.
        #expect(CoachCounting.fillerCounts(in: "It was, like, really big")["like"] == 1)
        #expect(CoachCounting.fillerCounts(in: "It was, like big, like, you see")["like"] == 2)
        #expect(CoachCounting.fillerCounts(in: "I like it and it looks like rain")["like"] == nil)
    }

    @Test func otherPhrases() {
        let counts = CoachCounting.fillerCounts(in: "I mean it basically works. Actually it does, I MEAN it.")
        #expect(counts["I mean"] == 2)
        #expect(counts["basically"] == 1)
        #expect(counts["actually"] == 1)
        #expect(CoachCounting.phraseFillerCount(in: "I mean it basically works. Actually it does, I MEAN it.") == 4)
    }

    @Test func repeatsCountWordsSaidTwice() {
        #expect(CoachCounting.repeatCount(in: "I I think the the plan works") == 2)
        #expect(CoachCounting.repeatCount(in: "We had had enough") == 1)
        #expect(CoachCounting.repeatCount(in: "so, so good") == 1)
        #expect(CoachCounting.repeatCount(in: "this is fine") == 0)
    }

    @Test func wordsAreWhitespaceTokens() {
        #expect(CoachCounting.wordCount("  one two\nthree\tfour  ") == 4)
        #expect(CoachCounting.wordCount("") == 0)
    }

    @Test func paceNeedsTenWordsAndFiveSeconds() {
        let ten = Array(repeating: "word", count: 10).joined(separator: " ")
        #expect(CoachCounting.pace(ten, recordingMs: 4_999) == nil)
        #expect(CoachCounting.pace("too short", recordingMs: 60_000) == nil)
        #expect(CoachCounting.pace(ten, recordingMs: 5_000) == 120)
        let thirty = Array(repeating: "word", count: 30).joined(separator: " ")
        #expect(CoachCounting.pace(thirty, recordingMs: 12_000) == 150)
    }

    @Test func sentencesSplitLikeParagrapher() {
        #expect(CoachCounting.sentences(in: "It costs 3.5 dollars. Then we go! Why? e.g. this stays.") ==
            ["It costs 3.5 dollars.", "Then we go!", "Why? e.g. this stays."])
        // A quote may open the next sentence, but a closing quote or bracket
        // right after the stop keeps the sentence going, as in Orttakey.
        #expect(CoachCounting.sentences(in: "He said. \"Fine.\" (Later.) 4 more") ==
            ["He said.", "\"Fine.\" (Later.) 4 more"])
        #expect(CoachCounting.sentenceLengths(in: "One two three. Four five.") == [3, 2])
        #expect(CoachCounting.sentenceLengths(in: "") == [])
    }

    @Test func polishFixesIgnoreRemovedFillers() {
        // Only the fillers went: nothing was rewritten.
        #expect(CoachCounting.polishChangeRatio(heard: "Um so I I think, like, it works", written: "So I think it works.") == 0)
        // Half the words changed.
        let ratio = CoachCounting.polishChangeRatio(heard: "send the file to sam today", written: "Send the report to Sam tomorrow.")
        #expect(abs(ratio - 2.0 / 6.0) < 0.0001)
        #expect(CoachCounting.polishChangeRatio(heard: "", written: "") == 0)
    }
}

@Suite("One dictation's measures")
struct DictationMeasuresTests {
    @Test func measuresAKnownRawTranscript() {
        let m = DictationMeasures(measuring: CoachDictation(
            createdAt: Date(),
            heard: "Um so the the plan is basically done. We ship it on Friday, you know, after review.",
            written: "The plan is done. We ship it on Friday after review.",
            recordingMs: 6_000,
            rawKnown: true
        ))
        #expect(m.words == 17)
        #expect(m.umUh == 1)
        #expect(m.phraseFillers == 2)
        #expect(m.repeats == 1)
        #expect(m.wpm == 170)
        #expect(m.sentenceLengths == [8, 9])
        #expect(m.medianSentence == 9)
        #expect(m.longestSentence == 9)
        #expect(m.polishChangeRatio != nil)
    }

    @Test func unknownRawLeavesTextMeasuresOut() {
        let m = DictationMeasures(measuring: CoachDictation(
            createdAt: Date(),
            heard: "The plan is done and we ship it on Friday after the review.",
            written: "The plan is done and we ship it on Friday after the review.",
            recordingMs: 5_000,
            rawKnown: false
        ))
        #expect(m.polishChangeRatio == nil)
        #expect(CoachMeasure.fillers.value(of: m) == nil)
        #expect(CoachMeasure.sentences.value(of: m) == nil)
        #expect(CoachMeasure.repeats.value(of: m) == nil)
        #expect(CoachMeasure.pace.value(of: m) == 156)
    }

    @Test func roundTripsAsJSON() throws {
        let m = DictationMeasures(words: 20, umUh: 1, phraseFillers: 0, wpm: nil, sentenceLengths: [12, 8], repeats: 0, polishChangeRatio: 0.1, rawKnown: true)
        let back = try JSONDecoder().decode(DictationMeasures.self, from: JSONEncoder().encode(m))
        #expect(back == m)
    }
}
