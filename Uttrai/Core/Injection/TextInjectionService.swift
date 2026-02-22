// TextInjectionService.swift
// Uttrai

import Cocoa
import os

enum InjectionResult {
    case success
    case blockedSecureField
}

final class TextInjectionService {
    private let clipboard: ClipboardManager
    private(set) var lastTranscript: String?

    init(clipboard: ClipboardManager = ClipboardManager()) {
        self.clipboard = clipboard
    }

    func isFocusedElementSecure() -> Bool {
        guard let frontApp = NSWorkspace.shared.frontmostApplication else {
            return false // Fail-open
        }

        let appElement = AXUIElementCreateApplication(frontApp.processIdentifier)

        var focusedElement: AnyObject?
        let focusResult = AXUIElementCopyAttributeValue(
            appElement,
            kAXFocusedUIElementAttribute as CFString,
            &focusedElement
        )

        guard focusResult == .success, let element = focusedElement else {
            return false // Fail-open if we can't get focused element
        }

        var roleValue: AnyObject?
        let roleResult = AXUIElementCopyAttributeValue(
            element as! AXUIElement,
            kAXRoleAttribute as CFString,
            &roleValue
        )

        guard roleResult == .success, let role = roleValue as? String else {
            return false // Fail-open
        }

        return role == (kAXSecureTextFieldRole as String)
    }

    func inject(text: String) async -> InjectionResult {
        // Step 1: Check for secure field BEFORE setting lastTranscript
        if isFocusedElementSecure() {
            Logger.injection.info("Blocked: focused element is a secure text field")
            return .blockedSecureField
        }

        // Step 2: Set lastTranscript only after secure field check passes
        lastTranscript = text

        // Step 3: Save current pasteboard
        let saved = clipboard.save()

        // Step 4: Set transcript on pasteboard
        clipboard.setString(text)

        // Step 5: Simulate paste
        simulatePaste()

        // Step 6: Wait for paste to complete
        try? await Task.sleep(nanoseconds: 250_000_000) // 250ms

        // Step 7: Restore pasteboard
        clipboard.restore(saved)

        Logger.injection.info("Text injected: \(text.prefix(50))...")
        return .success
    }

    func pasteLastTranscript() async -> InjectionResult {
        guard let transcript = lastTranscript else {
            Logger.injection.info("No last transcript to paste")
            return .blockedSecureField
        }
        return await inject(text: transcript)
    }

    private func simulatePaste() {
        let source = CGEventSource(stateID: .hidSystemState)

        // Key code 0x09 = V key
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false) else {
            Logger.injection.error("Failed to create CGEvents for paste simulation")
            return
        }

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand

        keyDown.post(tap: .cghidEventTap)
        usleep(10_000) // 10ms pause between key-down and key-up
        keyUp.post(tap: .cghidEventTap)
    }
}
