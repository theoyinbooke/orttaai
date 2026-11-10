// ModifierTapDetector.swift
// Orttaai
//
// Decides whether a press of one modifier key (Right Option or Right
// Command), on its own, was a tap: the key went down and up quickly with
// nothing else pressed in between. Typing an ⌥-character (é, ™, —) or using
// the key in a shortcut (⌘C) is never a tap.
//
// Timestamps are injected so the logic is fully deterministic under test.

import Foundation

struct ModifierTapDetector {
    /// macOS virtual key code for the Right Option key (kVK_RightOption).
    static let rightOptionKeyCode: UInt16 = 61
    /// macOS virtual key code for the Right Command key (kVK_RightCommand).
    static let rightCommandKeyCode: UInt16 = 54

    /// The key this detector watches.
    let keyCode: UInt16
    /// Longest press that still counts as a tap.
    let maxTapDuration: TimeInterval
    /// Right Command is half of many shortcuts whose other key the listener
    /// may never see (system shortcuts like ⌘Tab), so only a brisk tap counts.
    static let rightCommandTapMaxDuration: TimeInterval = 0.3

    /// Same threshold as the shortcut's tap, so one quick press means the
    /// same thing on either key.
    static let tapMaxDuration: TimeInterval = HotkeyGestureInterpreter.tapMaxDuration

    private var pressStart: TimeInterval?
    private var spoiled = false

    init(
        keyCode: UInt16 = ModifierTapDetector.rightOptionKeyCode,
        maxTapDuration: TimeInterval = ModifierTapDetector.tapMaxDuration
    ) {
        self.keyCode = keyCode
        self.maxTapDuration = maxTapDuration
    }

    /// A modifier key changed. Returns true when this was the release that
    /// completes a clean tap of the watched key.
    ///
    /// - Parameters:
    ///   - keyCode: the modifier key that changed.
    ///   - keyIsDown: whether the watched key is down after the change.
    ///   - otherModifiersDown: whether any other modifier is down.
    mutating func modifiersChanged(
        keyCode: UInt16,
        keyIsDown: Bool,
        otherModifiersDown: Bool,
        at time: TimeInterval
    ) -> Bool {
        guard keyCode == self.keyCode else {
            // Another modifier joined in while Right Option was held: a combo.
            if pressStart != nil { spoiled = true }
            return false
        }

        if keyIsDown {
            // Pressed while another modifier was already held: a combo.
            pressStart = otherModifiersDown ? nil : time
            spoiled = false
            return false
        }

        defer {
            pressStart = nil
            spoiled = false
        }
        guard let start = pressStart, !spoiled else { return false }
        let held = time - start
        return held >= 0 && held < maxTapDuration
    }

    /// A key, mouse button or anything else happened. While the watched key
    /// is down this turns the press into a combo, never a tap.
    mutating func otherInput() {
        if pressStart != nil { spoiled = true }
    }

    /// Forgets any press in flight, e.g. when the listener restarts.
    mutating func reset() {
        pressStart = nil
        spoiled = false
    }
}
