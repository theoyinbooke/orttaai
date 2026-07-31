// TextInjectionServiceTests.swift
// OrttaaiTests

import XCTest
@testable import Orttaai

// MARK: - Mocks

/// Scripted AX inspector so tests drive TextInjectionService's real
/// secure-field and verification decision logic without live AX calls.
final class MockAccessibilityInspector: AccessibilityInspecting {
    var detailsResult: AXInspection<FocusedElementDetails> = .axError

    /// Simulated focused-element text; snapshot reads reflect this.
    var simulatedFieldValue: String?
    var simulatedSelectedText: String?
    /// Simulated kAXSelectedTextRangeAttribute (caret when length == 0).
    var simulatedSelectedRange: FocusedTextRange?
    /// When true, snapshot reads report an AX API failure.
    var snapshotErrors = false
    /// When true, the element exposes no value/selectedText attributes.
    var fieldExposesNoText = false

    var insertResult = false
    /// Runs when insertTextAtFocus is called (simulate the insert landing).
    var onInsert: ((String) -> Void)?

    private(set) var insertedTexts: [String] = []
    private(set) var snapshotReadCount = 0

    func focusedElementDetails(processIdentifier: pid_t?) -> AXInspection<FocusedElementDetails> {
        detailsResult
    }

    func focusedElementTextSnapshot(processIdentifier: pid_t?) -> AXInspection<FocusedTextSnapshot> {
        snapshotReadCount += 1
        if snapshotErrors {
            return .axError
        }
        if fieldExposesNoText {
            return .value(FocusedTextSnapshot(value: nil, selectedText: nil))
        }
        return .value(FocusedTextSnapshot(
            value: simulatedFieldValue,
            selectedText: simulatedSelectedText,
            selectedRange: simulatedSelectedRange
        ))
    }

    func insertTextAtFocus(_ text: String, processIdentifier: pid_t?) -> Bool {
        insertedTexts.append(text)
        if insertResult {
            onInsert?(text)
        }
        return insertResult
    }
}

final class MockKeyEventPoster: KeyEventPosting {
    private(set) var pasteChordCount = 0
    private(set) var copyChordCount = 0
    private(set) var typedTexts: [String] = []
    private(set) var backspaceCounts: [Int] = []
    var onBackspaces: ((Int) -> Void)?
    /// Runs on each paste chord with the 1-based attempt number.
    var onPasteChord: ((Int) -> Void)?
    /// Runs on each copy chord with the 1-based attempt number.
    var onCopyChord: ((Int) -> Void)?
    var onTypedText: ((String) -> Void)?

    func postPasteChord() {
        pasteChordCount += 1
        onPasteChord?(pasteChordCount)
    }

    func postCopyChord() {
        copyChordCount += 1
        onCopyChord?(copyChordCount)
    }

    func postTypedText(_ text: String) {
        typedTexts.append(text)
        onTypedText?(text)
    }

    func postBackspaces(count: Int) {
        backspaceCounts.append(count)
        onBackspaces?(count)
    }
}

final class MockClipboard: ClipboardManaging {
    var savedItemsToReturn: [ClipboardManager.SavedItem] = []
    private(set) var saveCount = 0
    private(set) var restoreCount = 0
    private(set) var setStrings: [String] = []
    /// Simulated plain-string contents and change counter (bumped by
    /// setString and by tests simulating an app's Cmd+C landing).
    var stringToReturn: String?
    var restoredStringToReturn: String?
    var changeCount: Int = 0

    func save() -> [ClipboardManager.SavedItem] {
        saveCount += 1
        return savedItemsToReturn
    }

    func restore(_ savedItems: [ClipboardManager.SavedItem]) {
        restoreCount += 1
        stringToReturn = restoredStringToReturn
        changeCount += 1
    }

    func setString(_ string: String) {
        setStrings.append(string)
        stringToReturn = string
        changeCount += 1
    }

    func getString() -> String? {
        stringToReturn
    }
}

// MARK: - Fixtures

private func normalDetails() -> AXInspection<FocusedElementDetails> {
    .value(FocusedElementDetails(role: "AXTextField", subrole: nil, roleDescription: "text field"))
}

private func secureDetails() -> AXInspection<FocusedElementDetails> {
    .value(FocusedElementDetails(role: "AXTextField", subrole: "AXSecureTextField", roleDescription: "secure text field"))
}

// MARK: - Tests

final class TextInjectionServiceTests: XCTestCase {
    private var inspector: MockAccessibilityInspector!
    private var keyPoster: MockKeyEventPoster!
    private var clipboard: MockClipboard!
    private var service: TextInjectionService!

    override func setUp() {
        super.setUp()
        inspector = MockAccessibilityInspector()
        keyPoster = MockKeyEventPoster()
        clipboard = MockClipboard()
        service = TextInjectionService(
            clipboard: clipboard,
            inspector: inspector,
            keyPoster: keyPoster,
            unverifiedPastePolicy: { _ in .assumeDeliveredAndRestoreClipboard }
        )
        service.lowLatencyModeEnabled = true // keep test waits short
    }

    // MARK: Secure-field policy matrix (real decision logic)

    func testSecurePolicyAXErrorFailsOpen() {
        XCTAssertEqual(TextInjectionService.assessSecureField(.axError), .allowedAXError)
    }

    func testSecurePolicySecureSubroleBlocks() {
        let details = FocusedElementDetails(role: "AXTextField", subrole: "AXSecureTextField", roleDescription: nil)
        XCTAssertEqual(TextInjectionService.assessSecureField(.value(details)), .blocked)
    }

    func testSecurePolicySecureSubroleBlocksRegardlessOfRole() {
        // Chromium can expose non-AXTextField roles for web password inputs.
        let details = FocusedElementDetails(role: "AXGroup", subrole: "AXSecureTextField", roleDescription: nil)
        XCTAssertEqual(TextInjectionService.assessSecureField(.value(details)), .blocked)
    }

    func testSecurePolicyPasswordRoleDescriptionBlocks() {
        let details = FocusedElementDetails(role: "AXTextField", subrole: nil, roleDescription: "Password field")
        XCTAssertEqual(TextInjectionService.assessSecureField(.value(details)), .blocked)
    }

    func testSecurePolicySecureRoleDescriptionBlocks() {
        let details = FocusedElementDetails(role: "AXTextField", subrole: nil, roleDescription: "secure text field")
        XCTAssertEqual(TextInjectionService.assessSecureField(.value(details)), .blocked)
    }

    func testSecurePolicyNormalFieldAllows() {
        let details = FocusedElementDetails(role: "AXTextField", subrole: nil, roleDescription: "text field")
        XCTAssertEqual(TextInjectionService.assessSecureField(.value(details)), .allowedInspectedNormal)
    }

    func testSecurePolicyNormalTextAreaAllows() {
        let details = FocusedElementDetails(role: "AXTextArea", subrole: nil, roleDescription: "text entry area")
        XCTAssertEqual(TextInjectionService.assessSecureField(.value(details)), .allowedInspectedNormal)
    }

    func testInjectBlockedOnInspectedSecureField() async {
        inspector.detailsResult = secureDetails()

        let result = await service.inject(text: "hunter2")

        XCTAssertEqual(result, .blockedSecureField)
        XCTAssertTrue(clipboard.setStrings.isEmpty, "Blocked injection must not touch the clipboard")
        XCTAssertEqual(keyPoster.pasteChordCount, 0)
    }

    func testInjectProceedsWhenAXErrorsOnSecureCheck() async {
        // AX API failure => fail open, matching historical behavior.
        inspector.detailsResult = .axError
        inspector.snapshotErrors = true // verification inconclusive => assume success

        let result = await service.inject(text: "Hello world")

        XCTAssertEqual(result, .success(method: .paste))
    }

    // MARK: Paste verification matrix (real decision logic)

    func testVerificationPostAXErrorIsInconclusive() {
        let outcome = TextInjectionService.evaluatePasteVerification(
            pre: .value(FocusedTextSnapshot(value: "", selectedText: nil)),
            post: .axError,
            expectedText: "hello"
        )
        XCTAssertEqual(outcome, .inconclusive)
    }

    func testVerificationNoTextAttributesIsInconclusive() {
        let outcome = TextInjectionService.evaluatePasteVerification(
            pre: .value(FocusedTextSnapshot(value: nil, selectedText: nil)),
            post: .value(FocusedTextSnapshot(value: nil, selectedText: nil)),
            expectedText: "hello"
        )
        XCTAssertEqual(outcome, .inconclusive)
    }

    func testVerificationValueContainingTextConfirms() {
        let outcome = TextInjectionService.evaluatePasteVerification(
            pre: .value(FocusedTextSnapshot(value: "note: ", selectedText: nil)),
            post: .value(FocusedTextSnapshot(value: "note: hello world", selectedText: nil)),
            expectedText: "hello world"
        )
        XCTAssertEqual(outcome, .confirmed)
    }

    func testVerificationEmptyStringExposureIsInconclusive() {
        // Regression (cmux/Ghostty): the terminal's AX element reports "" for
        // value even after the paste lands inside the running TUI. Treating
        // "" as judgeable evidence double-pasted and fired an AX insert that
        // selected the entire terminal screen.
        let outcome = TextInjectionService.evaluatePasteVerification(
            pre: .value(FocusedTextSnapshot(value: "", selectedText: nil)),
            post: .value(FocusedTextSnapshot(value: "", selectedText: "")),
            expectedText: "hello world"
        )
        XCTAssertEqual(outcome, .inconclusive)
    }

    func testVerificationUnchangedValueWithoutTextFails() {
        let outcome = TextInjectionService.evaluatePasteVerification(
            pre: .value(FocusedTextSnapshot(value: "unchanged", selectedText: nil)),
            post: .value(FocusedTextSnapshot(value: "unchanged", selectedText: nil)),
            expectedText: "hello world"
        )
        XCTAssertEqual(outcome, .failed)
    }

    func testVerificationChangedValueWithoutMarkerConfirms() {
        // Apps may transform pasted text; a changed field must not trigger
        // duplicate-inserting fallbacks.
        let outcome = TextInjectionService.evaluatePasteVerification(
            pre: .value(FocusedTextSnapshot(value: "a", selectedText: nil)),
            post: .value(FocusedTextSnapshot(value: "a HELLO WORLD", selectedText: nil)),
            expectedText: "hello world"
        )
        XCTAssertEqual(outcome, .confirmed)
    }

    func testVerificationWithoutPreBaselineIsInconclusive() {
        let outcome = TextInjectionService.evaluatePasteVerification(
            pre: .axError,
            post: .value(FocusedTextSnapshot(value: "something else", selectedText: nil)),
            expectedText: "hello world"
        )
        XCTAssertEqual(outcome, .inconclusive)
    }

    func testVerificationNormalizesLineEndings() {
        let outcome = TextInjectionService.evaluatePasteVerification(
            pre: .value(FocusedTextSnapshot(value: "", selectedText: nil)),
            post: .value(FocusedTextSnapshot(value: "line one\r\nline two", selectedText: nil)),
            expectedText: "line one\nline two"
        )
        XCTAssertEqual(outcome, .confirmed)
    }

    func testVerificationAcceptsTailMarkerForLongTranscripts() {
        let longText = String(repeating: "alpha beta gamma ", count: 20) + "the distinctive ending."
        // Field head-truncated the long paste; only the tail survives.
        let outcome = TextInjectionService.evaluatePasteVerification(
            pre: .value(FocusedTextSnapshot(value: "", selectedText: nil)),
            post: .value(FocusedTextSnapshot(value: "…gamma the distinctive ending.", selectedText: nil)),
            expectedText: longText
        )
        XCTAssertEqual(outcome, .confirmed)
    }

    func testCodexUnverifiedPasteUsesGuardedRestoreWithoutFailureState() {
        XCTAssertEqual(
            TextInjectionService.unverifiedPastePolicy(targetBundleID: "com.openai.codex"),
            .guardedRestoreAfterUnverifiedSuccess
        )
        XCTAssertEqual(
            TextInjectionService.unverifiedPastePolicy(targetBundleID: "com.apple.TextEdit"),
            .assumeDeliveredAndRestoreClipboard
        )
    }

    func testCodexUnverifiedPasteRestoresClipboardAfterDeliveryWindow() async {
        inspector.detailsResult = normalDetails()
        inspector.fieldExposesNoText = true
        clipboard.restoredStringToReturn = "Previous clipboard"
        let durableService = TextInjectionService(
            clipboard: clipboard,
            inspector: inspector,
            keyPoster: keyPoster,
            unverifiedPastePolicy: { _ in .guardedRestoreAfterUnverifiedSuccess }
        )
        durableService.lowLatencyModeEnabled = true

        let result = await durableService.inject(text: "Hello Codex")

        XCTAssertEqual(result, .success(method: .unverifiedPaste))
        XCTAssertEqual(keyPoster.pasteChordCount, 1)
        XCTAssertEqual(clipboard.restoreCount, 1)
        XCTAssertEqual(clipboard.setStrings, ["Hello Codex"])
        XCTAssertEqual(clipboard.stringToReturn, "Previous clipboard")
        XCTAssertEqual(durableService.lastInjectionTelemetry?.method, .unverifiedPaste)
    }

    func testCodexUnverifiedPasteDoesNotOverwriteNewerClipboardContents() async {
        inspector.detailsResult = normalDetails()
        inspector.fieldExposesNoText = true
        keyPoster.onPasteChord = { [clipboard] _ in
            clipboard?.stringToReturn = "Copied on iPhone"
            clipboard?.changeCount += 1
        }
        let durableService = TextInjectionService(
            clipboard: clipboard,
            inspector: inspector,
            keyPoster: keyPoster,
            unverifiedPastePolicy: { _ in .guardedRestoreAfterUnverifiedSuccess }
        )
        durableService.lowLatencyModeEnabled = true

        let result = await durableService.inject(text: "Hello Codex")

        XCTAssertEqual(result, .success(method: .unverifiedPaste))
        XCTAssertEqual(keyPoster.pasteChordCount, 1)
        XCTAssertEqual(clipboard.restoreCount, 0)
        XCTAssertEqual(clipboard.stringToReturn, "Copied on iPhone")
        XCTAssertEqual(clipboard.setStrings, ["Hello Codex"])
    }

    // MARK: Happy path

    func testInjectSuccessOnFirstPaste() async {
        inspector.detailsResult = normalDetails()
        inspector.simulatedFieldValue = ""
        keyPoster.onPasteChord = { [inspector] _ in
            inspector?.simulatedFieldValue = "Hello world"
        }

        let result = await service.inject(text: "Hello world")

        XCTAssertEqual(result, .success(method: .paste))
        XCTAssertEqual(keyPoster.pasteChordCount, 1, "Verified first paste must not retry")
        XCTAssertTrue(inspector.insertedTexts.isEmpty, "No AX fallback on verified paste")
        XCTAssertTrue(keyPoster.typedTexts.isEmpty, "No typed fallback on verified paste")
        XCTAssertEqual(clipboard.setStrings, ["Hello world"])
        XCTAssertEqual(clipboard.restoreCount, 1, "Clipboard must be restored after success")
        XCTAssertEqual(service.lastInjectionTelemetry?.method, .paste)
        XCTAssertEqual(service.lastInjectionTelemetry?.pasteAttempts, 1)
    }

    func testVerifiedPasteDoesNotOverwriteNewerClipboardContents() async {
        inspector.detailsResult = normalDetails()
        inspector.simulatedFieldValue = ""
        keyPoster.onPasteChord = { [inspector, clipboard] _ in
            inspector?.simulatedFieldValue = "Hello world"
            clipboard?.stringToReturn = "Copied on iPhone"
            clipboard?.changeCount += 1
        }

        let result = await service.inject(text: "Hello world")

        XCTAssertEqual(result, .success(method: .paste))
        XCTAssertEqual(clipboard.restoreCount, 0)
        XCTAssertEqual(clipboard.stringToReturn, "Copied on iPhone")
        XCTAssertEqual(clipboard.setStrings, ["Hello world"])
    }

    func testInjectInconclusiveVerificationCountsAsSuccessWithoutFallbacks() async {
        // Element hides its text from AX (terminals, canvas editors):
        // behave exactly like today's unverified paste.
        inspector.detailsResult = normalDetails()
        inspector.fieldExposesNoText = true

        let result = await service.inject(text: "Hello world")

        XCTAssertEqual(result, .success(method: .paste))
        XCTAssertEqual(keyPoster.pasteChordCount, 1)
        XCTAssertTrue(inspector.insertedTexts.isEmpty)
        XCTAssertTrue(keyPoster.typedTexts.isEmpty)
        XCTAssertEqual(clipboard.restoreCount, 1)
    }

    func testInjectIntoTerminalStyleEmptyValueElementPastesOnceWithoutFallbacks() async {
        // Regression (cmux/Ghostty): element exposes value == "" before and
        // after the paste. Must behave like an unverifiable element: one
        // paste, assumed success, no retry, no AX insert (screen-wide
        // selection side effect), no typed duplicate.
        inspector.detailsResult = normalDetails()
        inspector.simulatedFieldValue = ""

        let result = await service.inject(text: "Hello world")

        XCTAssertEqual(result, .success(method: .paste))
        XCTAssertEqual(keyPoster.pasteChordCount, 1, "Terminal-style elements must not double-paste")
        XCTAssertTrue(inspector.insertedTexts.isEmpty, "AX insert must never fire on unverifiable elements")
        XCTAssertTrue(keyPoster.typedTexts.isEmpty)
        XCTAssertEqual(clipboard.restoreCount, 1)
    }

    // MARK: Fallback chain

    func testInjectRetriesPasteOnceWhenFirstPasteDidNotLand() async {
        inspector.detailsResult = normalDetails()
        inspector.simulatedFieldValue = "draft: "
        keyPoster.onPasteChord = { [inspector] attempt in
            if attempt == 2 {
                inspector?.simulatedFieldValue = "Hello world"
            }
        }

        let result = await service.inject(text: "Hello world")

        XCTAssertEqual(result, .success(method: .paste))
        XCTAssertEqual(keyPoster.pasteChordCount, 2)
        XCTAssertTrue(inspector.insertedTexts.isEmpty)
        XCTAssertEqual(service.lastInjectionTelemetry?.pasteAttempts, 2)
        XCTAssertEqual(clipboard.restoreCount, 1)
    }

    func testInjectFallsBackToAXInsertAfterPasteRetryFails() async {
        inspector.detailsResult = normalDetails()
        inspector.simulatedFieldValue = "draft: "
        inspector.insertResult = true
        inspector.onInsert = { [inspector] text in
            inspector?.simulatedFieldValue = text
        }

        let result = await service.inject(text: "Hello world")

        XCTAssertEqual(result, .success(method: .axInsert))
        XCTAssertEqual(keyPoster.pasteChordCount, 2, "AX fallback only after paste + retry both fail")
        XCTAssertEqual(inspector.insertedTexts, ["Hello world"])
        XCTAssertTrue(keyPoster.typedTexts.isEmpty, "Typed fallback not reached when AX insert lands")
        XCTAssertEqual(service.lastInjectionTelemetry?.method, .axInsert)
        XCTAssertEqual(clipboard.restoreCount, 1)
    }

    func testInjectFallsBackToTypedKeystrokesAfterAXInsertFails() async {
        inspector.detailsResult = normalDetails()
        inspector.simulatedFieldValue = "draft: "
        inspector.insertResult = false
        keyPoster.onTypedText = { [inspector] text in
            inspector?.simulatedFieldValue = text
        }

        let result = await service.inject(text: "Hello world")

        XCTAssertEqual(result, .success(method: .typed))
        XCTAssertEqual(keyPoster.pasteChordCount, 2)
        XCTAssertEqual(inspector.insertedTexts, ["Hello world"], "AX insert attempted before typing")
        XCTAssertEqual(keyPoster.typedTexts, ["Hello world"])
        XCTAssertEqual(service.lastInjectionTelemetry?.method, .typed)
        XCTAssertEqual(clipboard.restoreCount, 1)
    }

    func testInjectReportsHonestFailureWhenAllMethodsFail() async {
        inspector.detailsResult = normalDetails()
        inspector.simulatedFieldValue = "stuck" // never changes
        inspector.insertResult = false

        let result = await service.inject(text: "Hello world")

        XCTAssertEqual(result, .failedAllMethods)
        XCTAssertEqual(keyPoster.pasteChordCount, 2)
        XCTAssertEqual(inspector.insertedTexts, ["Hello world"])
        XCTAssertEqual(keyPoster.typedTexts, ["Hello world"])
        XCTAssertEqual(service.lastInjectionTelemetry?.method, .failed)
        XCTAssertEqual(clipboard.restoreCount, 0, "Failure must leave the transcript on the clipboard")
        XCTAssertEqual(clipboard.setStrings.last, "Hello world")
    }
}
