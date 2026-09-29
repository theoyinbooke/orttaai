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

    func testLexiconKnowsCommonModernDeveloperAndProductWords() {
        let modern = [
            "codec", "codecs", "github", "kubernetes", "postgres", "prisma", "figma", "tailwind",
            "websocket", "websockets", "codebase", "codebases", "docker", "terraform", "graphql",
            "typescript", "javascript", "firebase", "cloudflare", "stripe", "webhook", "webhooks",
            "changelog", "deployed", "deploying", "refactored", "dashboards", "middleware", "microservices",
            "ffmpeg", "bitrate", "openai", "chatgpt", "iphone", "macbook", "signup", "freemium"
        ]
        for word in modern {
            XCTAssertTrue(EnglishLexicon.isRealWord(word), word)
        }
    }

    // MARK: - Corrections

    func testNearMissNamesAreCorrectedToTheTargetSpelling() {
        let temitope = ["Temitope"]
        XCTAssertEqual(corrected("Tematope will present the metrics.", targets: temitope), "Temitope will present the metrics.")

        for variant in ["Mitumo", "Metumo"] {
            XCTAssertEqual(corrected("Ask \(variant) about it", targets: ["Meetumo"]), "Ask Meetumo about it", variant)
        }

        XCTAssertEqual(corrected("Ask Yemesi to update it", targets: ["Yemisi"]), "Ask Yemisi to update it")
    }

    func testNamesHeardWithADifferentSyllableShapeAreLeftAlone() {
        // Too far from the target to tell apart from someone else's name:
        // an extra or missing syllable, a doubled consonant, a changed ending.
        XCTAssertEqual(corrected("Owenbook asked", targets: ["Oyinbooke"]), "Owenbook asked")
        XCTAssertEqual(corrected("Taimytope will draft it.", targets: ["Temitope"]), "Taimytope will draft it.")
        XCTAssertEqual(corrected("Send it to Folosaday today", targets: ["Folasade"]), "Send it to Folosaday today")
        XCTAssertEqual(corrected("Install Olima first", targets: ["Ollama"]), "Install Olima first")
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
        XCTAssertEqual(corrected("Mitumo apps", targets: ["Meetumo"]), "Meetumo apps")
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

    // MARK: - Inflections, names, casing, documented behavior

    func testInflectedFormsOfATargetAreNeverRewrittenToTheBaseForm() {
        let cases: [(target: String, text: String)] = [
            ("WebSocket", "We use websockets a lot."),
            ("WebSocket", "Two Websockets stayed open."),
            ("Codebase", "the codebases are big"),
            ("Codebase", "the code bases are big"),
            ("Vercel", "We are vercelling it tonight."),
            ("Vercel", "The Vercels differ."),
            ("Temitope", "Both Temitopes came."),
            ("Meetumo", "Two Meetumos merged.")
        ]
        for (target, text) in cases {
            XCTAssertEqual(corrected(text, targets: [target]), text, text)
        }
    }

    func testTheBaseFormIsNotRewrittenToAnInflectedTarget() {
        let cases: [(target: String, text: String)] = [
            ("Codebases", "the codebase is big"),
            ("WebSockets", "open one websocket"),
            ("Temitopes", "ask Temitope"),
            ("Vercels", "deploy on Vercel")
        ]
        for (target, text) in cases {
            XCTAssertEqual(corrected(text, targets: [target]), text, text)
        }
    }

    func testDifferentRealPeopleAndWordsAreNotRewrittenToSimilarTargets() {
        let cases: [(target: String, names: [String])] = [
            ("Michael", ["Michelle", "Michaela", "Michele", "Michal"]),
            ("Claude", ["Claudia", "Claudio", "Cloud"]),
            ("Olamide", ["Olumide"]),
            ("Sophia", ["Sophie"]),
            ("Temitope", ["Temitayo", "Temidayo", "Yemi", "Folake", "Tomiwa", "Temitopa"]),
            ("Adebayo", ["Adebayor", "Adebayi"]),
            ("Oluwaseun", ["Oluwaseyi"]),
            ("Folasade", ["Folake", "Folasida"])
        ]
        for (target, names) in cases {
            for name in names {
                let sentence = "Ask \(name) to join."
                XCTAssertEqual(corrected(sentence, targets: [target]), sentence, "\(name) vs \(target)")
            }
        }
    }

    func testNameNearMissRulesAreVowelOnlyAndKeepEndingAndLength() {
        let corrections: [(target: String, heard: String)] = [
            ("Temitope", "Tematope"),
            ("Yemisi", "Yemesi"),
            ("Meetumo", "Mitumo"),
            ("Meetumo", "Metumo"),
            // Eight letters or more tolerate two vowel swaps.
            ("Folasade", "Folesede")
        ]
        for (target, heard) in corrections {
            XCTAssertEqual(corrected("Ask \(heard) now", targets: [target]), "Ask \(target) now", heard)
        }

        let untouched: [(target: String, heard: String)] = [
            // A vowel crossing between {a, e, i} and {o, u}, on a short target.
            ("Yemisi", "Yemosi"),
            // Two swaps on a short target.
            ("Yemisi", "Yamasi"),
            // A different last letter.
            ("Yemisi", "Yemisa"),
            ("Temitope", "Temitopa"),
            ("Folasade", "Folasida"),
            // A dropped vowel.
            ("Temitope", "Temtope"),
            // Too many edits even for a long target.
            ("Folasade", "Falisade"),
            // Different consonants.
            ("Temitope", "Temitayo")
        ]
        for (target, heard) in untouched {
            XCTAssertEqual(corrected("Ask \(heard) now", targets: [target]), "Ask \(heard) now", heard)
        }
    }

    func testBrandCasedTargetsAreRecasedEvenWhenTheLowercaseFormIsAListedWord() {
        XCTAssertTrue(EnglishLexicon.isRealWord("github"))
        XCTAssertEqual(corrected("push it to github now", targets: ["GitHub"]), "push it to GitHub now")
        XCTAssertEqual(corrected("open the websocket now", targets: ["WebSocket"]), "open the WebSocket now")
        // A plain first-letter-capitalized target is not a brand casing: the
        // ordinary word stays as spoken.
        XCTAssertEqual(corrected("the cursor blinks", targets: ["Cursor"]), "the cursor blinks")
    }

    func testExactCompoundRuleRewritesOrdinaryPhrasesThatSpellATargetOnPurpose() {
        // By design: the target is the user's own chosen spelling, so a
        // phrase that spells it letter for letter is joined to it.
        XCTAssertEqual(corrected("what is the tail wind speed", targets: ["Tailwind"]), "what is the Tailwind speed")
        XCTAssertEqual(corrected("I asked open AI about it", targets: ["OpenAI"]), "I asked OpenAI about it")
        XCTAssertEqual(corrected("go to the back end now", targets: ["Backend"]), "go to the Backend now")
    }
}
