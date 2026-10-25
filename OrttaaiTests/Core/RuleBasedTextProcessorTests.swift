// RuleBasedTextProcessorTests.swift
// OrttaaiTests

import XCTest
import GRDB
@testable import Orttaai

@MainActor
final class RuleBasedTextProcessorTests: XCTestCase {
    private var db: DatabaseManager!
    private var settings: AppSettings!
    private var processor: RuleBasedTextProcessor!
    private var originalDefaults: [String: Any?] = [:]
    private let defaultKeysToRestore = [
        "dictionaryEnabled",
        "snippetsEnabled",
        "spokenFormattingEnabled",
        "autoParagraphsEnabled",
        "fuzzyDictionaryEnabled",
        "disfluencyCleanupEnabled",
        "dictationLanguage",
        "lowLatencyModeEnabled"
    ]

    override func setUpWithError() throws {
        originalDefaults = Dictionary(
            uniqueKeysWithValues: defaultKeysToRestore.map { key in
                (key, UserDefaults.standard.object(forKey: key))
            }
        )
        let dbQueue = try DatabaseQueue(path: ":memory:")
        db = try DatabaseManager(dbQueue: dbQueue)
        settings = AppSettings()
        settings.dictionaryEnabled = true
        settings.snippetsEnabled = true
        settings.spokenFormattingEnabled = true
        settings.autoParagraphsEnabled = true
        settings.fuzzyDictionaryEnabled = true
        settings.disfluencyCleanupEnabled = true
        settings.dictationLanguage = "en"
        // The test host shares the Debug app's defaults, where this may be on.
        settings.lowLatencyModeEnabled = false
        processor = RuleBasedTextProcessor(databaseManager: db, settings: settings)
    }

    override func tearDownWithError() throws {
        processor = nil
        settings = nil
        db = nil
        for key in defaultKeysToRestore {
            if let value = originalDefaults[key] ?? nil {
                UserDefaults.standard.set(value, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        originalDefaults = [:]
    }

    func testDictionaryReplacement() async throws {
        _ = try db.upsertDictionaryEntry(source: "whispr", target: "Wispr")

        let output = try await processor.process(
            TextProcessorInput(rawTranscript: "whispr flow", targetApp: nil, mode: .raw)
        )

        XCTAssertEqual(output.text, "Wispr flow")
        XCTAssertTrue(output.changes.contains { $0.contains("Dictionary") })
    }

    func testSnippetExpansionWithCommandPrefix() async throws {
        _ = try db.upsertSnippetEntry(
            trigger: "my email",
            expansion: "theoyinbooke@gmail.com"
        )

        let output = try await processor.process(
            TextProcessorInput(rawTranscript: "insert my email", targetApp: nil, mode: .raw)
        )

        XCTAssertEqual(output.text, "theoyinbooke@gmail.com")
        XCTAssertTrue(output.changes.contains { $0.contains("Snippet expanded") })
    }

    func testDisabledFeaturesBypassRules() async throws {
        _ = try db.upsertDictionaryEntry(source: "whispr", target: "Wispr")
        _ = try db.upsertSnippetEntry(trigger: "my email", expansion: "me@example.com")
        settings.dictionaryEnabled = false
        settings.snippetsEnabled = false

        let output = try await processor.process(
            TextProcessorInput(rawTranscript: "insert my email and whispr", targetApp: nil, mode: .raw)
        )

        XCTAssertEqual(output.text, "insert my email and whispr")
        XCTAssertTrue(output.changes.isEmpty)
    }

    func testDictionaryCacheInvalidatesAfterUpdate() async throws {
        _ = try db.upsertDictionaryEntry(source: "whispr", target: "Wispr")

        let firstOutput = try await processor.process(
            TextProcessorInput(rawTranscript: "whispr flow", targetApp: nil, mode: .raw)
        )
        XCTAssertEqual(firstOutput.text, "Wispr flow")

        let entry = try XCTUnwrap(try db.fetchDictionaryEntries().first)
        _ = try db.updateDictionaryEntry(
            id: try XCTUnwrap(entry.id),
            source: "whispr",
            target: "Whisper",
            isCaseSensitive: false,
            isActive: true
        )

        let secondOutput = try await processor.process(
            TextProcessorInput(rawTranscript: "whispr flow", targetApp: nil, mode: .raw)
        )
        XCTAssertEqual(secondOutput.text, "Whisper flow")
    }

    func testSnippetCacheInvalidatesAfterDelete() async throws {
        let entry = try db.upsertSnippetEntry(
            trigger: "my email",
            expansion: "theoyinbooke@gmail.com"
        )

        let firstOutput = try await processor.process(
            TextProcessorInput(rawTranscript: "insert my email", targetApp: nil, mode: .raw)
        )
        XCTAssertEqual(firstOutput.text, "theoyinbooke@gmail.com")

        _ = try db.deleteSnippetEntry(id: try XCTUnwrap(entry.id))

        let secondOutput = try await processor.process(
            TextProcessorInput(rawTranscript: "insert my email", targetApp: nil, mode: .raw)
        )
        XCTAssertEqual(secondOutput.text, "insert my email")
    }

    func testFormatsNumberedListFromSpokenMarkers() async throws {
        let output = try await processor.process(
            TextProcessorInput(
                rawTranscript: "number one it has to be this number two it has to be that",
                targetApp: nil,
                mode: .raw
            )
        )

        XCTAssertEqual(output.text, "1. It has to be this\n2. It has to be that")
        XCTAssertTrue(output.changes.contains("Spoken formatting: numbered list"))
    }

    private func processed(_ text: String, app: String? = nil) async throws -> TextProcessorOutput {
        try await processor.process(TextProcessorInput(rawTranscript: text, targetApp: app, mode: .raw))
    }

    func testFormatsNumberedListFromOrdinalWords() async throws {
        let output = try await processed(
            "My concerns are these. First, the cancel button should match the others. Second, we don't need the extra keys. Third, it should be pure voice."
        )
        XCTAssertEqual(
            output.text,
            "My concerns are these.\n1. The cancel button should match the others.\n2. We don't need the extra keys.\n3. It should be pure voice."
        )
    }

    /// The shape of a real Express dictation: "First, …" then "Number two, …".
    func testOrdinalAndNumberMarkersMakeOneList() async throws {
        let output = try await processed("First, fix the cancel button. Number two, remove the extra keys.")
        XCTAssertEqual(output.text, "1. Fix the cancel button.\n2. Remove the extra keys.")
    }

    /// Nothing marks the end of the last item, so a long tail after it
    /// becomes its own paragraph instead of part of item two.
    func testLongTailAfterTheLastItemBecomesAParagraph() async throws {
        let tail = "The other thing I wanted to say is that the colors feel far too loud for a keyboard"
            + " that sits under every single app you use all day long on your phone and on your iPad too."
        let output = try await processed(
            "First, fix the cancel button. Second, drop the extra keys. It should be pure voice. " + tail
        )
        XCTAssertEqual(
            output.text,
            "1. Fix the cancel button.\n2. Drop the extra keys. It should be pure voice.\n\n" + tail
        )
    }

    func testFirstlySecondlyMakeAList() async throws {
        let output = try await processed("Firstly: ship the fix. Secondly: tell the testers.")
        XCTAssertEqual(output.text, "1. Ship the fix.\n2. Tell the testers.")
    }

    func testOrdinalWordsInProseAreLeftAlone() async throws {
        for text in [
            "First, let me check the logs before we ship.",
            "This is the first time, and the second time, it worked.",
            "Wait a second, I think it is fine.",
        ] {
            let output = try await processed(text)
            XCTAssertEqual(output.text, text)
        }
    }

    private func longDictation(paragraphOpeners: [String]) -> String {
        let body = "The keyboard should feel like a regular keyboard with one big microphone in the middle."
            + " The cancel button should sit at the bottom where people expect it."
            + " Every extra control we add makes it harder to use with one hand."
        return paragraphOpeners.map { "\($0) \(body)" }.joined(separator: " ")
    }

    func testLongDictationIsSplitIntoParagraphsAtNewPoints() async throws {
        let text = longDictation(paragraphOpeners: ["Here is my take.", "Also, one more thing.", "Finally, to wrap up."])
        let output = try await processed(text)

        let paragraphs = output.text.components(separatedBy: "\n\n")
        XCTAssertEqual(paragraphs.count, 3)
        XCTAssertTrue(paragraphs[1].hasPrefix("Also, one more thing."))
        XCTAssertTrue(paragraphs[2].hasPrefix("Finally, to wrap up."))
        XCTAssertEqual(output.text.replacingOccurrences(of: "\n\n", with: " "), text, "no words change")
    }

    func testShortDictationStaysOneParagraph() async throws {
        let text = "Also, the cancel button should sit at the bottom. Finally, ship it today."
        let output = try await processed(text)
        XCTAssertEqual(output.text, text)
    }

    func testAutomaticParagraphsSkipTerminalsAndCanBeDisabled() async throws {
        let text = longDictation(paragraphOpeners: ["Here is my take.", "Also, one more thing.", "Finally, to wrap up."])
        let terminalOutput = try await processed(text, app: "Terminal")
        XCTAssertEqual(terminalOutput.text, text)

        settings.autoParagraphsEnabled = false
        let disabledOutput = try await processed(text)
        XCTAssertEqual(disabledOutput.text, text)
    }

    func testSpeakersOwnBreaksAreKept() async throws {
        let text = longDictation(paragraphOpeners: ["Here is my take.", "Also, one more thing."]) + " new paragraph Finally, done."
        let output = try await processed(text)
        XCTAssertEqual(output.text.components(separatedBy: "\n\n").count, 2, "only the spoken break")
    }

    func testFormatsNumberedListWithWhisperPunctuation() async throws {
        let output = try await processor.process(
            TextProcessorInput(
                rawTranscript: "Number one, open settings. Number two, choose audio.",
                targetApp: nil,
                mode: .raw
            )
        )

        XCTAssertEqual(output.text, "1. Open settings.\n2. Choose audio.")
        XCTAssertTrue(output.changes.contains("Spoken formatting: numbered list"))
    }

    func testFormatsInlineNumberedMarkersFromWhisper() async throws {
        let output = try await processor.process(
            TextProcessorInput(
                rawTranscript: "1. Open Settings 2. Choose Audio",
                targetApp: nil,
                mode: .raw
            )
        )

        XCTAssertEqual(output.text, "1. Open Settings\n2. Choose Audio")
        XCTAssertTrue(output.changes.contains("Spoken formatting: numbered list"))
    }

    func testFormatsInlineNumberedMarkersWithIntro() async throws {
        let output = try await processor.process(
            TextProcessorInput(
                rawTranscript: "Here are the steps 1. open settings 2. choose audio",
                targetApp: nil,
                mode: .raw
            )
        )

        XCTAssertEqual(output.text, "Here are the steps\n1. Open settings\n2. Choose audio")
        XCTAssertTrue(output.changes.contains("Spoken formatting: numbered list"))
    }

    func testFormatsNumberedListWithIntroAndDigitMarkers() async throws {
        let output = try await processor.process(
            TextProcessorInput(
                rawTranscript: "here are the steps number 1 open settings and number 2 choose audio",
                targetApp: nil,
                mode: .raw
            )
        )

        XCTAssertEqual(output.text, "here are the steps\n1. Open settings\n2. Choose audio")
    }

    func testFormatsNumberedListWithLinkingVerb() async throws {
        let output = try await processor.process(
            TextProcessorInput(
                rawTranscript: "number one is speed number two is stability",
                targetApp: nil,
                mode: .raw
            )
        )

        XCTAssertEqual(output.text, "1. Speed\n2. Stability")
    }

    func testFormattedListPreservesItemSentencePunctuation() async throws {
        let output = try await processor.process(
            TextProcessorInput(
                rawTranscript: "number one buy milk. number two wash car.",
                targetApp: nil,
                mode: .raw
            )
        )

        XCTAssertEqual(output.text, "1. Buy milk.\n2. Wash car.")
    }

    func testDoesNotFormatNumberOneInProse() async throws {
        let output = try await processor.process(
            TextProcessorInput(
                rawTranscript: "I think the number one reason is latency",
                targetApp: nil,
                mode: .raw
            )
        )

        XCTAssertEqual(output.text, "I think the number one reason is latency")
        XCTAssertFalse(output.changes.contains { $0.contains("Spoken formatting") })
    }

    func testFormatsBulletListFromRepeatedMarkers() async throws {
        let output = try await processor.process(
            TextProcessorInput(
                rawTranscript: "bullet point fast on device transcription bullet point clipboard is preserved",
                targetApp: nil,
                mode: .raw
            )
        )

        XCTAssertEqual(output.text, "- Fast on device transcription\n- Clipboard is preserved")
        XCTAssertTrue(output.changes.contains("Spoken formatting: bullet list"))
    }

    func testDoesNotFormatBulletPointInProse() async throws {
        let output = try await processor.process(
            TextProcessorInput(
                rawTranscript: "Please make the first bullet point stronger",
                targetApp: nil,
                mode: .raw
            )
        )

        XCTAssertEqual(output.text, "Please make the first bullet point stronger")
        XCTAssertFalse(output.changes.contains { $0.contains("Spoken formatting") })
    }

    func testDoesNotFormatBulletPointDefinitionAtStart() async throws {
        let output = try await processor.process(
            TextProcessorInput(
                rawTranscript: "bullet point is a phrase I might say",
                targetApp: nil,
                mode: .raw
            )
        )

        XCTAssertEqual(output.text, "bullet point is a phrase I might say")
    }

    func testSpokenFormattingCanBeDisabled() async throws {
        settings.spokenFormattingEnabled = false

        let output = try await processor.process(
            TextProcessorInput(
                rawTranscript: "number one open settings number two choose audio",
                targetApp: nil,
                mode: .raw
            )
        )

        XCTAssertEqual(output.text, "number one open settings number two choose audio")
        XCTAssertFalse(output.changes.contains { $0.contains("Spoken formatting") })
    }

    // MARK: - Line break commands

    func testNewParagraphCommandInsertsParagraphBreak() async throws {
        let output = try await processor.process(
            TextProcessorInput(
                rawTranscript: "thanks for your help new paragraph best regards John",
                targetApp: nil,
                mode: .raw
            )
        )

        XCTAssertEqual(output.text, "thanks for your help\n\nBest regards John")
        XCTAssertTrue(output.changes.contains { $0.contains("line break command") })
    }

    func testNewLineCommandConsumesSurroundingCommas() async throws {
        let output = try await processor.process(
            TextProcessorInput(
                rawTranscript: "first step done, new line, second step",
                targetApp: nil,
                mode: .raw
            )
        )

        XCTAssertEqual(output.text, "first step done\nSecond step")
    }

    func testNewParagraphKeepsSentencePunctuationBeforeBreak() async throws {
        let output = try await processor.process(
            TextProcessorInput(
                rawTranscript: "Done. New paragraph. Next section covers billing",
                targetApp: nil,
                mode: .raw
            )
        )

        XCTAssertEqual(output.text, "Done.\n\nNext section covers billing")
    }

    func testNewLineAsNounPhraseIsLeftAlone() async throws {
        let output = try await processor.process(
            TextProcessorInput(
                rawTranscript: "we are launching a new line of products this fall",
                targetApp: nil,
                mode: .raw
            )
        )

        XCTAssertEqual(output.text, "we are launching a new line of products this fall")
        XCTAssertFalse(output.changes.contains { $0.contains("line break") })
    }

    func testNewParagraphAsNounPhraseIsLeftAlone() async throws {
        let output = try await processor.process(
            TextProcessorInput(
                rawTranscript: "add a new paragraph about pricing to the doc",
                targetApp: nil,
                mode: .raw
            )
        )

        XCTAssertEqual(output.text, "add a new paragraph about pricing to the doc")
    }

    func testTrailingNewLineCommandIsDropped() async throws {
        let output = try await processor.process(
            TextProcessorInput(
                rawTranscript: "send the file new line",
                targetApp: nil,
                mode: .raw
            )
        )

        XCTAssertEqual(output.text, "send the file")
    }

    func testSingleWordNewlineIsACommand() async throws {
        let output = try await processor.process(
            TextProcessorInput(
                rawTranscript: "alpha newline beta",
                targetApp: nil,
                mode: .raw
            )
        )

        XCTAssertEqual(output.text, "alpha\nBeta")
    }

    func testLineBreakCommandsComposeWithNumberedList() async throws {
        let output = try await processor.process(
            TextProcessorInput(
                rawTranscript: "here is the plan new line number one review the budget number two send the report",
                targetApp: nil,
                mode: .raw
            )
        )

        XCTAssertEqual(output.text, "here is the plan\n1. Review the budget\n2. Send the report")
    }

    func testVocabularyBiasTermsSnapshotsActiveTargetsAndTriggers() throws {
        _ = try db.upsertDictionaryEntry(source: "olan rewaju", target: "Olanrewaju")
        _ = try db.upsertDictionaryEntry(source: "wisper kit", target: "WhisperKit")
        _ = try db.upsertDictionaryEntry(source: "old term", target: "Retired", isActive: false)
        _ = try db.upsertSnippetEntry(trigger: "my email sig", expansion: "Best,\nTheo")

        let terms = processor.vocabularyBiasTerms()

        XCTAssertTrue(terms.contains("Olanrewaju"))
        XCTAssertTrue(terms.contains("WhisperKit"))
        XCTAssertTrue(terms.contains("my email sig"))
        XCTAssertFalse(terms.contains("Retired"), "inactive entries must not bias decoding")
        XCTAssertFalse(terms.contains("Best,\nTheo"), "expansions are typed, not spoken — only triggers bias")
    }

    // MARK: - Fuzzy dictionary

    private func process(_ text: String) async throws -> TextProcessorOutput {
        try await processor.process(TextProcessorInput(rawTranscript: text, targetApp: nil, mode: .raw))
    }

    func testFuzzyDictionaryCorrectsNearMissOfTargetWithoutBumpingUsage() async throws {
        _ = try db.upsertDictionaryEntry(source: "temi tope", target: "Temitope")

        let output = try await process("Tematope will present today")

        XCTAssertEqual(output.text, "Temitope will present today")
        XCTAssertTrue(output.changes.contains("Dictionary (fuzzy): 'Tematope' -> 'Temitope'"))
        let entry = try XCTUnwrap(try db.fetchDictionaryEntries().first)
        XCTAssertEqual(entry.usageCount, 0, "fuzzy hits must not feed the bias prompt ordering")
    }

    func testExactRowsRunBeforeFuzzyMatching() async throws {
        _ = try db.upsertDictionaryEntry(source: "mitumor", target: "Meetumo")

        let output = try await process("mitumor and Mitumo")

        XCTAssertEqual(output.text, "Meetumo and Meetumo")
        XCTAssertEqual(output.changes.filter { $0.hasPrefix("Dictionary:") }.count, 1)
        XCTAssertEqual(output.changes.filter { $0.hasPrefix("Dictionary (fuzzy):") }.count, 1)
        let entry = try XCTUnwrap(try db.fetchDictionaryEntries().first)
        XCTAssertEqual(entry.usageCount, 1, "only the literal hit counts")
    }

    func testFuzzyDictionaryLeavesRealWordsAlone() async throws {
        _ = try db.upsertDictionaryEntry(source: "vasel", target: "Vercel")
        _ = try db.upsertDictionaryEntry(source: "mitumor", target: "Meetumo")

        let output = try await process("The verse fits the meetup")

        XCTAssertEqual(output.text, "The verse fits the meetup")
        XCTAssertTrue(output.changes.isEmpty)
    }

    func testFuzzyDictionaryCanBeDisabled() async throws {
        _ = try db.upsertDictionaryEntry(source: "temi tope", target: "Temitope")
        settings.fuzzyDictionaryEnabled = false

        let output = try await process("Tematope will present")

        XCTAssertEqual(output.text, "Tematope will present")
    }

    func testFuzzyDictionaryFollowsDictionaryChanges() async throws {
        _ = try db.upsertDictionaryEntry(source: "temi tope", target: "Temitope")
        let first = try await process("Tematope")
        XCTAssertEqual(first.text, "Temitope")

        let entry = try XCTUnwrap(try db.fetchDictionaryEntries().first)
        _ = try db.deleteDictionaryEntry(id: try XCTUnwrap(entry.id))

        let second = try await process("Tematope")
        XCTAssertEqual(second.text, "Tematope")
    }

    func testDisabledDictionaryDisablesFuzzyMatchingToo() async throws {
        _ = try db.upsertDictionaryEntry(source: "temi tope", target: "Temitope")
        settings.dictionaryEnabled = false

        let output = try await process("Tematope will present")

        XCTAssertEqual(output.text, "Tematope will present")
    }

    func testFuzzyDictionarySkipsNonEnglishDictation() async throws {
        _ = try db.upsertDictionaryEntry(source: "temi tope", target: "Temitope")

        for language in ["es", "fr", "auto"] {
            settings.dictationLanguage = language
            let output = try await process("Tematope will present")
            XCTAssertEqual(output.text, "Tematope will present", language)
            XCTAssertFalse(output.changes.contains { $0.hasPrefix("Dictionary (fuzzy)") }, language)
        }
    }

    func testFuzzyDictionaryRunsForAutoLanguageWhenLowLatencyModeForcesEnglish() async throws {
        _ = try db.upsertDictionaryEntry(source: "temi tope", target: "Temitope")
        settings.dictationLanguage = "auto"
        settings.lowLatencyModeEnabled = true

        let output = try await process("Tematope will present")

        XCTAssertEqual(output.text, "Temitope will present")
    }

    func testFuzzyDictionaryKeepsInflectedFormsAndSimilarNamesIntact() async throws {
        _ = try db.upsertDictionaryEntry(source: "web socket", target: "WebSocket")
        _ = try db.upsertDictionaryEntry(source: "michael s", target: "Michael")

        let output = try await process("We use websockets and ask Michelle or Michaela.")

        XCTAssertEqual(output.text, "We use websockets and ask Michelle or Michaela.")
    }

    // MARK: - Disfluency cleanup

    func testDisfluencyCleanupRunsInTheProcessor() async throws {
        let output = try await process("so um um to avoid the the memory i think")

        XCTAssertEqual(output.text, "so to avoid the memory I think")
        XCTAssertTrue(output.changes.contains("Disfluency: removed 2 fillers"))
    }

    func testFillerBeforeLineBreakCommandStillProducesTheBreak() async throws {
        let output = try await process("Send the report, um, new line best regards")

        XCTAssertEqual(output.text, "Send the report\nBest regards")
    }

    func testFillerAfterLineBreakCommandStillProducesTheBreak() async throws {
        let output = try await process("Send the report new line um best regards")

        XCTAssertEqual(output.text, "Send the report\nBest regards")
    }

    func testDisfluencyCleanupCanBeDisabled() async throws {
        settings.disfluencyCleanupEnabled = false

        let output = try await process("so um the the plan i think")

        XCTAssertEqual(output.text, "so um the the plan i think")
    }

    func testDisfluencyCleanupSkipsNonEnglishDictation() async throws {
        settings.dictationLanguage = "es"

        let output = try await process("voy a a la tienda")

        XCTAssertEqual(output.text, "voy a a la tienda")
    }

    func testSnippetExpansionIsNeverCleaned() async throws {
        _ = try db.upsertSnippetEntry(trigger: "my sig", expansion: "um the the plan i think")

        let output = try await process("insert my sig")

        XCTAssertEqual(output.text, "um the the plan i think")
        XCTAssertFalse(output.changes.contains { $0.hasPrefix("Disfluency") })
    }
}
