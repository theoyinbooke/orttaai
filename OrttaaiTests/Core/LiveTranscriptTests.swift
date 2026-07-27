// LiveTranscriptTests.swift
// OrttaaiTests

import XCTest
@testable import Orttaai

final class LiveTranscriptTests: XCTestCase {
    func testCommitsAppendInOrder() {
        var transcript = LiveTranscript()

        transcript.apply(.committed("The first clip"))
        transcript.apply(.committed("and the second clip"))

        XCTAssertEqual(transcript.committedText, "The first clip and the second clip")
        XCTAssertEqual(transcript.speculativeText, "")
    }

    func testSpeculativeTailReplacesPreviousTail() {
        var transcript = LiveTranscript()

        transcript.apply(.speculative("hel"))
        transcript.apply(.speculative("hello wor"))
        transcript.apply(.speculative("hello world"))

        XCTAssertEqual(transcript.speculativeText, "hello world")
        XCTAssertEqual(transcript.committedText, "")
    }

    func testCommitSupersedesSpeculativeTail() {
        var transcript = LiveTranscript()

        transcript.apply(.speculative("hello wor"))
        transcript.apply(.committed("hello world"))

        XCTAssertEqual(transcript.committedText, "hello world")
        XCTAssertEqual(transcript.speculativeText, "", "A commit covers the tail's audio; the stale tail must be dropped")
    }

    func testEmptyCommitClearsTailWithoutAppending() {
        var transcript = LiveTranscript()

        transcript.apply(.committed("hello"))
        transcript.apply(.speculative("stray tail"))
        transcript.apply(.committed(""))

        XCTAssertEqual(transcript.committedText, "hello")
        XCTAssertEqual(transcript.speculativeText, "")
    }

    func testCommittedTextIsNeverRewrittenBySpeculativeEvents() {
        var transcript = LiveTranscript()

        transcript.apply(.committed("stable prefix"))
        transcript.apply(.speculative("tail one"))
        transcript.apply(.speculative("tail two revised"))

        XCTAssertEqual(transcript.committedText, "stable prefix")
    }

    func testSessionBeganClearsEverything() {
        var transcript = LiveTranscript()
        transcript.apply(.committed("old dictation"))
        transcript.apply(.speculative("old tail"))

        transcript.apply(.sessionBegan)

        XCTAssertTrue(transcript.isEmpty)
        XCTAssertEqual(transcript.committedText, "")
        XCTAssertEqual(transcript.speculativeText, "")
    }

    func testCommitsNormalizeBlankAudioMarkersAndWhitespace() {
        var transcript = LiveTranscript()

        transcript.apply(.committed("  hello  "))
        transcript.apply(.committed("[BLANK_AUDIO]"))
        transcript.apply(.committed("world"))

        XCTAssertEqual(transcript.committedText, "hello world")
    }

    func testCommittedTextStaysBoundedForLongDictations() {
        var transcript = LiveTranscript()
        let clip = String(repeating: "word ", count: 40).trimmingCharacters(in: .whitespaces)

        for _ in 0..<60 {
            transcript.apply(.committed(clip))
        }

        XCTAssertLessThanOrEqual(
            transcript.committedText.count,
            LiveTranscript.maxCommittedDisplayCharacters
        )
        XCTAssertTrue(transcript.committedText.hasSuffix("word"), "The trailing portion must be preserved")
    }

    func testIsEmptyReflectsBothComponents() {
        var transcript = LiveTranscript()
        XCTAssertTrue(transcript.isEmpty)

        transcript.apply(.speculative("tail"))
        XCTAssertFalse(transcript.isEmpty)

        transcript.apply(.committed(""))
        XCTAssertTrue(transcript.isEmpty)

        transcript.apply(.committed("text"))
        XCTAssertFalse(transcript.isEmpty)
    }
}
