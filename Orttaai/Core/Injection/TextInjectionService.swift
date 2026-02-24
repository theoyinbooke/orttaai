// TextInjectionService.swift
// Orttaai

import Cocoa
import os

enum InjectionResult: Equatable {
    case success
    case blockedSecureField
    case noTranscript
}

struct InjectionTelemetry: Sendable {
    let appActivationMs: Int
    let clipboardRestoreDelayMs: Int
    let totalInjectionMs: Int
    let targetBundleID: String?
}

protocol TextInjecting: AnyObject {
    var lastTranscript: String? { get }
    var lastInjectionTelemetry: InjectionTelemetry? { get }
    var lowLatencyModeEnabled: Bool { get set }
    func inject(text: String, targetApp: NSRunningApplication?) async -> InjectionResult
    func pasteLastTranscript(targetApp: NSRunningApplication?) async -> InjectionResult
}

extension TextInjecting {
    var lastInjectionTelemetry: InjectionTelemetry? { nil }
    var lowLatencyModeEnabled: Bool {
        get { false }
        set {}
    }

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
    private(set) var lastInjectionTelemetry: InjectionTelemetry?
    var lowLatencyModeEnabled: Bool = false
    private var adaptiveTimingByApp: [String: AdaptiveInjectionTiming] = [:]

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
        let injectionStart = CFAbsoluteTimeGetCurrent()
        lastInjectionTelemetry = nil

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
        let appKey = adaptiveKey(for: appToActivate)
        let timingProfile = adaptiveTiming(for: appKey, textLength: text.count)
        let activationMs = await activateTargetAppIfNeeded(
            appToActivate,
            timeoutMs: timingProfile.activationTimeoutMs
        )

        if let app = appToActivate, app.bundleIdentifier != Bundle.main.bundleIdentifier {
            Logger.injection.info("Target app active: \(app.isActive), bundle: \(app.bundleIdentifier ?? "?")")
        }

        // Step 6: Simulate paste
        simulatePaste()

        // Step 7: Wait for paste to complete
        let restoreDelayMs = resolvedRestoreDelayMs(
            for: timingProfile,
            activationMs: activationMs,
            activationSucceeded: appToActivate?.isActive ?? true
        )
        try? await Task.sleep(nanoseconds: UInt64(restoreDelayMs) * 1_000_000)

        // Step 8: Restore pasteboard
        clipboard.restore(saved)

        let injectionMs = Int((CFAbsoluteTimeGetCurrent() - injectionStart) * 1000)
        let activationSucceeded = appToActivate?.isActive ?? true
        updateAdaptiveTiming(
            for: appKey,
            activationMs: activationMs,
            restoreDelayMs: restoreDelayMs,
            activationSucceeded: activationSucceeded
        )
        lastInjectionTelemetry = InjectionTelemetry(
            appActivationMs: activationMs,
            clipboardRestoreDelayMs: restoreDelayMs,
            totalInjectionMs: injectionMs,
            targetBundleID: appToActivate?.bundleIdentifier
        )

        Logger.injection.info(
            "Text injected: \(text.prefix(50))... [activation=\(activationMs)ms, restoreDelay=\(restoreDelayMs)ms, total=\(injectionMs)ms]"
        )
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

    private func activateTargetAppIfNeeded(
        _ app: NSRunningApplication?,
        timeoutMs: Int
    ) async -> Int {
        guard let app, app.bundleIdentifier != Bundle.main.bundleIdentifier else {
            return 0
        }

        let start = CFAbsoluteTimeGetCurrent()
        _ = app.activate()
        if app.isActive {
            return Int((CFAbsoluteTimeGetCurrent() - start) * 1000)
        }

        let pollIntervalNs: UInt64 = 10_000_000 // 10ms
        let timeoutNs = UInt64(max(0, timeoutMs)) * 1_000_000
        var elapsedNs: UInt64 = 0

        while elapsedNs < timeoutNs, !app.isActive {
            try? await Task.sleep(nanoseconds: pollIntervalNs)
            elapsedNs += pollIntervalNs
        }

        return Int((CFAbsoluteTimeGetCurrent() - start) * 1000)
    }

    private func adaptiveKey(for app: NSRunningApplication?) -> String {
        guard let bundleID = app?.bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines),
              !bundleID.isEmpty else {
            return lowLatencyModeEnabled ? "ll:__default__" : "std:__default__"
        }
        return lowLatencyModeEnabled ? "ll:\(bundleID)" : "std:\(bundleID)"
    }

    private func adaptiveTiming(for appKey: String, textLength: Int) -> AdaptiveInjectionTiming {
        let baseline = lowLatencyModeEnabled ? AdaptiveInjectionTiming.lowLatencyDefault : AdaptiveInjectionTiming.default
        let current = adaptiveTimingByApp[appKey] ?? baseline
        let textComplexityBoost = min(35, Int(Double(max(textLength, 1)).squareRoot() * 2.3))
        let timeout = clamp(
            current.activationTimeoutMs + textComplexityBoost / 3,
            min: 55,
            max: lowLatencyModeEnabled ? 260 : 450
        )
        let restore = clamp(
            current.restoreDelayMs + textComplexityBoost,
            min: 30,
            max: lowLatencyModeEnabled ? 150 : 240
        )
        return AdaptiveInjectionTiming(activationTimeoutMs: timeout, restoreDelayMs: restore)
    }

    private func resolvedRestoreDelayMs(
        for timing: AdaptiveInjectionTiming,
        activationMs: Int,
        activationSucceeded: Bool
    ) -> Int {
        var delay = timing.restoreDelayMs
        if activationMs > 140 {
            delay += lowLatencyModeEnabled ? 10 : 18
        }
        if !activationSucceeded {
            delay = max(delay, lowLatencyModeEnabled ? 100 : 130)
        }
        return clamp(delay, min: 30, max: lowLatencyModeEnabled ? 170 : 260)
    }

    private func updateAdaptiveTiming(
        for appKey: String,
        activationMs: Int,
        restoreDelayMs: Int,
        activationSucceeded: Bool
    ) {
        let baseline = lowLatencyModeEnabled ? AdaptiveInjectionTiming.lowLatencyDefault : AdaptiveInjectionTiming.default
        let current = adaptiveTimingByApp[appKey] ?? baseline
        let activationTarget = clamp(
            activationMs + (activationSucceeded ? 28 : 110),
            min: 60,
            max: lowLatencyModeEnabled ? 300 : 460
        )
        let restoreTarget = clamp(
            activationSucceeded ? max(30, restoreDelayMs - 10) : restoreDelayMs + 22,
            min: 30,
            max: lowLatencyModeEnabled ? 170 : 260
        )

        let updated = AdaptiveInjectionTiming(
            activationTimeoutMs: ewma(current.activationTimeoutMs, activationTarget, alpha: 0.25),
            restoreDelayMs: ewma(current.restoreDelayMs, restoreTarget, alpha: 0.22)
        )
        adaptiveTimingByApp[appKey] = updated
    }

    private func ewma(_ current: Int, _ target: Int, alpha: Double) -> Int {
        Int((Double(current) * (1 - alpha) + Double(target) * alpha).rounded())
    }

    private func clamp(_ value: Int, min minValue: Int, max maxValue: Int) -> Int {
        Swift.max(minValue, Swift.min(maxValue, value))
    }
}

private struct AdaptiveInjectionTiming {
    var activationTimeoutMs: Int
    var restoreDelayMs: Int

    static let `default` = AdaptiveInjectionTiming(
        activationTimeoutMs: 140,
        restoreDelayMs: 90
    )

    static let lowLatencyDefault = AdaptiveInjectionTiming(
        activationTimeoutMs: 95,
        restoreDelayMs: 52
    )
}
