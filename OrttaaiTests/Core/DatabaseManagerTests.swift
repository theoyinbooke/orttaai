// DatabaseManagerTests.swift
// OrttaaiTests

import XCTest
import GRDB
@testable import Orttaai

final class DatabaseManagerTests: XCTestCase {
    var db: DatabaseManager!

    override func setUpWithError() throws {
        let dbQueue = try DatabaseQueue(path: ":memory:")
        db = try DatabaseManager(dbQueue: dbQueue)
    }

    override func tearDownWithError() throws {
        db = nil
    }

    func testInsertAndFetch() throws {
        try db.saveTranscription(
            text: "Hello world",
            appName: "TextEdit",
            recordingMs: 3000,
            processingMs: 1500,
            modelId: "openai_whisper-large-v3_turbo"
        )

        let records = try db.fetchRecent()
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.text, "Hello world")
        XCTAssertEqual(records.first?.targetAppName, "TextEdit")
    }

    func testFetchRecentOrdering() throws {
        try db.saveTranscription(
            text: "First",
            appName: "App1",
            recordingMs: 1000,
            processingMs: 500,
            modelId: "test"
        )

        // Small delay to ensure different timestamps
        try db.saveTranscription(
            text: "Second",
            appName: "App2",
            recordingMs: 2000,
            processingMs: 1000,
            modelId: "test"
        )

        let records = try db.fetchRecent()
        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(records.first?.text, "Second")
        XCTAssertEqual(records.last?.text, "First")
    }

    func testAutoPrune() throws {
        for i in 0..<510 {
            try db.saveTranscription(
                text: "Entry \(i)",
                appName: "TestApp",
                recordingMs: 1000,
                processingMs: 500,
                modelId: "test"
            )
        }

        let records = try db.fetchRecent(limit: 600)
        XCTAssertEqual(records.count, 500)
    }

    func testSearch() throws {
        try db.saveTranscription(
            text: "The quick brown fox",
            appName: "TextEdit",
            recordingMs: 3000,
            processingMs: 1500,
            modelId: "test"
        )
        try db.saveTranscription(
            text: "Hello world",
            appName: "TextEdit",
            recordingMs: 2000,
            processingMs: 1000,
            modelId: "test"
        )

        let results = try db.search(query: "fox")
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.text, "The quick brown fox")
    }

    func testDeleteAll() throws {
        for i in 0..<5 {
            try db.saveTranscription(
                text: "Entry \(i)",
                appName: "TestApp",
                recordingMs: 1000,
                processingMs: 500,
                modelId: "test"
            )
        }

        try db.deleteAll()
        let records = try db.fetchRecent()
        XCTAssertEqual(records.count, 0)
    }

    func testDeleteTranscriptionById() throws {
        try db.saveTranscription(
            text: "Delete me",
            appName: "TestApp",
            recordingMs: 1_000,
            processingMs: 500,
            modelId: "test"
        )
        let inserted = try XCTUnwrap(try db.fetchRecent().first)
        let id = try XCTUnwrap(inserted.id)

        let didDelete = try db.deleteTranscription(id: id)
        XCTAssertTrue(didDelete)

        let records = try db.fetchRecent()
        XCTAssertTrue(records.isEmpty)
    }

    func testDeleteTranscriptionReturnsFalseWhenMissing() throws {
        let didDelete = try db.deleteTranscription(id: 123_456)
        XCTAssertFalse(didDelete)
    }

    func testEmptyFetch() throws {
        let records = try db.fetchRecent()
        XCTAssertEqual(records.count, 0)
    }
}
