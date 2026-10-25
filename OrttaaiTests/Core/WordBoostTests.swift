// WordBoostTests.swift
// OrttaaiTests
//
// The guard cases are real Word Boost proposals from the gauntlet corpora,
// with their measured acoustic margins (gauntlet/asr_eval/word_boost_guard.json).

import XCTest
@testable import Orttaai

final class WordBoostTests: XCTestCase {

    private func accepts(_ heard: String, _ term: String, margin: Float) -> Bool {
        WordBoostGuard.accepts(.init(heard: heard, term: term, acousticMargin: margin))
    }

    // MARK: - Guard

    func testSpelledOutJoinsAreKept() {
        XCTAssertTrue(accepts("use effect callback", "useEffectCallback", margin: -2.13))
        XCTAssertTrue(accepts("decoding options,", "DecodingOptions", margin: -3.36))
        XCTAssertTrue(accepts("decoding option", "DecodingOptions", margin: -1.88))
        XCTAssertTrue(accepts("Finalized live transcription", "finalizeLiveTranscription", margin: -1.73))
        XCTAssertTrue(accepts("committed sample cant", "committedSampleCount", margin: -1.4))
    }

    func testOrdinaryWordsNeedStrongAcousticEvidence() {
        XCTAssertFalse(accepts("code", "Xcode", margin: -1.67))
        XCTAssertFalse(accepts("decoder.", "Xcode", margin: -0.93))
        XCTAssertFalse(accepts("transcript", "TypeScript", margin: -4.87))
        XCTAssertFalse(accepts("grab", "GRDB", margin: -1.95))
        XCTAssertFalse(accepts("Whisper", "WhisperKit", margin: -1.68))
        XCTAssertTrue(accepts("common case", "camelCase", margin: -0.58))
        // The one correct proposal the guard gives up: the audio was not clear enough.
        XCTAssertFalse(accepts("upcast", "appcast", margin: -2.04))
    }

    func testMisheardNamesAreKept() {
        XCTAssertTrue(accepts("Quen", "Qwen", margin: -2.24))
        XCTAssertTrue(accepts("Aluwa soon", "Oluwaseun", margin: -2.08))
        XCTAssertTrue(accepts("Tamitoke", "Temitope", margin: -1.97))
    }

    func testFloorRejectsTermsThatSoundClearlyWorse() {
        XCTAssertFalse(accepts("runbook,", "Oyinbooke", margin: -5.61))
        XCTAssertFalse(accepts("release.", "camelCase", margin: -4.23))
    }

    /// Swaps from real Express dictations (Oct 24-25) that put a dictionary
    /// word where the user said something spelled nothing like it.
    func testTermsSpelledNothingLikeTheHeardWordsAreRejected() {
        XCTAssertFalse(accepts("Mac mini", "Meetumo", margin: -0.4))
        XCTAssertFalse(accepts("space bar", "supabase", margin: -0.3))
        XCTAssertFalse(accepts("make a", "Arsenal", margin: -0.2))
        XCTAssertFalse(accepts("I'm", "Meetumo", margin: 0.5))
        // Near-misses of names still pass.
        XCTAssertTrue(accepts("Folosiday", "Folasade", margin: -1.43))
        XCTAssertTrue(accepts("Olama's", "Ollama", margin: 0.84))
    }

    func testContractionsAndCommonWordsCountAsOrdinaryWords() {
        for word in ["i'm", "it's", "don't", "didn't", "you're", "we've", "they'll", "she'd", "can't", "won't", "it\u{2019}s"] {
            XCTAssertTrue(EnglishLexicon.isRealWord(word), word)
        }
        XCTAssertTrue(EnglishLexicon.isRealWord("mini"))
        XCTAssertTrue(EnglishLexicon.isRealWord("spacebar"))
        XCTAssertFalse(EnglishLexicon.isRealWord("olama's"))
        XCTAssertEqual(WordBoostGuard.words(in: "It\u{2019}s fine"), ["it's", "fine"])
    }

    func testReplacementsThatDropSpokenWordsAreRejected() {
        XCTAssertFalse(accepts("keep LM Studio", "LM Studio", margin: 0.29))
        XCTAssertFalse(accepts("or LM Studio", "LM Studio", margin: -0.26))
    }

    // MARK: - Applying replacements

    func testReplacementsKeepAttachedPunctuation() throws {
        guard #available(macOS 15, *) else { throw XCTSkip("Express needs macOS 15") }
        let text = "Ask Olen Ruaju, then ship Whisper kit."
        let olen = text.utf8.count - "Olen Ruaju, then ship Whisper kit.".utf8.count
        let whisper = text.utf8.count - "Whisper kit.".utf8.count
        let result = ExpressTranscriber.applying(
            [(olen..<(olen + "Olen Ruaju,".utf8.count), "Olanrewaju"), (whisper..<text.utf8.count, "WhisperKit")],
            to: text
        )
        XCTAssertEqual(result, "Ask Olanrewaju, then ship WhisperKit.")
    }

    func testReplacementsIndexUTF8BytesNotCharacters() throws {
        guard #available(macOS 15, *) else { throw XCTSkip("Express needs macOS 15") }
        let text = "Café notes for Quen"
        let start = text.utf8.count - "Quen".utf8.count
        XCTAssertEqual(
            ExpressTranscriber.applying([(start..<text.utf8.count, "Qwen")], to: text),
            "Café notes for Qwen"
        )
    }

    // MARK: - Dictionary to vocabulary

    private func entry(_ source: String, _ target: String, active: Bool = true) -> DictionaryEntry {
        DictionaryEntry(
            id: nil,
            source: source,
            target: target,
            normalizedSource: source.lowercased(),
            isCaseSensitive: false,
            isActive: active,
            usageCount: 0,
            createdAt: Date(),
            updatedAt: Date()
        )
    }

    func testDictionaryTargetsBecomeTermsWithTheirMisheardSpellings() {
        let terms = RuleBasedTextProcessor.wordBoostTerms(from: [
            entry("alan ruaju", "Olanrewaju"),
            entry("olen ruajoinbook", "Olanrewaju"),
            entry("Alan Ruaju", "olanrewaju"),
            entry("whisper kit", "WhisperKit"),
            entry("Qwen", "Qwen"),
            entry("stale", "Retired", active: false),
        ])

        XCTAssertEqual(terms, [
            WordBoostTerm(text: "Olanrewaju", aliases: ["alan ruaju", "olen ruajoinbook"]),
            WordBoostTerm(text: "WhisperKit", aliases: ["whisper kit"]),
            WordBoostTerm(text: "Qwen", aliases: []),
        ])
    }
}
