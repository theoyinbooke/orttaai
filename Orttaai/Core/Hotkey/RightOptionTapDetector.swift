// RightOptionTapDetector.swift
// Orttaai
//
// Decides whether a press of the Right Option key, on its own, was a tap: the
// key went down and up quickly with nothing else pressed in between. Typing
// an ⌥-character (é, ™, —) or using ⌥ in a shortcut is never a tap.
//
// Timestamps are injected so the logic is fully deterministic under test.

import Foundation

struct RightOptionTapDetector {
    /// macOS virtual key code for the Right Option key (kVK_RightOption).
    static let rightOptionKeyCode: UInt16 = 61

    /// Same threshold as the shortcut's tap, so one quick press means the
    /// same thing on either key.
    static let tapMaxDuration: TimeInterval = HotkeyGestureInterpreter.tapMaxDuration

    private var pressStart: TimeInterval?
    private var spoiled = false

    /// A modifier key changed. Returns true when this was the release that
    /// completes a clean tap of Right Option.
    ///
    /// - Parameters:
    ///   - keyCode: the modifier key that changed.
    ///   - rightOptionDown: whether Right Option is down after the change.
    ///   - otherModifiersDown: whether ⌘, ⌃, ⇧, Fn or Left Option are down.
    mutating func modifiersChanged(
        keyCode: UInt16,
        rightOptionDown: Bool,
        otherModifiersDown: Bool,
        at time: TimeInterval
    ) -> Bool {
        guard keyCode == Self.rightOptionKeyCode else {
            // Another modifier joined in while Right Option was held: a combo.
            if pressStart != nil { spoiled = true }
            return false
        }

        if rightOptionDown {
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
        return held >= 0 && held < Self.tapMaxDuration
    }

    /// A key, mouse button or anything else happened. While Right Option is
    /// down this turns the press into a combo, never a tap.
    mutating func otherInput() {
        if pressStart != nil { spoiled = true }
    }

    /// Forgets any press in flight, e.g. when the listener restarts.
    mutating func reset() {
        pressStart = nil
        spoiled = false
    }
}
