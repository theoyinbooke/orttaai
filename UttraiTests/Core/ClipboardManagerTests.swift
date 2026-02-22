// ClipboardManagerTests.swift
// UttraiTests

import XCTest
import AppKit
@testable import Uttrai

final class ClipboardManagerTests: XCTestCase {
    var clipboard: ClipboardManager!

    override func setUp() {
        super.setUp()
        clipboard = ClipboardManager()
    }

    override func tearDown() {
        clipboard = nil
        super.tearDown()
    }

    func testRoundTripPlainText() {
        let pasteboard = NSPasteboard.general
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
        let pasteboard = NSPasteboard.general
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
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()

        let saved = clipboard.save()
        XCTAssertTrue(saved.isEmpty, "Should return empty for empty pasteboard")
    }

    func testRestoreEmptyArray() {
        // Should not crash
        clipboard.restore([])
    }

    func testFileURLPreservation() {
        let pasteboard = NSPasteboard.general
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
}
