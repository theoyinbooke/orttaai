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

    func testCopyGoesAheadWhenSavingTheClipboardTakesTooLong() async {
        inspector.snapshotErrors = true
        clipboard.saveGivesUp = true
        keyPoster.onCopyChord = { [clipboard] _ in
            clipboard?.stringToReturn = "copied selection"
            clipboard?.changeCount += 1
        }

        let captured = await service.captureSelection(processIdentifier: 123)

        XCTAssertEqual(captured, .captured(CapturedSelection(text: "copied selection", method: .clipboardCopy)))
        XCTAssertEqual(clipboard.restoreCount, 0, "nothing was saved to restore")
        XCTAssertEqual(clipboard.stringToReturn, "copied selection", "the copied selection stays on the clipboard")
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

    func testCodeEditorLineCopyIsNotASelection() async {
        // VS Code copies the current line when ⌘C finds nothing selected.
        inspector.snapshotErrors = true
        keyPoster.onCopyChord = { [clipboard] _ in
            clipboard?.stringToReturn = "let total = items.count\n"
            clipboard?.copyIsFromEmptySelection = true
            clipboard?.changeCount += 1
        }

        let captured = await service.captureSelection(processIdentifier: 123)

        XCTAssertEqual(captured, .noSelection)
        XCTAssertEqual(clipboard.restoreCount, 1, "The clipboard is still restored")
    }

    func testVSCodeMarkerIsFoundInEitherEncoding() {
        let json = #"{"version":1,"isFromEmptySelection":true,"multicursorText":null,"mode":"swift"}"#
        XCTAssertTrue(ClipboardManager.marksEmptySelection(Data(json.utf8)))
        XCTAssertTrue(ClipboardManager.marksEmptySelection(json.data(using: .utf16LittleEndian)!))

        let selected = #"{"version":1,"isFromEmptySelection":false,"mode":"swift"}"#
        XCTAssertFalse(ClipboardManager.marksEmptySelection(Data(selected.utf8)))
        XCTAssertFalse(ClipboardManager.marksEmptySelection(Data("plain text".utf8)))
    }

    func testRealPasteboardWithEditorMetadata() {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("orttaai-test-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        let manager = ClipboardManager(pasteboard: pasteboard)

        pasteboard.clearContents()
        // Chromium's custom-data type: a binary header, then the MIME type
        // and its value as UTF-16.
        var custom = Data([0x50, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00])
        custom.append("vscode-editor-data".data(using: .utf16LittleEndian)!)
        custom.append(#"{"version":1,"isFromEmptySelection":true}"#.data(using: .utf16LittleEndian)!)
        let item = NSPasteboardItem()
        item.setString("let total = items.count\n", forType: .string)
        XCTAssertTrue(item.setData(custom, forType: NSPasteboard.PasteboardType("org.chromium.web-custom-data")))
        pasteboard.writeObjects([item])
        XCTAssertTrue(manager.copiedFromEmptySelection())

        pasteboard.clearContents()
        pasteboard.setString("selected words", forType: .string)
        XCTAssertFalse(manager.copiedFromEmptySelection(), "An ordinary copy is a selection")
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

    // MARK: - Peek (dictation shortcut)

    func testPeekReadsTheSelectionWithoutTouchingTheClipboard() async {
        inspector.simulatedSelectedText = "the selected words"

        let peeked = await service.peekSelection(processIdentifier: 123)

        XCTAssertEqual(peeked, .captured(CapturedSelection(text: "the selected words", method: .axRead)))
        XCTAssertEqual(keyPoster.copyChordCount, 0)
        XCTAssertEqual(clipboard.saveCount, 0)
    }

    func testPeekWithNothingSelectedNeverCopies() async {
        inspector.simulatedSelectedText = nil

        let peeked = await service.peekSelection(processIdentifier: 123)

        XCTAssertEqual(peeked, .noSelection)
        XCTAssertEqual(keyPoster.copyChordCount, 0, "Every dictation peeks, so it must never press Cmd+C")
    }

    func testPeekIgnoresAOneLineField() async {
        // An address bar selects its URL when clicked.
        inspector.detailsResult = .value(FocusedElementDetails(role: kAXTextFieldRole as String))
        inspector.simulatedSelectedText = "https://example.com"

        let peeked = await service.peekSelection(processIdentifier: 123)

        XCTAssertEqual(peeked, .noSelection)
    }

    func testPeekReadsATextArea() async {
        inspector.detailsResult = .value(FocusedElementDetails(role: kAXTextAreaRole as String))
        inspector.simulatedSelectedText = "a paragraph"

        let peeked = await service.peekSelection(processIdentifier: 123)

        XCTAssertEqual(peeked, .captured(CapturedSelection(text: "a paragraph", method: .axRead)))
    }

    func testStillSelectedComparesTheCurrentSelection() async {
        inspector.simulatedSelectedText = "the words"
        let same = await service.isStillSelected(" the words ", processIdentifier: 123)
        XCTAssertTrue(same)

        inspector.simulatedSelectedText = ""
        let gone = await service.isStillSelected("the words", processIdentifier: 123)
        XCTAssertFalse(gone)

        inspector.snapshotErrors = true
        let unreadable = await service.isStillSelected("the words", processIdentifier: 123)
        XCTAssertTrue(unreadable, "Unreadable is no new information")
    }

    func testPeekNeverReadsASecureField() async {
        inspector.detailsResult = .value(FocusedElementDetails(
            role: kAXTextFieldRole as String,
            subrole: kAXSecureTextFieldSubrole as String,
            roleDescription: "secure text field"
        ))
        inspector.simulatedSelectedText = "hunter2"

        let peeked = await service.peekSelection(processIdentifier: 123)

        XCTAssertEqual(peeked, .blockedSecureField)
        XCTAssertEqual(inspector.snapshotReadCount, 0)
    }

    // MARK: - Selecting the last dictation

    func testLastDictationIsFoundAndSelected() async {
        inspector.simulatedFieldValue = "Hi Sam. See you on Monday. See you on Monday."
        inspector.simulatedSelectedRange = FocusedTextRange(location: 45, length: 0)

        let selected = await service.selectInsertedText(" See you on Monday. ", processIdentifier: 123)

        XCTAssertEqual(selected, .captured(CapturedSelection(text: "See you on Monday.", method: .lastInsertion)))
        XCTAssertEqual(
            inspector.selectedRanges,
            [FocusedTextRange(location: 27, length: 18)],
            "The most recent copy is the one selected"
        )
    }

    func testCopyNearestBeforeTheCaretIsChosen() {
        // "OK." dictated in the middle; another "OK." further down.
        let field = "Intro. OK. Middle text. OK. End."
        let caretAfterFirst = 10
        XCTAssertEqual(
            SelectionCaptureService.locateInsertedText("OK.", in: field, caretUTF16: caretAfterFirst),
            NSRange(location: 7, length: 3)
        )
    }

    func testSeveralCopiesAfterTheCaretAreNotGuessed() {
        let field = "OK. and OK."
        XCTAssertNil(SelectionCaptureService.locateInsertedText("OK.", in: field, caretUTF16: 0))
        XCTAssertEqual(
            SelectionCaptureService.locateInsertedText("and", in: field, caretUTF16: 0),
            NSRange(location: 4, length: 3),
            "A single copy is trusted wherever the caret is"
        )
    }

    func testEmojiAndAccentsUseTheFieldsUnits() {
        let field = "Café 👋 See you."
        let found = SelectionCaptureService.locateInsertedText("See you.", in: field, caretUTF16: (field as NSString).length)
        XCTAssertEqual(found, (field as NSString).range(of: "See you."))
    }

    func testDeselectPutsTheCaretAfterTheText() async {
        inspector.simulatedFieldValue = "Hi. See you on Monday."
        inspector.simulatedSelectedText = "See you on Monday."
        inspector.simulatedSelectedRange = FocusedTextRange(location: 4, length: 18)

        await service.deselectInsertedText("See you on Monday.", processIdentifier: 123)

        XCTAssertEqual(inspector.selectedRanges, [FocusedTextRange(location: 22, length: 0)])
    }

    func testDeselectLeavesAnotherSelectionAlone() async {
        inspector.simulatedFieldValue = "Hi. See you on Monday."
        inspector.simulatedSelectedText = "Hi."
        inspector.simulatedSelectedRange = FocusedTextRange(location: 0, length: 3)

        await service.deselectInsertedText("See you on Monday.", processIdentifier: 123)

        XCTAssertTrue(inspector.selectedRanges.isEmpty, "The person's own selection is never touched")
    }

    func testLastDictationNoLongerInTheFieldIsNotSelected() async {
        inspector.simulatedFieldValue = "Something else entirely"

        let selected = await service.selectInsertedText("See you on Monday.", processIdentifier: 123)

        XCTAssertEqual(selected, .noSelection)
        XCTAssertTrue(inspector.selectedRanges.isEmpty)
    }

    func testUnreadableFieldIsNotSelected() async {
        inspector.snapshotErrors = true

        let selected = await service.selectInsertedText("See you on Monday.", processIdentifier: 123)

        XCTAssertEqual(selected, .noSelection)
    }

    func testSelectionTheAppDoesNotShowIsNotTrustedAndTheCaretGoesBack() async {
        inspector.simulatedFieldValue = "See you on Monday."
        inspector.simulatedSelectedRange = FocusedTextRange(location: 18, length: 0)
        inspector.selectionTakesEffect = false

        let selected = await service.selectInsertedText("See you on Monday.", processIdentifier: 123)

        XCTAssertEqual(selected, .noSelection, "An edit is pasted over the selection, so it must be confirmed")
        XCTAssertEqual(inspector.selectedRanges.last, FocusedTextRange(location: 18, length: 0))
    }

    func testLastDictationInASecureFieldIsNeverRead() async {
        inspector.detailsResult = .value(FocusedElementDetails(
            role: kAXTextFieldRole as String,
            subrole: kAXSecureTextFieldSubrole as String,
            roleDescription: "secure text field"
        ))
        inspector.simulatedFieldValue = "hunter2"

        let selected = await service.selectInsertedText("hunter2", processIdentifier: 123)

        XCTAssertEqual(selected, .blockedSecureField)
        XCTAssertEqual(inspector.snapshotReadCount, 0)
    }

    func testAXErrorOnDetailsFailsOpenMatchingInjectionPolicy() async {
        inspector.detailsResult = .axError
        inspector.simulatedSelectedText = "normal selection"

        let captured = await service.captureSelection(processIdentifier: 123)

        XCTAssertEqual(captured, .captured(CapturedSelection(text: "normal selection", method: .axRead)))
    }
}
