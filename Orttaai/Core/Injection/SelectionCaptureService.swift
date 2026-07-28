// SelectionCaptureService.swift
// Orttaai

import Cocoa
import os

/// How the current selection was read out of the frontmost app. Persisted
/// nowhere, but logged so capture behavior stays diagnosable per app.
enum SelectionCaptureMethod: String, Equatable, Sendable {
    case axRead = "ax"
    case clipboardCopy = "clipboard"
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

        // Step 2: Cmd+C fallback into a saved-and-restored clipboard.
        let saved = clipboard.save()
        let baselineChangeCount = clipboard.changeCount
        keyPoster.postCopyChord()

        var copied: String?
        for _ in 0..<Self.copyPollAttempts {
            try? await Task.sleep(nanoseconds: Self.copyPollIntervalNs)
            if clipboard.changeCount != baselineChangeCount {
                copied = clipboard.getString()
                break
            }
        }
        clipboard.restore(saved)

        guard let copied, !copied.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            Logger.injection.info("Selection capture found no selection (AX empty, copy produced nothing)")
            return .noSelection
        }
        Logger.injection.info("Selection captured via clipboard fallback (\(copied.count) chars)")
        return .captured(CapturedSelection(text: copied, method: .clipboardCopy))
    }
}
