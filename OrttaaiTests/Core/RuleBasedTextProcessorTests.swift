// RuleBasedTextProcessorTests.swift
// OrttaaiTests

import XCTest
import GRDB
@testable import Orttaai

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
}
