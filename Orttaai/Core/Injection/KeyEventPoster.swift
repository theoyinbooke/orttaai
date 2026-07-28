// KeyEventPoster.swift
// Orttaai

import Cocoa
import os

/// Testable seam over synthetic keyboard events so injection fallback logic
/// can be exercised in unit tests without posting real CGEvents.
protocol KeyEventPosting: AnyObject {
    /// Posts a synthetic Cmd+V chord to the HID event tap.
    func postPasteChord()
    /// Types `text` as ordered unicode keystrokes, chunked so long transcripts
    /// stay within CGEvent's per-event unicode payload limits.
    func postTypedText(_ text: String)
}

final class CGKeyEventPoster: KeyEventPosting {
    /// CGEventKeyboardSetUnicodeString accepts long payloads, but small
    /// chunks with inter-event gaps keep ordering reliable across apps.
    static let typedChunkLength = 20

    func postPasteChord() {
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

    func postTypedText(_ text: String) {
        let source = CGEventSource(stateID: .hidSystemState)
        let characters = Array(text.utf16)
        var index = 0

        while index < characters.count {
            let end = min(index + Self.typedChunkLength, characters.count)
            var chunk = Array(characters[index..<end])

            guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                  let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else {
                Logger.injection.error("Failed to create CGEvents for typed injection")
                return
            }

            keyDown.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: &chunk)
            keyUp.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: &chunk)
            keyDown.post(tap: .cghidEventTap)
            keyUp.post(tap: .cghidEventTap)
            usleep(3_000) // 3ms between chunks preserves ordering in slow apps

            index = end
        }
    }
}
