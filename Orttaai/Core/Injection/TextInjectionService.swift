// TextInjectionService.swift
// Orttaai

import Cocoa
import os

enum InjectionResult: Equatable {
    case success
    case blockedSecureField
    case noTranscript
}

protocol TextInjecting: AnyObject {
    var lastTranscript: String? { get }
    func inject(text: String, targetApp: NSRunningApplication?) async -> InjectionResult
    func pasteLastTranscript(targetApp: NSRunningApplication?) async -> InjectionResult
}

extension TextInjecting {
    func inject(text: String) async -> InjectionResult {
        await inject(text: text, targetApp: nil)
    }
    func pasteLastTranscript() async -> InjectionResult {
        await pasteLastTranscript(targetApp: nil)
    }
}

final class TextInjectionService: TextInjecting {
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

        let focusedAXElement = element as! AXUIElement

        var roleValue: AnyObject?
        let roleResult = AXUIElementCopyAttributeValue(
            focusedAXElement,
            kAXRoleAttribute as CFString,
            &roleValue
        )

        guard roleResult == .success, let role = roleValue as? String else {
            return false // Fail-open
        }

        guard role == (kAXTextFieldRole as String) else {
            return false
        }

        var subroleValue: AnyObject?
        let subroleResult = AXUIElementCopyAttributeValue(
            focusedAXElement,
            kAXSubroleAttribute as CFString,
            &subroleValue
        )

        guard subroleResult == .success, let subrole = subroleValue as? String else {
            return false
        }

        return subrole == (kAXSecureTextFieldSubrole as String)
    }

    func inject(text: String, targetApp: NSRunningApplication? = nil) async -> InjectionResult {
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

        // Step 5: Re-activate the target app so the paste goes to it, not Orttaai.
        // The target app was captured when recording started — before Orttaai's floating panel appeared.
        let appToActivate = targetApp ?? NSWorkspace.shared.frontmostApplication
        if let app = appToActivate, app.bundleIdentifier != Bundle.main.bundleIdentifier {
            app.activate()
            // Poll until the target app is actually active (up to 500ms)
            for _ in 0..<10 {
                try? await Task.sleep(nanoseconds: 25_000_000) // 25ms
                if app.isActive { break }
            }
            Logger.injection.info("Target app active: \(app.isActive), bundle: \(app.bundleIdentifier ?? "?")")
        }

        // Step 6: Simulate paste
        simulatePaste()

        // Step 7: Wait for paste to complete
        try? await Task.sleep(nanoseconds: 150_000_000) // 150ms

        // Step 8: Restore pasteboard
        clipboard.restore(saved)

        Logger.injection.info("Text injected: \(text.prefix(50))...")
        return .success
    }

    func pasteLastTranscript(targetApp: NSRunningApplication? = nil) async -> InjectionResult {
        guard let transcript = lastTranscript else {
            Logger.injection.info("No last transcript to paste")
            return .noTranscript
        }
        return await inject(text: transcript, targetApp: targetApp)
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
        usleep(7_000) // 7ms pause between key-down and key-up
        keyUp.post(tap: .cghidEventTap)
    }
}
