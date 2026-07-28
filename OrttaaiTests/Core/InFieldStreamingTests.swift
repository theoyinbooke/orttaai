// InFieldStreamingTests.swift
// OrttaaiTests

import XCTest
@testable import Orttaai

/// Unit tests for in-field streaming: increment computation, the finalize
/// reconciliation planner, the terminal/secure/focus gate matrix, and the
/// session state machine — all driven through the existing protocol seams
/// (no live AX).
final class InFieldStreamingTests: XCTestCase {

    // MARK: - Increment planner

    func testFirstIncrementHasNoLeadingSpaceAndLaterOnesJoinWithSingleSpace() {
        var planner = StreamingIncrementPlanner()

        XCTAssertEqual(planner.increment(forCommittedText: "Hello there,"), "Hello there,")
        XCTAssertEqual(planner.increment(forCommittedText: "how are you?"), " how are you?")
        XCTAssertEqual(planner.streamedText, "Hello there, how are you?")
    }

    func testIncrementFlattensNewlinesAndCollapsesInternalWhitespace() {
        var planner = StreamingIncrementPlanner()

        let increment = planner.increment(forCommittedText: "  hello\nworld\r\n  again\ttoday  ")

        XCTAssertEqual(increment, "hello world again today")
        XCTAssertFalse(planner.streamedText.contains(where: \.isNewline),
                       "Streamed increments must never contain line breaks")
    }

    func testBlankAndSilentCommitsProduceNoIncrement() {
        var planner = StreamingIncrementPlanner()

        XCTAssertNil(planner.increment(forCommittedText: ""))
        XCTAssertNil(planner.increment(forCommittedText: "   \n  "))
        XCTAssertNil(planner.increment(forCommittedText: "[BLANK_AUDIO]"))
        XCTAssertEqual(planner.streamedText, "")
    }

    // MARK: - Reconciliation planner

    func testPlanAlreadyExactWhenFinalEqualsStreamed() {
        let plan = StreamingReconciliation.plan(
            streamedText: "hello world",
            finalText: "hello world",
            preStreamFieldValue: "note: ",
            currentFieldValue: "note: hello world"
        )
        XCTAssertEqual(plan, .alreadyExact)
    }

    func testPlanAppendsRemainderWhenStreamedIsPrefixOfFinal() {
        let plan = StreamingReconciliation.plan(
            streamedText: "hello world",
            finalText: "hello world and more",
            preStreamFieldValue: "",
            currentFieldValue: "hello world"
        )
        XCTAssertEqual(plan, .appendRemainder(" and more"))
    }

    func testPlanReplacesOnlyTheDivergentTail() {
        // Dictionary pass corrected "helo" -> "hello": shared prefix "hel",
        // delete the 8 streamed characters after it, insert the fixed tail.
        let plan = StreamingReconciliation.plan(
            streamedText: "helo world",
            finalText: "hello world",
            preStreamFieldValue: "pre ",
            currentFieldValue: "pre helo world"
        )
        XCTAssertEqual(plan, .replaceDivergentTail(deleteCharacters: 7, replacement: "lo world"))
    }

    func testPlanAbortsWhenFieldBecameUnreadable() {
        let plan = StreamingReconciliation.plan(
            streamedText: "hello",
            finalText: "hello",
            preStreamFieldValue: "",
            currentFieldValue: nil
        )
        XCTAssertEqual(plan, .abortFieldMismatch)
    }

    func testPlanAbortsWhenUserTypedMidStream() {
        // User typed "!" while dictating: the field is no longer exactly
        // baseline + streamed span, so deletion is unsafe.
        let plan = StreamingReconciliation.plan(
            streamedText: "hello world",
            finalText: "hello world",
            preStreamFieldValue: "note: ",
            currentFieldValue: "note: hello world!"
        )
        XCTAssertEqual(plan, .abortFieldMismatch)
    }

    func testPlanAbortsWhenAppTransformedStreamedText() {
        // Autocapitalize rewrote the streamed words — same length, different
        // content. Splice verification must reject it.
        let plan = StreamingReconciliation.plan(
            streamedText: "hello world",
            finalText: "hello world",
            preStreamFieldValue: "",
            currentFieldValue: "Hello world"
        )
        XCTAssertEqual(plan, .abortFieldMismatch)
    }

    func testPlanToleratesSmartQuoteSubstitutionByTheEditor() {
        // TextEdit rewrites typed straight apostrophes into typographic ones
        // (verified live). A 1:1 cosmetic substitution must not read as a
        // user-typed mismatch.
        let plan = StreamingReconciliation.plan(
            streamedText: "don't stop now",
            finalText: "don't stop now",
            preStreamFieldValue: "memo: ",
            currentFieldValue: "memo: don\u{2019}t stop now"
        )
        XCTAssertEqual(plan, .alreadyExact)
    }

    func testSpliceMatchesStreamedSpanInsertedMidDocument() {
        XCTAssertTrue(StreamingReconciliation.spliceMatches(pre: "AB", streamed: "XY", current: "AXYB"))
        XCTAssertFalse(StreamingReconciliation.spliceMatches(pre: "AB", streamed: "XY", current: "AXBY"))
    }

    func testSpliceHandlesRepeatedContentByCheckingEveryOccurrence() {
        // The streamed text also occurs in pre-existing content; only the
        // second occurrence is the real insertion.
        XCTAssertTrue(StreamingReconciliation.spliceMatches(
            pre: "abc abc",
            streamed: "abc",
            current: "abc abcabc"
        ))
    }

    func testSpliceFallsBackToContainmentWithoutBaseline() {
        XCTAssertTrue(StreamingReconciliation.spliceMatches(pre: nil, streamed: "hello", current: "say hello now"))
        XCTAssertFalse(StreamingReconciliation.spliceMatches(pre: nil, streamed: "hello", current: "goodbye"))
    }

    // MARK: - Start gate matrix

    private func normalDetails(role: String = "AXTextArea") -> AXInspection<FocusedElementDetails> {
        .value(FocusedElementDetails(role: role, subrole: nil, roleDescription: "text entry area"))
    }

    private func snapshot(value: String?) -> AXInspection<FocusedTextSnapshot> {
        .value(FocusedTextSnapshot(value: value, selectedText: nil))
    }

    func testGateBlocksKnownTerminalBundlesCaseInsensitively() {
        for bundleID in ["com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty", "NET.KOVIDGOYAL.KITTY"] {
            XCTAssertEqual(
                InFieldStreamingGate.assessStart(
                    bundleID: bundleID,
                    targetFrontmost: true,
                    details: normalDetails(),
                    snapshot: snapshot(value: "prompt$ ")
                ),
                .terminalBundle,
                "\(bundleID) must never receive streamed keystrokes"
            )
        }
    }

    func testGateBlocksEmptyValueTextAreaAsTerminalHeuristic() {
        // Terminals like cmux/Ghostty expose their grid as an AXTextArea with
        // an empty-string value (see the paste-verification history).
        XCTAssertEqual(
            InFieldStreamingGate.assessStart(
                bundleID: "com.unknown.terminal-like",
                targetFrontmost: true,
                details: normalDetails(role: "AXTextArea"),
                snapshot: snapshot(value: "")
            ),
            .terminalHeuristic
        )
    }

    func testGateAllowsEmptyValueSingleLineTextField() {
        XCTAssertNil(
            InFieldStreamingGate.assessStart(
                bundleID: "com.apple.Notes",
                targetFrontmost: true,
                details: normalDetails(role: "AXTextField"),
                snapshot: snapshot(value: "")
            )
        )
    }

    func testGateBlocksSecureField() {
        let secureDetails = AXInspection<FocusedElementDetails>.value(
            FocusedElementDetails(role: "AXTextField", subrole: "AXSecureTextField", roleDescription: "secure text field")
        )
        XCTAssertEqual(
            InFieldStreamingGate.assessStart(
                bundleID: "com.apple.Safari",
                targetFrontmost: true,
                details: secureDetails,
                snapshot: snapshot(value: "")
            ),
            .secureField
        )
    }

    func testGateBlocksWhenAXFailsOrFieldExposesNoValue() {
        XCTAssertEqual(
            InFieldStreamingGate.assessStart(
                bundleID: "com.example.app",
                targetFrontmost: true,
                details: .axError,
                snapshot: snapshot(value: "text")
            ),
            .unreadableField
        )
        XCTAssertEqual(
            InFieldStreamingGate.assessStart(
                bundleID: "com.example.app",
                targetFrontmost: true,
                details: normalDetails(),
                snapshot: snapshot(value: nil)
            ),
            .unreadableField
        )
        XCTAssertEqual(
            InFieldStreamingGate.assessStart(
                bundleID: "com.example.app",
                targetFrontmost: true,
                details: normalDetails(),
                snapshot: .axError
            ),
            .unreadableField
        )
    }

    func testGateBlocksWhenTargetNotFrontmost() {
        XCTAssertEqual(
            InFieldStreamingGate.assessStart(
                bundleID: "com.example.app",
                targetFrontmost: false,
                details: normalDetails(),
                snapshot: snapshot(value: "text")
            ),
            .focusLost
        )
    }

    func testGateAllowsNormalReadableTextArea() {
        XCTAssertNil(
            InFieldStreamingGate.assessStart(
                bundleID: "com.apple.TextEdit",
                targetFrontmost: true,
                details: normalDetails(),
                snapshot: snapshot(value: "existing document text")
            )
        )
    }

    // MARK: - Session behavior (through the protocol seams)

    private var inspector: MockAccessibilityInspector!
    private var keyPoster: MockKeyEventPoster!
    private var clipboard: MockClipboard!
    private var targetFrontmost = true

    override func setUp() {
        super.setUp()
        inspector = MockAccessibilityInspector()
        keyPoster = MockKeyEventPoster()
        clipboard = MockClipboard()
        targetFrontmost = true
    }

    /// Session whose typed keystrokes land in the simulated field, like a
    /// well-behaved text view.
    private func makeSession(fieldValue: String = "doc: ", keystrokesLand: Bool = true) -> InFieldStreamingSession {
        inspector.detailsResult = normalDetails()
        inspector.simulatedFieldValue = fieldValue
        // Well-behaved text views keep the caret at the end of what was
        // typed/deleted; the mock mirrors that so caret-guard checks see
        // realistic positions.
        let syncCaretToEnd = { [inspector] in
            let value = inspector?.simulatedFieldValue ?? ""
            inspector?.simulatedSelectedRange = FocusedTextRange(location: value.utf16.count, length: 0)
        }
        syncCaretToEnd()
        if keystrokesLand {
            keyPoster.onTypedText = { [inspector] text in
                inspector?.simulatedFieldValue = (inspector?.simulatedFieldValue ?? "") + text
                syncCaretToEnd()
            }
            keyPoster.onBackspaces = { [inspector] count in
                let value = inspector?.simulatedFieldValue ?? ""
                inspector?.simulatedFieldValue = String(value.dropLast(count))
                syncCaretToEnd()
            }
            keyPoster.onPasteChord = { [inspector, clipboard] _ in
                let pasted = clipboard?.setStrings.last ?? ""
                inspector?.simulatedFieldValue = (inspector?.simulatedFieldValue ?? "") + pasted
                syncCaretToEnd()
            }
        }
        return InFieldStreamingSession(
            targetApp: nil,
            inspector: inspector,
            keyPoster: keyPoster,
            clipboard: clipboard,
            settleNanoseconds: 0,
            isTargetFrontmost: { [weak self] in self?.targetFrontmost ?? false }
        )
    }

    func testSessionStreamsCommitsAsTypedIncrementsWithoutTouchingClipboard() async {
        let session = makeSession()

        await session.ingestCommit("Hello there,")
        await session.ingestCommit("how are you?")

        XCTAssertTrue(session.isStreaming)
        XCTAssertEqual(keyPoster.typedTexts, ["Hello there,", " how are you?"])
        XCTAssertEqual(inspector.simulatedFieldValue, "doc: Hello there, how are you?")
        XCTAssertEqual(clipboard.saveCount, 0, "Streaming must never touch the clipboard")
        XCTAssertEqual(clipboard.setStrings, [])
    }

    func testSessionFallsBackWhenTargetLosesFocusAndNeverResumes() async {
        let session = makeSession()
        await session.ingestCommit("first clip")

        targetFrontmost = false
        await session.ingestCommit("second clip")

        XCTAssertEqual(session.phase, .fallback(.focusLost))
        XCTAssertFalse(session.isStreaming)
        XCTAssertEqual(keyPoster.typedTexts, ["first clip"], "No keystrokes may reach a different app")

        // Focus returning does not resume streaming — fallback is one-way.
        targetFrontmost = true
        await session.ingestCommit("third clip")
        XCTAssertEqual(keyPoster.typedTexts, ["first clip"])
    }

    func testSpeculativeFocusCheckFlipsFallbackQuickly() async {
        let session = makeSession()
        await session.ingestCommit("first clip")
        XCTAssertTrue(session.isStreaming)

        targetFrontmost = false
        session.refreshFocusGate()

        XCTAssertEqual(session.phase, .fallback(.focusLost))
    }

    func testSessionStopsWhenFieldBecomesSecureMidSession() async {
        let session = makeSession()
        await session.ingestCommit("email body")

        inspector.detailsResult = .value(
            FocusedElementDetails(role: "AXTextField", subrole: "AXSecureTextField", roleDescription: "secure text field")
        )
        await session.ingestCommit("secret words")

        XCTAssertEqual(session.phase, .fallback(.secureField))
        XCTAssertEqual(keyPoster.typedTexts, ["email body"])
    }

    func testSessionFallsBackWhenElementSwallowsKeystrokes() async {
        // Field value never changes (terminal-like grid): the visibility
        // check after the first increment must stop the stream.
        let session = makeSession(fieldValue: "prompt$ ", keystrokesLand: false)

        await session.ingestCommit("ls -la")

        XCTAssertEqual(session.phase, .fallback(.fieldMismatch))
        await session.ingestCommit("rm -rf things")
        XCTAssertEqual(keyPoster.typedTexts, ["ls -la"], "After the mismatch nothing more may be typed")
    }

    func testSessionKeepsStreamingWhenEditorSmartQuotesTheEcho() async {
        // The field echoes the increment with a typographic apostrophe; the
        // visibility check must not treat that as swallowed keystrokes.
        let session = makeSession(fieldValue: "memo: ", keystrokesLand: false)
        keyPoster.onTypedText = { [inspector] text in
            let curly = text.replacingOccurrences(of: "'", with: "\u{2019}")
            inspector?.simulatedFieldValue = (inspector?.simulatedFieldValue ?? "") + curly
        }

        await session.ingestCommit("don't stop now")

        XCTAssertTrue(session.isStreaming)
        XCTAssertEqual(inspector.simulatedFieldValue, "memo: don\u{2019}t stop now")
    }

    func testSessionNeverCreatesStreamingSessionGateOnEmptyTextArea() async {
        let session = makeSession(fieldValue: "")

        await session.ingestCommit("hello")

        XCTAssertEqual(session.phase, .fallback(.terminalHeuristic))
        XCTAssertEqual(keyPoster.typedTexts, [])
    }

    // MARK: - Finalize reconciliation

    func testFinalizeIsNoOpWhenStreamedSpanEqualsFinalText() async {
        let session = makeSession()
        await session.ingestCommit("hello world")

        let outcome = await session.finalize(finalText: "hello world")

        XCTAssertEqual(outcome, .completed)
        XCTAssertEqual(keyPoster.backspaceCounts, [])
        XCTAssertEqual(keyPoster.typedTexts, ["hello world"])
        XCTAssertEqual(clipboard.setStrings, [])
    }

    func testFinalizeTypesOnlyTheRemainderWhenPrefixesMatch() async {
        let session = makeSession()
        await session.ingestCommit("hello world")

        let outcome = await session.finalize(finalText: "hello world today")

        XCTAssertEqual(outcome, .completed)
        XCTAssertEqual(keyPoster.backspaceCounts, [])
        XCTAssertEqual(keyPoster.typedTexts, ["hello world", " today"])
        XCTAssertEqual(inspector.simulatedFieldValue, "doc: hello world today")
    }

    func testFinalizeReplacesDivergentTailWithBackspacesThenTypedText() async {
        let session = makeSession()
        await session.ingestCommit("helo world")

        let outcome = await session.finalize(finalText: "hello world")

        XCTAssertEqual(outcome, .completed)
        XCTAssertEqual(keyPoster.backspaceCounts, [7], "Delete exactly the divergent streamed tail, never more")
        XCTAssertEqual(keyPoster.typedTexts, ["helo world", "lo world"])
        XCTAssertEqual(inspector.simulatedFieldValue, "doc: hello world")
        XCTAssertEqual(clipboard.saveCount, 0)
    }

    func testFinalizePastesReconciliationTextContainingNewlinesWithOneSaveRestore() async {
        let session = makeSession()
        await session.ingestCommit("first line new line second line")

        // Spoken formatting turned the command into a real line break.
        let final = "first line\nSecond line"
        let outcome = await session.finalize(finalText: final)

        XCTAssertEqual(outcome, .completed)
        XCTAssertEqual(keyPoster.pasteChordCount, 1)
        XCTAssertEqual(clipboard.saveCount, 1, "Clipboard is saved/restored exactly once per session")
        XCTAssertEqual(clipboard.restoreCount, 1)
        XCTAssertEqual(clipboard.setStrings.count, 1)
        XCTAssertTrue(clipboard.setStrings[0].contains("\n"))
        XCTAssertFalse(keyPoster.typedTexts.contains(where: { $0.contains("\n") }),
                       "Line breaks must never be typed as unicode keystrokes")
    }

    func testFinalizeAbortsHonestlyWhenUserTypedMidStream() async {
        let session = makeSession()
        await session.ingestCommit("hello world")

        // User typed "!" into the field mid-dictation.
        inspector.simulatedFieldValue = "doc: hello world!"
        let outcome = await session.finalize(finalText: "hello world, friend")

        XCTAssertEqual(outcome, .failedNeedsManualPaste)
        XCTAssertEqual(keyPoster.backspaceCounts, [], "Never delete when the field stopped matching the streamed span")
        XCTAssertEqual(keyPoster.typedTexts, ["hello world"], "No new text may be inserted after a mismatch")
        XCTAssertEqual(clipboard.setStrings, ["hello world, friend"], "Final text goes to the clipboard for Cmd+V")
    }

    func testFinalizeAbortsWhenFieldBecameUnreadable() async {
        let session = makeSession()
        await session.ingestCommit("hello world")

        inspector.snapshotErrors = true
        let outcome = await session.finalize(finalText: "hello world")

        XCTAssertEqual(outcome, .failedNeedsManualPaste)
        XCTAssertEqual(clipboard.setStrings, ["hello world"])
    }

    // MARK: Caret guard (user moved the caret without typing)

    func testFinalizeDivergentTailAbortsWhenCaretMovedIntoPreexistingText() async {
        let session = makeSession()
        await session.ingestCommit("helo world")

        // User clicked into "doc: " (offset 2) — the field VALUE still
        // matches the splice, but backspaces would now delete pre-existing
        // characters.
        inspector.simulatedSelectedRange = FocusedTextRange(location: 2, length: 0)
        let outcome = await session.finalize(finalText: "hello world")

        XCTAssertEqual(outcome, .failedNeedsManualPaste)
        XCTAssertEqual(keyPoster.backspaceCounts, [], "Never backspace when the caret left the streamed span")
        XCTAssertEqual(keyPoster.typedTexts, ["helo world"], "No replacement text at a moved caret")
        XCTAssertEqual(clipboard.setStrings, ["hello world"], "Final text goes to the clipboard")
    }

    func testFinalizeAppendAbortsWhenCaretMovedIntoPreexistingText() async {
        let session = makeSession()
        await session.ingestCommit("hello world")

        inspector.simulatedSelectedRange = FocusedTextRange(location: 0, length: 0)
        let outcome = await session.finalize(finalText: "hello world today")

        XCTAssertEqual(outcome, .failedNeedsManualPaste)
        XCTAssertEqual(keyPoster.typedTexts, ["hello world"], "Remainder must not be typed mid-document")
        XCTAssertEqual(clipboard.setStrings, ["hello world today"])
    }

    func testFinalizeDivergentTailAbortsWhenCaretUnreadable() async {
        let session = makeSession()
        await session.ingestCommit("helo world")

        // Element stops exposing the selection range (canvas-ish editor):
        // destructive deletion must not proceed on faith.
        inspector.simulatedSelectedRange = nil
        let outcome = await session.finalize(finalText: "hello world")

        XCTAssertEqual(outcome, .failedNeedsManualPaste)
        XCTAssertEqual(keyPoster.backspaceCounts, [])
        XCTAssertEqual(clipboard.setStrings, ["hello world"])
    }

    func testFinalizeAppendProceedsWhenCaretUnreadable() async {
        let session = makeSession()
        await session.ingestCommit("hello world")

        // Non-destructive append keeps the status quo for elements that do
        // not expose a selection range; post-verification stays the backstop.
        inspector.simulatedSelectedRange = nil
        let outcome = await session.finalize(finalText: "hello world today")

        XCTAssertEqual(outcome, .completed)
        XCTAssertEqual(inspector.simulatedFieldValue, "doc: hello world today")
    }

    func testFinalizeDivergentTailAbortsWhenSelectionIsNonEmpty() async {
        let session = makeSession()
        await session.ingestCommit("helo world")

        // User selected some text — typing/deleting would replace it.
        let end = (inspector.simulatedFieldValue ?? "").utf16.count
        inspector.simulatedSelectedRange = FocusedTextRange(location: end - 5, length: 5)
        let outcome = await session.finalize(finalText: "hello world")

        XCTAssertEqual(outcome, .failedNeedsManualPaste)
        XCTAssertEqual(keyPoster.backspaceCounts, [])
    }

    func testMidStreamIncrementFallsBackWhenCaretMovedWithoutTyping() async {
        let session = makeSession()
        await session.ingestCommit("first clip")

        // User clicks into pre-existing text between commits (no keystrokes).
        inspector.simulatedSelectedRange = FocusedTextRange(location: 1, length: 0)
        await session.ingestCommit("second clip")

        XCTAssertEqual(session.phase, .fallback(.fieldMismatch))
        XCTAssertEqual(keyPoster.typedTexts, ["first clip"], "Second increment must not be typed at a moved caret")
    }

    func testMidStreamIncrementProceedsWhenCaretIsAtSpanEnd() async {
        let session = makeSession()
        await session.ingestCommit("first clip")
        await session.ingestCommit("second clip")

        XCTAssertTrue(session.isStreaming)
        XCTAssertEqual(keyPoster.typedTexts, ["first clip", " second clip"])
    }

    func testFinalizeReportsNotStreamedWhenNothingWasTyped() async {
        let session = makeSession()

        let outcome = await session.finalize(finalText: "hello world")

        XCTAssertEqual(outcome, .notStreamed)
        XCTAssertEqual(keyPoster.typedTexts, [])
        XCTAssertEqual(clipboard.setStrings, [])
    }

    func testFinalizeAfterFocusFallbackStillReconcilesTheStreamedSpan() async {
        let session = makeSession()
        await session.ingestCommit("hello")

        targetFrontmost = false
        await session.ingestCommit("world")
        XCTAssertEqual(session.phase, .fallback(.focusLost))

        // Finalize reconciles the partial streamed span against the full
        // final transcript: the missing words are appended, not re-pasted.
        let outcome = await session.finalize(finalText: "hello world")

        XCTAssertEqual(outcome, .completed)
        XCTAssertEqual(keyPoster.typedTexts, ["hello", " world"])
    }
}
