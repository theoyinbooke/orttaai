// SelectionCaptureService.swift
// Orttaai

import Cocoa
import os

/// How the current selection was read out of the frontmost app. Persisted
/// nowhere, but logged so capture behavior stays diagnosable per app.
enum SelectionCaptureMethod: String, Equatable, Sendable {
    case axRead = "ax"
    case clipboardCopy = "clipboard"
    /// Nothing was selected, so the last dictation was found in the field
    /// and selected.
    case lastInsertion = "last"
}

struct CapturedSelection: Equatable, Sendable {
    let text: String
    let method: SelectionCaptureMethod
}

enum SelectionCaptureResult: Equatable, Sendable {
    case captured(CapturedSelection)
    case noSelection
    /// The focused element is a password/secure field. Its contents must
    /// never be read — not even to hand to a local model.
    case blockedSecureField
}

/// Coordinator-facing seam over selection capture so the edit-command flow
/// (AX read first, Cmd+C-into-saved-clipboard fallback, no-selection error)
/// can be exercised in unit tests without live AX or the real pasteboard.
protocol SelectionCapturing: AnyObject {
    func captureSelection(processIdentifier: pid_t?) async -> SelectionCaptureResult
    /// The selection as Accessibility reports it, with no copy to the
    /// clipboard: safe to run at the start of every dictation.
    func peekSelection(processIdentifier: pid_t?) async -> SelectionCaptureResult
    /// Finds `text` (a dictation inserted earlier) in the focused field and
    /// selects it. `.noSelection` when the field can't be read, no longer
    /// holds the text, or doesn't take the selection.
    func selectInsertedText(_ text: String, processIdentifier: pid_t?) async -> SelectionCaptureResult
    /// Undoes `selectInsertedText` when the edit didn't land: if `text` is
    /// still the selection, the caret goes back to just after it.
    func deselectInsertedText(_ text: String, processIdentifier: pid_t?) async
    /// Whether `text` is still what's selected, right before an edit is
    /// pasted over it. True when the field can't be read: then nothing more
    /// is known than before.
    func isStillSelected(_ text: String, processIdentifier: pid_t?) async -> Bool
}

extension SelectionCapturing {
    func peekSelection(processIdentifier: pid_t?) async -> SelectionCaptureResult { .noSelection }
    func selectInsertedText(_ text: String, processIdentifier: pid_t?) async -> SelectionCaptureResult { .noSelection }
    func deselectInsertedText(_ text: String, processIdentifier: pid_t?) async {}
    func isStillSelected(_ text: String, processIdentifier: pid_t?) async -> Bool { true }
}

/// Reads the selected text of the frontmost app:
/// 1. AX read of kAXSelectedTextAttribute on the focused element (fast, no
///    clipboard side effects) — used whenever it yields non-empty text.
/// 2. Fallback for apps that hide selection from AX (Electron, terminals):
///    save the pasteboard, post a synthetic Cmd+C, wait for the pasteboard
///    change counter to bump, read the string, restore the saved pasteboard.
/// Returns nil when no selection can be found either way.
final class SelectionCaptureService: SelectionCapturing {
    private let inspector: any AccessibilityInspecting
    private let clipboard: any ClipboardManaging
    private let keyPoster: any KeyEventPosting

    /// Bounded wait for the copy to land: apps commit Cmd+C asynchronously.
    static let copyPollAttempts = 6
    static let copyPollIntervalNs: UInt64 = 50_000_000 // 50ms

    /// Reads while waiting for the app to show the new selection.
    static let selectPollAttempts = 5
    static let selectPollIntervalNs: UInt64 = 30_000_000 // 30ms

    init(
        inspector: any AccessibilityInspecting = SystemAccessibilityInspector(),
        clipboard: any ClipboardManaging = ClipboardManager(),
        keyPoster: any KeyEventPosting = CGKeyEventPoster()
    ) {
        self.inspector = inspector
        self.clipboard = clipboard
        self.keyPoster = keyPoster
    }

    func captureSelection(processIdentifier: pid_t?) async -> SelectionCaptureResult {
        // Step 0: secure-field guard, BEFORE any read. Injection re-checks at
        // paste time, but by then the field's contents would already have
        // reached the LLM — the same policy must gate capture itself.
        // Same fail-open-on-AX-error semantics as TextInjectionService.
        if TextInjectionService.assessSecureField(
            inspector.focusedElementDetails(processIdentifier: processIdentifier)
        ) == .blocked {
            Logger.injection.info("Selection capture blocked: focused element is a secure text field")
            return .blockedSecureField
        }

        // Step 1: AX read — no side effects, works in most native apps.
        if case .value(let snapshot) = inspector.focusedElementTextSnapshot(processIdentifier: processIdentifier),
           let selected = snapshot.selectedText,
           !selected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Logger.injection.info("Selection captured via AX (\(selected.count) chars)")
            return .captured(CapturedSelection(text: selected, method: .axRead))
        }

        // Step 2: Cmd+C fallback into a saved-and-restored clipboard. When
        // saving takes too long (an item copied on an iPhone, fetched over
        // the air), the copy goes ahead and its result stays on the clipboard.
        let saved = await clipboard.save(giveUpAfterMs: ClipboardManager.saveLimitMs)
        let baselineChangeCount = clipboard.changeCount
        keyPoster.postCopyChord()

        var copied: String?
        var copiedWholeLine = false
        for _ in 0..<Self.copyPollAttempts {
            try? await Task.sleep(nanoseconds: Self.copyPollIntervalNs)
            if clipboard.changeCount != baselineChangeCount {
                copied = clipboard.getString()
                // VS Code and its forks copy the whole line when nothing is
                // selected; that line is not a selection.
                copiedWholeLine = clipboard.copiedFromEmptySelection()
                break
            }
        }
        if let saved {
            clipboard.restore(saved)
        }

        if copiedWholeLine {
            Logger.injection.info("Selection capture found no selection (the editor copied the current line)")
            return .noSelection
        }
        guard let copied, !copied.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            Logger.injection.info("Selection capture found no selection (AX empty, copy produced nothing)")
            return .noSelection
        }
        Logger.injection.info("Selection captured via clipboard fallback (\(copied.count) chars)")
        return .captured(CapturedSelection(text: copied, method: .clipboardCopy))
    }

    /// Where the inserted text is in the field, in UTF-16 units. The caret
    /// sits just after a fresh insertion, so the copy nearest before the
    /// caret wins when the same words appear more than once. With no copy
    /// before the caret (the person moved it up), only a single copy in the
    /// whole field is trusted; several would be a guess.
    static func locateInsertedText(_ needle: String, in value: String, caretUTF16: Int?) -> NSRange? {
        let field = value as NSString
        if let caretUTF16, caretUTF16 >= 0, caretUTF16 <= field.length {
            let beforeCaret = field.range(
                of: needle,
                options: .backwards,
                range: NSRange(location: 0, length: caretUTF16)
            )
            if beforeCaret.location != NSNotFound { return beforeCaret }
        }
        let first = field.range(of: needle)
        guard first.location != NSNotFound else { return nil }
        let last = field.range(of: needle, options: .backwards)
        return first.location == last.location ? first : nil
    }

    func isStillSelected(_ text: String, processIdentifier: pid_t?) async -> Bool {
        guard case .value(let snapshot) = inspector.focusedElementTextSnapshot(processIdentifier: processIdentifier) else {
            return true
        }
        let selected = snapshot.selectedText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return selected == text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func deselectInsertedText(_ text: String, processIdentifier: pid_t?) async {
        let needle = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard case .value(let snapshot) = inspector.focusedElementTextSnapshot(processIdentifier: processIdentifier),
              snapshot.selectedText == needle,
              let range = snapshot.selectedRange, range.length > 0 else { return }
        _ = inspector.selectTextRange(
            FocusedTextRange(location: range.location + range.length, length: 0),
            processIdentifier: processIdentifier
        )
    }

    func peekSelection(processIdentifier: pid_t?) async -> SelectionCaptureResult {
        switch await inspector.peekSelectedText(processIdentifier: processIdentifier) {
        case .secureField:
            return .blockedSecureField
        case .selected(_, isSingleLine: true):
            // An address bar or search box selects all its text when
            // clicked; what's said there is meant to replace it.
            return .noSelection
        case .selected(let text, _) where !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty:
            return .captured(CapturedSelection(text: text, method: .axRead))
        case .selected, .nothingSelected:
            return .noSelection
        }
    }

    func selectInsertedText(_ text: String, processIdentifier: pid_t?) async -> SelectionCaptureResult {
        if TextInjectionService.assessSecureField(
            inspector.focusedElementDetails(processIdentifier: processIdentifier)
        ) == .blocked {
            return .blockedSecureField
        }

        let needle = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty,
              case .value(let snapshot) = inspector.focusedElementTextSnapshot(processIdentifier: processIdentifier),
              let value = snapshot.value else {
            Logger.injection.info("Last dictation not selected: the field can't be read")
            return .noSelection
        }
        guard let found = Self.locateInsertedText(
            needle,
            in: value,
            caretUTF16: snapshot.selectedRange.map { $0.location + $0.length }
        ) else {
            Logger.injection.info("Last dictation not selected: the field doesn't hold it, or holds it more than once away from the caret")
            return .noSelection
        }
        guard inspector.selectTextRange(
            FocusedTextRange(location: found.location, length: found.length),
            processIdentifier: processIdentifier
        ) else {
            Logger.injection.info("Last dictation not selected: the app refused the selection")
            return .noSelection
        }

        // Only a selection the app confirms is edited: the result is pasted
        // over whatever is selected.
        for attempt in 0..<Self.selectPollAttempts {
            if attempt > 0 {
                try? await Task.sleep(nanoseconds: Self.selectPollIntervalNs)
            }
            if case .value(let after) = inspector.focusedElementTextSnapshot(processIdentifier: processIdentifier),
               after.selectedText == needle {
                Logger.injection.info("Last dictation selected (\(needle.count) chars)")
                return .captured(CapturedSelection(text: needle, method: .lastInsertion))
            }
        }
        if let original = snapshot.selectedRange {
            _ = inspector.selectTextRange(original, processIdentifier: processIdentifier)
        }
        Logger.injection.info("Last dictation not selected: the selection didn't show up")
        return .noSelection
    }
}
