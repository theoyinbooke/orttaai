// FuzzyDictionaryMatcherTests.swift
// OrttaaiTests

import XCTest
@testable import Orttaai

@MainActor
final class FuzzyDictionaryMatcherTests: XCTestCase {
    private func corrected(_ text: String, targets: [String]) -> String {
        FuzzyDictionaryMatcher(targets: targets).apply(to: text).text
    }

    // MARK: - Lexicon

    func testLexiconLoadsFromBundleWithinSizeBudget() throws {
        XCTAssertTrue(EnglishLexicon.isAvailable)

        let url = try XCTUnwrap(Bundle(for: RuleBasedTextProcessor.self).url(forResource: "english-words", withExtension: "txt"))
        let size = try XCTUnwrap(try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int)
        XCTAssertLessThan(size, 1_500_000)
        XCTAssertGreaterThan(size, 100_000)
    }

    func testLexiconAcceptsWordsAndRegularInflectionsButNotNames() {
        for word in ["verse", "verses", "arena", "script", "transcript", "cache", "cash", "codes", "stopped", "meetup", "meetups", "app"] {
            XCTAssertTrue(EnglishLexicon.isRealWord(word), word)
        }
        for word in ["temitope", "temitayo", "meetumo", "oyinbooke", "tematope", "vercel", "supabase"] {
            XCTAssertFalse(EnglishLexicon.isRealWord(word), word)
        }
    }

    // MARK: - Corrections

    func testNearMissNamesAreCorrectedToTheTargetSpelling() {
        let temitope = ["Temitope"]
        XCTAssertEqual(corrected("Tematope will present the metrics.", targets: temitope), "Temitope will present the metrics.")
        XCTAssertEqual(corrected("Taimytope will draft it.", targets: temitope), "Temitope will draft it.")
        XCTAssertEqual(corrected("Taimitope's team shipped.", targets: temitope), "Temitope's team shipped.")

        for variant in ["Mitumo", "Metumo", "Mitoomo"] {
            XCTAssertEqual(corrected("Ask \(variant) about it", targets: ["Meetumo"]), "Ask Meetumo about it", variant)
        }

        XCTAssertEqual(corrected("Owenbook asked", targets: ["Oyinbooke"]), "Oyinbooke asked")
        XCTAssertEqual(corrected("Owen Book asked", targets: ["Oyinbooke"]), "Oyinbooke asked")
        XCTAssertEqual(corrected("Ask Yemesi to update it", targets: ["Yemisi"]), "Ask Yemisi to update it")
        XCTAssertEqual(corrected("Send it to Folosaday today", targets: ["Folasade"]), "Send it to Folasade today")
        XCTAssertEqual(corrected("Install Olima first", targets: ["Ollama"]), "Install Ollama first")
    }

    func testNearMissBrandsAcrossWordBoundariesAreCorrected() {
        XCTAssertEqual(corrected("The Postgar SQL replica lagged.", targets: ["PostgreSQL"]), "The PostgreSQL replica lagged.")
        XCTAssertEqual(corrected("Mitomo app is live", targets: ["Meetumo-app"]), "Meetumo-app is live")
    }

    func testCompoundExactWindowsAreJoinedToTheTarget() {
        XCTAssertEqual(corrected("I love chat GPT a lot", targets: ["ChatGPT"]), "I love ChatGPT a lot")
        XCTAssertEqual(corrected("Set the no speech threshold now", targets: ["noSpeechThreshold"]), "Set the noSpeechThreshold now")
        XCTAssertEqual(corrected("The app cast feed is stale", targets: ["appcast"]), "The appcast feed is stale")
        XCTAssertEqual(corrected("Use the use effect callback hook", targets: ["useEffectCallback"]), "Use the useEffectCallback hook")
        XCTAssertEqual(corrected("The Whisper Kit upgrade", targets: ["WhisperKit"]), "The WhisperKit upgrade")
        XCTAssertEqual(corrected("half in camel case", targets: ["camelCase"]), "half in camelCase")
        XCTAssertEqual(corrected("The energy VAD framing", targets: ["EnergyVAD"]), "The EnergyVAD framing")
    }

    func testTargetCasingIsAppliedToAnUnlistedSpelling() {
        XCTAssertEqual(corrected("open the websocket now", targets: ["WebSocket"]), "open the WebSocket now")
        XCTAssertEqual(corrected("asked chatgpt about it", targets: ["ChatGpt"]), "asked ChatGpt about it")
    }

    func testMixedCaseSpellingOfTheTargetIsNotFlattened() {
        XCTAssertEqual(corrected("look at ChatGPT, you know", targets: ["ChatGpt"]), "look at ChatGPT, you know")
        XCTAssertEqual(corrected("open Websocket now", targets: ["WebSocket"]), "open WebSocket now")
    }

    func testEveryOccurrenceIsCorrectedAndReported() {
        let result = FuzzyDictionaryMatcher(targets: ["Temitope", "Meetumo"])
            .apply(to: "Tematope met Mitumo, then Tematope left.")
        XCTAssertEqual(result.text, "Temitope met Meetumo, then Temitope left.")
        XCTAssertEqual(
            result.replacements,
            [
                .init(original: "Tematope", target: "Temitope"),
                .init(original: "Mitumo", target: "Meetumo"),
                .init(original: "Tematope", target: "Temitope")
            ]
        )
    }

    func testAlreadyCorrectTextIsUntouched() {
        let targets = ["Temitope", "Meetumo-app", "noSpeechThreshold", "PostgreSQL", "Vercel"]
        for text in ["Temitope", "Meetumo-app ships", "the noSpeechThreshold value", "PostgreSQL and Vercel"] {
            XCTAssertEqual(corrected(text, targets: targets), text)
        }
    }

    // MARK: - Guards

    func testRealEnglishWordsNearTargetsAreNeverRewritten() {
        let targets = ["Vercel", "Meetumo", "Arsenal", "TypeScript", "Temitope", "Yemisi", "Folasade", "Supabase", "Codexis"]
        let sentences = [
            "Read the verse and then the verses again.",
            "Join the meetup and other meetups.",
            "The arena was full and the arsenal was empty.",
            "Write the script and read the transcript.",
            "Clear the cache and pay cash.",
            "Enter the codes and use the codex.",
            "Temitayo and Yemi are different people from Temitope.",
            "A super base for a super basement.",
            "The vessel was late."
        ]
        for sentence in sentences {
            XCTAssertEqual(corrected(sentence, targets: targets), sentence)
        }
    }

    func testDifferentRealPeopleWithSimilarNamesAreNotRewritten() {
        let targets = ["Temitope", "Yemisi", "Folasade"]
        for name in ["Temitayo", "Yemi", "Folake", "Tomiwa"] {
            let sentence = "Ask \(name) to join."
            XCTAssertEqual(corrected(sentence, targets: targets), sentence, name)
        }
    }

    func testWindowsWithStopwordsAreSkippedUnlessTheTargetContainsThem() {
        // "the" is a stopword: "the Tematope" must not become one window with it.
        XCTAssertEqual(corrected("with the Tematope team", targets: ["Temitope"]), "with the Temitope team")
        // "no" is part of the target, so the exact compound may absorb it.
        XCTAssertEqual(corrected("set no speech threshold", targets: ["noSpeechThreshold"]), "set noSpeechThreshold")
        // Real words that merely concatenate to a target (with a stopword) stay.
        XCTAssertEqual(corrected("go to gether", targets: ["Together"]), "go to gether")
    }

    func testMultiWordWindowsOfRealWordsMatchOnlyAsExactCompounds() {
        // 'finalized live transcription' is one letter off the target but every word is real.
        let sentence = "The finalized live transcription call"
        XCTAssertEqual(corrected(sentence, targets: ["finalizeLiveTranscription"]), sentence)
        XCTAssertEqual(corrected("super base", targets: ["Supabase"]), "super base")
    }

    func testAdjacentWordsAreNotSwallowed() {
        XCTAssertEqual(corrected("Tematope presented slides", targets: ["Temitope"]), "Temitope presented slides")
        XCTAssertEqual(corrected("Mitomo apps", targets: ["Meetumo"]), "Meetumo apps")
    }

    func testShortTargetsAndShortWindowsAreIgnored() {
        XCTAssertEqual(corrected("We ship with Tori", targets: ["Tauri"]), "We ship with Tori")
        XCTAssertEqual(corrected("Qen models", targets: ["Qwen"]), "Qen models")
        XCTAssertTrue(FuzzyDictionaryMatcher(targets: ["Tauri", "groq", "  "]).isEmpty)
    }

    func testCodeAndPathAdjacentWordsAreLeftAlone() {
        for text in ["mail me@Tematope.org", "open /usr/Tematope/bin", "call snake_Tematope_case", "see Tematope.com now"] {
            XCTAssertEqual(corrected(text, targets: ["Temitope"]), text)
        }
    }

    func testDifferentFirstLetterIsNeverCorrected() {
        XCTAssertEqual(corrected("Alain Rouajou wants it", targets: ["Olanrewaju"]), "Alain Rouajou wants it")
    }
}
