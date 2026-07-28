// TextInjectionService.swift
// Orttaai

import Cocoa
import os

/// How the transcript actually landed in the target app. Persisted with each
/// history entry so telemetry stays honest about the delivery mechanism.
enum InjectionMethod: String, Equatable, Sendable {
    case paste
    case axInsert = "ax"
    case typed
    case failed
}

enum InjectionResult: Equatable {
    case success(method: InjectionMethod)
    case blockedSecureField
    case noTranscript
    /// Paste, retry, AX insertion, and typed keystrokes all verifiably failed.
    /// The transcript is left on the clipboard so the user can Cmd+V it.
    case failedAllMethods
}

/// Outcome of the secure-field guard. The policy is: an AX API failure keeps
/// the historical fail-open behavior, but a successfully inspected element
/// that looks like a password field blocks injection.
enum SecureFieldAssessment: Equatable, Sendable {
    case blocked
    case allowedInspectedNormal
    case allowedAXError
}

/// Outcome of post-paste verification.
enum PasteVerificationOutcome: Equatable, Sendable {
    /// The focused element's text observably received the transcript
    /// (contains it, or changed relative to the pre-paste snapshot).
    case confirmed
    /// The focused element's text was readable both before and after, did not
    /// change, and does not contain the transcript — the paste did not land.
    case failed
    /// AX could not read enough to judge (no permission, no value attribute).
    /// Treated as success so apps that hide their text from AX never trigger
    /// duplicate-inserting fallbacks.
    case inconclusive
}

struct InjectionTelemetry: Sendable {
    let appActivationMs: Int
    let clipboardRestoreDelayMs: Int
    let totalInjectionMs: Int
    let targetBundleID: String?
    let method: InjectionMethod
    /// Number of synthetic paste attempts made (0 when paste was skipped).
    let pasteAttempts: Int

    init(
        appActivationMs: Int,
        clipboardRestoreDelayMs: Int,
        totalInjectionMs: Int,
        targetBundleID: String?,
        method: InjectionMethod = .paste,
        pasteAttempts: Int = 1
    ) {
        self.appActivationMs = appActivationMs
        self.clipboardRestoreDelayMs = clipboardRestoreDelayMs
        self.totalInjectionMs = totalInjectionMs
        self.targetBundleID = targetBundleID
        self.method = method
        self.pasteAttempts = pasteAttempts
    }
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
    private let clipboard: any ClipboardManaging
    private let inspector: any AccessibilityInspecting
    private let keyPoster: any KeyEventPosting
    private(set) var lastTranscript: String?
    private(set) var lastInjectionTelemetry: InjectionTelemetry?
    var lowLatencyModeEnabled: Bool = false
    private var adaptiveTimingByApp: [String: AdaptiveInjectionTiming] = [:]

    /// Extra verification polls after the first read reports a failed paste,
    /// covering apps that commit the pasted text a beat late.
    static let verificationRetryPolls = 3
    static let verificationPollIntervalNs: UInt64 = 40_000_000 // 40ms

    init(
        clipboard: any ClipboardManaging = ClipboardManager(),
        inspector: any AccessibilityInspecting = SystemAccessibilityInspector(),
        keyPoster: any KeyEventPosting = CGKeyEventPoster()
    ) {
        self.clipboard = clipboard
        self.inspector = inspector
        self.keyPoster = keyPoster
    }

    // MARK: - Secure-field policy (pure decision logic)

    /// Decides whether the focused element is a secure/password field.
    /// - AX API errored (permission, timeout, no focused element): fail open.
    /// - Successfully inspected element with a secure subrole, or a role
    ///   description that identifies it as a password/secure input (how
    ///   Safari and Chromium describe web password fields): block.
    static func assessSecureField(_ inspection: AXInspection<FocusedElementDetails>) -> SecureFieldAssessment {
        switch inspection {
        case .axError:
            return .allowedAXError
        case .value(let details):
            if details.subrole == (kAXSecureTextFieldSubrole as String) {
                return .blocked
            }
            if let description = details.roleDescription?.lowercased() {
                if description.contains("password") || description.contains("secure") {
                    return .blocked
                }
            }
            return .allowedInspectedNormal
        }
    }

    // MARK: - Paste verification (pure decision logic)

    /// Judges whether an injection attempt landed, comparing the focused
    /// element's text before and after the attempt.
    static func evaluatePasteVerification(
        pre: AXInspection<FocusedTextSnapshot>,
        post: AXInspection<FocusedTextSnapshot>,
        expectedText: String
    ) -> PasteVerificationOutcome {
        guard case .value(let postSnapshot) = post else {
            return .inconclusive
        }
        guard postSnapshot.value != nil || postSnapshot.selectedText != nil else {
            // Element exposes no text to AX (canvas editors, terminals) —
            // we cannot judge, so we must not trigger fallbacks.
            return .inconclusive
        }

        let expected = Self.normalizedForComparison(expectedText)
        guard !expected.isEmpty else { return .inconclusive }
        let markers = Self.verificationMarkers(for: expected)

        let postTexts = [postSnapshot.value, postSnapshot.selectedText]
            .compactMap { $0 }
            .map(Self.normalizedForComparison)
        if postTexts.contains(where: { text in markers.contains(where: { text.contains($0) }) }) {
            return .confirmed
        }

        guard case .value(let preSnapshot) = pre, let preValue = preSnapshot.value else {
            // Cannot compare against a baseline — fail open rather than risk
            // a duplicate insert from a false negative.
            return .inconclusive
        }

        if let postValue = postSnapshot.value, postValue != preValue {
            // The field changed even though the marker is absent (the app may
            // transform pasted text). Treat as landed to avoid duplicates.
            return .confirmed
        }

        return .failed
    }

    private static func normalizedForComparison(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }

    /// Long transcripts may be head-truncated by bounded fields; accept a
    /// distinctive tail as evidence the paste landed.
    private static func verificationMarkers(for normalizedExpected: String) -> [String] {
        var markers = [normalizedExpected]
        if normalizedExpected.count > 160 {
            markers.append(String(normalizedExpected.suffix(64)))
        }
        return markers
    }

    // MARK: - Injection

    func isFocusedElementSecure(in targetApp: NSRunningApplication? = nil) -> Bool {
        let app = targetApp ?? NSWorkspace.shared.frontmostApplication
        let inspection = inspector.focusedElementDetails(processIdentifier: app?.processIdentifier)
        return Self.assessSecureField(inspection) == .blocked
    }

    func inject(text: String, targetApp: NSRunningApplication? = nil) async -> InjectionResult {
        let injectionStart = CFAbsoluteTimeGetCurrent()
        lastInjectionTelemetry = nil

        // Step 1: Check for secure field BEFORE setting lastTranscript.
        // Use the target app (captured at recording start) so we check
        // the correct app, not whatever happens to be frontmost now.
        let appToActivate = targetApp ?? NSWorkspace.shared.frontmostApplication
        let targetPid = appToActivate?.processIdentifier
        let secureAssessment = Self.assessSecureField(
            inspector.focusedElementDetails(processIdentifier: targetPid)
        )
        if secureAssessment == .blocked {
            Logger.injection.info("Blocked: focused element is a secure text field")
            return .blockedSecureField
        }

        // Step 2: Set lastTranscript only after secure field check passes
        lastTranscript = text

        // Step 3: Save current pasteboard, then stage the transcript on it
        let saved = clipboard.save()
        clipboard.setString(text)

        // Step 4: Activate the target app so the paste goes to it, not Orttaai.
        let appKey = adaptiveKey(for: appToActivate)
        let timingProfile = adaptiveTiming(for: appKey, textLength: text.count)
        var activationMs = await activateTargetAppIfNeeded(
            appToActivate,
            timeoutMs: timingProfile.activationTimeoutMs
        )

        if let app = appToActivate, app.bundleIdentifier != Bundle.main.bundleIdentifier {
            Logger.injection.info("Target app active: \(app.isActive), bundle: \(app.bundleIdentifier ?? "?")")
        }

        // Step 5: Snapshot the focused element's text so verification can
        // detect "nothing changed" after the synthetic paste.
        let preSnapshot = inspector.focusedElementTextSnapshot(processIdentifier: targetPid)

        // Step 6: Paste + bounded verification, with one activation+paste retry.
        var restoreDelayMs = 0
        var verdict: PasteVerificationOutcome = .failed
        var pasteAttempts = 0
        var method: InjectionMethod = .paste

        for attempt in 1...2 {
            if attempt == 2 {
                // Retry: re-activate in case the first paste raced focus transfer.
                Logger.injection.warning("Paste verification failed — retrying activation + paste")
                activationMs += await activateTargetAppIfNeeded(
                    appToActivate,
                    timeoutMs: timingProfile.activationTimeoutMs
                )
            }

            // Brief stabilization delay after activation so the window server
            // finishes transferring keyboard focus before the CGEvent arrives.
            if activationMs > 0 {
                try? await Task.sleep(nanoseconds: 30_000_000) // 30ms
            }

            keyPoster.postPasteChord()
            pasteAttempts += 1

            // Wait for the paste to be delivered before verifying/restoring.
            let delay = resolvedRestoreDelayMs(
                for: timingProfile,
                activationMs: activationMs,
                activationSucceeded: appToActivate?.isActive ?? true
            )
            restoreDelayMs += delay
            try? await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000)

            verdict = await verifyInjection(expectedText: text, pre: preSnapshot, pid: targetPid)
            if verdict != .failed { break }
        }

        // Step 7: Fallbacks — AX insertion, then typed unicode keystrokes.
        if verdict == .failed {
            Logger.injection.warning("Paste retry failed verification — attempting AX insertion")
            if inspector.insertTextAtFocus(text, processIdentifier: targetPid) {
                verdict = await verifyInjection(expectedText: text, pre: preSnapshot, pid: targetPid)
                if verdict != .failed {
                    method = .axInsert
                }
            }
        }

        if verdict == .failed {
            Logger.injection.warning("AX insertion failed — attempting typed keystrokes")
            keyPoster.postTypedText(text)
            try? await Task.sleep(nanoseconds: 60_000_000) // 60ms for events to land
            verdict = await verifyInjection(expectedText: text, pre: preSnapshot, pid: targetPid)
            if verdict != .failed {
                method = .typed
            }
        }

        let activationSucceeded = appToActivate?.isActive ?? true
        updateAdaptiveTiming(
            for: appKey,
            activationMs: activationMs,
            restoreDelayMs: max(restoreDelayMs, 30),
            activationSucceeded: activationSucceeded
        )

        let injectionMs = Int((CFAbsoluteTimeGetCurrent() - injectionStart) * 1000)

        if verdict == .failed {
            // Honest failure: keep the transcript on the clipboard (do NOT
            // restore the old pasteboard) so the user can paste manually.
            clipboard.setString(text)
            lastInjectionTelemetry = InjectionTelemetry(
                appActivationMs: activationMs,
                clipboardRestoreDelayMs: restoreDelayMs,
                totalInjectionMs: injectionMs,
                targetBundleID: appToActivate?.bundleIdentifier,
                method: .failed,
                pasteAttempts: pasteAttempts
            )
            Logger.injection.error(
                "All injection methods failed for \(appToActivate?.bundleIdentifier ?? "?", privacy: .public) — transcript left on clipboard"
            )
            return .failedAllMethods
        }

        // Step 8: Restore pasteboard after a verified/assumed-good injection.
        clipboard.restore(saved)

        lastInjectionTelemetry = InjectionTelemetry(
            appActivationMs: activationMs,
            clipboardRestoreDelayMs: restoreDelayMs,
            totalInjectionMs: injectionMs,
            targetBundleID: appToActivate?.bundleIdentifier,
            method: method,
            pasteAttempts: pasteAttempts
        )

        Logger.injection.info(
            "Text injected via \(method.rawValue, privacy: .public): \(text.prefix(50))... [activation=\(activationMs)ms, restoreDelay=\(restoreDelayMs)ms, total=\(injectionMs)ms, verification=\(String(describing: verdict), privacy: .public)]"
        )
        return .success(method: method)
    }

    func pasteLastTranscript(targetApp: NSRunningApplication? = nil) async -> InjectionResult {
        guard let transcript = lastTranscript else {
            Logger.injection.info("No last transcript to paste")
            return .noTranscript
        }
        return await inject(text: transcript, targetApp: targetApp)
    }

    // MARK: - Verification

    /// One cheap AX read on the happy path; a few short polls only when the
    /// first read says the text has not landed yet.
    private func verifyInjection(
        expectedText: String,
        pre: AXInspection<FocusedTextSnapshot>,
        pid: pid_t?
    ) async -> PasteVerificationOutcome {
        var polls = 0
        while true {
            let post = inspector.focusedElementTextSnapshot(processIdentifier: pid)
            let outcome = Self.evaluatePasteVerification(pre: pre, post: post, expectedText: expectedText)
            if outcome != .failed || polls >= Self.verificationRetryPolls {
                return outcome
            }
            polls += 1
            try? await Task.sleep(nanoseconds: Self.verificationPollIntervalNs)
        }
    }

    // MARK: - Activation & adaptive timing

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
