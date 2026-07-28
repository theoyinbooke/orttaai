// SelectionCaptureServiceTests.swift
// OrttaaiTests

import XCTest
@testable import Orttaai

/// Drives the real selection-capture decision logic (AX read first,
/// Cmd+C-into-saved-clipboard fallback, no-selection nil) through the C4
/// protocol seams, without live AX or the system pasteboard.
final class SelectionCaptureServiceTests: XCTestCase {
    private var inspector: MockAccessibilityInspector!
    private var clipboard: MockClipboard!
    private var keyPoster: MockKeyEventPoster!
    private var service: SelectionCaptureService!

    override func setUp() {
        super.setUp()
        inspector = MockAccessibilityInspector()
        clipboard = MockClipboard()
        keyPoster = MockKeyEventPoster()
        service = SelectionCaptureService(inspector: inspector, clipboard: clipboard, keyPoster: keyPoster)
    }

    func testAXSelectedTextWinsWithoutTouchingClipboard() async {
        inspector.simulatedSelectedText = "the selected words"

        let captured = await service.captureSelection(processIdentifier: 123)

        XCTAssertEqual(captured, .captured(CapturedSelection(text: "the selected words", method: .axRead)))
        XCTAssertEqual(clipboard.saveCount, 0, "AX success must not disturb the clipboard")
        XCTAssertEqual(keyPoster.copyChordCount, 0)
    }

    func testEmptyAXSelectionFallsBackToClipboardCopy() async {
        inspector.simulatedSelectedText = "   " // whitespace-only reads as no selection
        clipboard.savedItemsToReturn = []
        keyPoster.onCopyChord = { [clipboard] _ in
            // Simulate the target app committing the copy.
            clipboard?.stringToReturn = "copied selection"
            clipboard?.changeCount += 1
        }

        let captured = await service.captureSelection(processIdentifier: 123)

        XCTAssertEqual(captured, .captured(CapturedSelection(text: "copied selection", method: .clipboardCopy)))
        XCTAssertEqual(keyPoster.copyChordCount, 1)
        XCTAssertEqual(clipboard.saveCount, 1, "Original clipboard must be saved before the synthetic copy")
        XCTAssertEqual(clipboard.restoreCount, 1, "Original clipboard must be restored after the read")
    }

    func testAXErrorFallsBackToClipboardCopy() async {
        inspector.snapshotErrors = true
        keyPoster.onCopyChord = { [clipboard] _ in
            clipboard?.stringToReturn = "terminal selection"
            clipboard?.changeCount += 1
        }

        let captured = await service.captureSelection(processIdentifier: 123)

        XCTAssertEqual(captured, .captured(CapturedSelection(text: "terminal selection", method: .clipboardCopy)))
        XCTAssertEqual(clipboard.restoreCount, 1)
    }

    func testNoSelectionAnywhereReturnsNoSelection() async {
        inspector.simulatedSelectedText = nil
        // Cmd+C lands nowhere: the change counter never bumps.

        let captured = await service.captureSelection(processIdentifier: 123)

        XCTAssertEqual(captured, .noSelection)
        XCTAssertEqual(keyPoster.copyChordCount, 1, "The fallback copy is still attempted")
        XCTAssertEqual(clipboard.restoreCount, 1, "Clipboard is restored even when nothing was copied")
    }

    func testCopyProducingWhitespaceCountsAsNoSelection() async {
        inspector.simulatedSelectedText = nil
        keyPoster.onCopyChord = { [clipboard] _ in
            clipboard?.stringToReturn = "  \n "
            clipboard?.changeCount += 1
        }

        let captured = await service.captureSelection(processIdentifier: 123)

        XCTAssertEqual(captured, .noSelection)
        XCTAssertEqual(clipboard.restoreCount, 1)
    }

    // MARK: - Secure-field guard at capture time

    func testSecureFieldBlocksCaptureBeforeAnyRead() async {
        inspector.detailsResult = .value(FocusedElementDetails(
            role: kAXTextFieldRole as String,
            subrole: kAXSecureTextFieldSubrole as String,
            roleDescription: "secure text field"
        ))
        inspector.simulatedSelectedText = "hunter2"

        let captured = await service.captureSelection(processIdentifier: 123)

        XCTAssertEqual(captured, .blockedSecureField)
        XCTAssertEqual(inspector.snapshotReadCount, 0, "A secure field's text must never be read")
        XCTAssertEqual(keyPoster.copyChordCount, 0, "No synthetic copy may run on a secure field")
        XCTAssertEqual(clipboard.saveCount, 0)
    }

    func testAXErrorOnDetailsFailsOpenMatchingInjectionPolicy() async {
        inspector.detailsResult = .axError
        inspector.simulatedSelectedText = "normal selection"

        let captured = await service.captureSelection(processIdentifier: 123)

        XCTAssertEqual(captured, .captured(CapturedSelection(text: "normal selection", method: .axRead)))
    }
}
