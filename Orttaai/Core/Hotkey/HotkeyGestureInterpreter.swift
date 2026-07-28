// HotkeyGestureInterpreter.swift
// Orttaai

import Foundation

/// Pure tap-vs-hold disambiguation for the shared push-to-talk hotkey.
///
/// Recording always starts on key-down (never waiting for disambiguation);
/// this interpreter only decides what the matching key-up means:
/// - Released before `tapMaxDuration` with hands-free enabled → the press was
///   a TAP: keep recording and promote it to hands-free mode.
/// - Released at/after the threshold (or hands-free disabled) → the press was
///   a HOLD: stop and finalize, exactly like classic push-to-talk.
///
/// Timestamps are injected so the logic is fully deterministic under test —
/// no wall-clock reads live here.
struct HotkeyGestureInterpreter {
    /// A press-and-release shorter than this reads as a tap. Holding for this
    /// long or longer keeps push-to-talk semantics (release = stop).
    static let tapMaxDuration: TimeInterval = 0.35

    enum ReleaseAction: Equatable {
        /// Hold released: stop recording and finalize.
        case stopRecording
        /// Tap detected: keep recording, switch to hands-free mode.
        case promoteToHandsFree
        /// No press was recorded for this release (e.g. the key-up following
        /// the tap that stopped a hands-free session) — do nothing.
        case ignore
    }

    private(set) var pressStart: TimeInterval?

    /// Records the key-down that started (or attempted to start) recording.
    mutating func recordPress(at time: TimeInterval) {
        pressStart = time
    }

    /// Forgets any in-flight press, e.g. when recording failed to start or a
    /// key-down was consumed as a hands-free stop.
    mutating func reset() {
        pressStart = nil
    }

    /// Consumes the recorded press and classifies the release. A release with
    /// no recorded press is ignored. Non-monotonic timestamps (release before
    /// press) classify as a hold so recording always has a way to stop.
    mutating func evaluateRelease(
        at time: TimeInterval,
        handsFreeEnabled: Bool
    ) -> ReleaseAction {
        guard let start = pressStart else { return .ignore }
        pressStart = nil

        let heldDuration = time - start
        if handsFreeEnabled, heldDuration >= 0, heldDuration < Self.tapMaxDuration {
            return .promoteToHandsFree
        }
        return .stopRecording
    }
}
