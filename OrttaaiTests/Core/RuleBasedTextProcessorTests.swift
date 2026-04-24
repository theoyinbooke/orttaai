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

    override func setUpWithError() throws {
        let dbQueue = try DatabaseQueue(path: ":memory:")
        db = try DatabaseManager(dbQueue: dbQueue)
        settings = AppSettings()
        settings.dictionaryEnabled = true
        settings.snippetsEnabled = true
        settings.spokenFormattingEnabled = true
        processor = RuleBasedTextProcessor(databaseManager: db, settings: settings)
    }

    override func tearDownWithError() throws {
        processor = nil
        settings = nil
        db = nil
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
}
