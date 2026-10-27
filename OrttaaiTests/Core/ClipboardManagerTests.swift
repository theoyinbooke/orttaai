// ClipboardManagerTests.swift
// OrttaaiTests

import XCTest
import AppKit
@testable import Orttaai

final class ClipboardManagerTests: XCTestCase {
    /// A private pasteboard per test, so running them never touches the
    /// system clipboard.
    var pasteboard: NSPasteboard!
    var clipboard: ClipboardManager!

    override func setUp() {
        super.setUp()
        pasteboard = NSPasteboard(name: NSPasteboard.Name("com.orttaai.tests.\(UUID().uuidString)"))
        clipboard = ClipboardManager(pasteboard: pasteboard)
    }

    override func tearDown() {
        pasteboard.releaseGlobally()
        clipboard = nil
        pasteboard = nil
        super.tearDown()
    }

    func testRoundTripPlainText() {
        pasteboard.clearContents()
        pasteboard.setString("Test clipboard content", forType: .string)

        let saved = clipboard.save()
        XCTAssertFalse(saved.isEmpty, "Should save at least one item")

        // Clear and verify it's gone
        pasteboard.clearContents()
        XCTAssertNil(pasteboard.string(forType: .string))

        // Restore and verify
        clipboard.restore(saved)
        XCTAssertEqual(pasteboard.string(forType: .string), "Test clipboard content")
    }

    func testRoundTripMultipleTypes() {
        pasteboard.clearContents()

        let item = NSPasteboardItem()
        item.setString("Plain text", forType: .string)
        let rtfData = "RTF data".data(using: .utf8)!
        item.setData(rtfData, forType: .rtf)
        pasteboard.writeObjects([item])

        let saved = clipboard.save()
        XCTAssertFalse(saved.isEmpty)

        pasteboard.clearContents()
        clipboard.restore(saved)

        XCTAssertEqual(pasteboard.string(forType: .string), "Plain text")
        XCTAssertNotNil(pasteboard.data(forType: .rtf))
    }

    func testSaveEmptyPasteboard() {
        pasteboard.clearContents()

        let saved = clipboard.save()
        XCTAssertTrue(saved.isEmpty, "Should return empty for empty pasteboard")
    }

    func testRestoreEmptyArray() {
        // Should not crash
        clipboard.restore([])
    }

    func testFileURLPreservation() {
        pasteboard.clearContents()

        let tempURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("test-file.txt")
        try? "test".write(to: tempURL, atomically: true, encoding: .utf8)

        pasteboard.writeObjects([tempURL as NSURL])

        let saved = clipboard.save()
        pasteboard.clearContents()
        clipboard.restore(saved)

        // Verify some data was restored (URL types may vary)
        XCTAssertFalse(saved.isEmpty)

        // Cleanup
        try? FileManager.default.removeItem(at: tempURL)
    }

    func testStagedStringStaysOnItsOwnPasteboard() {
        clipboard.setString("Hello world")

        XCTAssertEqual(clipboard.getString(), "Hello world")
        XCTAssertEqual(pasteboard.string(forType: .string), "Hello world")
    }

    @MainActor
    func testSaveGivesUpWhenReadingTheClipboardIsSlow() async {
        // As when the clipboard holds an item copied on an iPhone that
        // doesn't answer: macOS waits 20 s before giving up on it.
        let slow = ClipboardManager(pasteboard: pasteboard, readItems: {
            Thread.sleep(forTimeInterval: 1.5)
            return []
        })
        let started = ContinuousClock.now

        let saved = await slow.save(giveUpAfterMs: 100)

        XCTAssertNil(saved)
        XCTAssertLessThan(started.duration(to: .now), .seconds(1), "the paste must not wait for the slow read")
    }

    @MainActor
    func testSaveReturnsTheClipboardWhenReadingIsQuick() async {
        pasteboard.clearContents()
        pasteboard.setString("kept", forType: .string)

        let saved = await clipboard.save(giveUpAfterMs: ClipboardManager.saveLimitMs)

        XCTAssertEqual(saved?.first?.dataByType[.string], Data("kept".utf8))
    }
}
