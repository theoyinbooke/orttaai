// TextInjectionService.swift
// Orttaai

import Cocoa
import os

/// How the transcript actually landed in the target app. Persisted with each
/// history entry so telemetry stays honest about the delivery mechanism.
enum InjectionMethod: String, Equatable, Sendable {
    case paste
    case unverifiedPaste = "unverified_paste"
    case axInsert = "ax"
    case typed
    case failed
}

enum InjectionResult: Equatable {
    case success(method: InjectionMethod)
    case blockedSecureField
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

enum UnverifiedPastePolicy: Equatable, Sendable {
    case assumeDeliveredAndRestoreClipboard
    case guardedRestoreAfterUnverifiedSuccess
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
    var lastInjectionTelemetry: InjectionTelemetry? { get }
    var lowLatencyModeEnabled: Bool { get set }
    func inject(text: String, targetApp: NSRunningApplication?) async -> InjectionResult
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
}

final class TextInjectionService: TextInjecting {
    private let clipboard: any ClipboardManaging
    private let inspector: any AccessibilityInspecting
    private let keyPoster: any KeyEventPosting
    private let unverifiedPastePolicyProvider: (String?) -> UnverifiedPastePolicy
    /// Whether an app is the one in front, and asking it to come forward;
    /// seams for tests, which can't move real apps.
    private let isInFront: (NSRunningApplication) -> Bool
    private let requestFront: (NSRunningApplication) -> Void
    private let returnTimeoutMs: Int
    private(set) var lastInjectionTelemetry: InjectionTelemetry?
    var lowLatencyModeEnabled: Bool = false
    private var adaptiveTimingByApp: [String: AdaptiveInjectionTiming] = [:]

    /// Extra verification polls after the first read reports a failed paste,
    /// covering apps that commit the pasted text a beat late.
    static let verificationRetryPolls = 3
    static let verificationPollIntervalNs: UInt64 = 40_000_000 // 40ms
    /// While waiting for a paste to land, the field is first read this soon
    /// after the paste chord, then every `pasteDeliveryPollMs`.
    static let pasteDeliveryFirstCheckMs = 15
    static let pasteDeliveryPollMs = 10
    static let codexBundleID = "com.openai.codex"
    /// How long the transcript stays on Codex's clipboard after the paste
    /// when the field doesn't show it sooner. Measured in October 2026,
    /// Codex read the clipboard within 115 ms of the paste, about 40 ms
    /// typically.
    static let codexPasteBudgetMs = 150
    /// How long a paste waits for its app to come back to the front after
    /// something else took it while the dictation was processed. Since
    /// macOS 14 an app that isn't in front itself (Orttaai lives in the menu
    /// bar) can't bring another one forward: in 60 days to October 2026, none
    /// of the 26 apps Orttaai asked to come forward did, and each paste
    /// failed. In the latest, a system alert held the front and ChatGPT came
    /// back 3 s after the paste gave up.
    static let targetReturnTimeoutMs = 8_000
    static let targetReturnPollMs = 50

    init(
        clipboard: any ClipboardManaging = ClipboardManager(),
        inspector: any AccessibilityInspecting = SystemAccessibilityInspector(),
        keyPoster: any KeyEventPosting = CGKeyEventPoster(),
        unverifiedPastePolicy: @escaping (String?) -> UnverifiedPastePolicy = {
            TextInjectionService.unverifiedPastePolicy(targetBundleID: $0)
        },
        isInFront: @escaping (NSRunningApplication) -> Bool = { $0.isActive },
        requestFront: @escaping (NSRunningApplication) -> Void = { _ = $0.activate() },
        returnTimeoutMs: Int = TextInjectionService.targetReturnTimeoutMs
    ) {
        self.clipboard = clipboard
        self.inspector = inspector
        self.keyPoster = keyPoster
        self.unverifiedPastePolicyProvider = unverifiedPastePolicy
        self.isInFront = isInFront
        self.requestFront = requestFront
        self.returnTimeoutMs = returnTimeoutMs
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
        let postExposesText = (postSnapshot.value?.isEmpty == false)
            || (postSnapshot.selectedText?.isEmpty == false)
        guard postExposesText else {
            // Element exposes no text to AX — nil attributes (canvas editors)
            // or empty strings (terminals like Ghostty/cmux report "" for the
            // screen even after a paste lands in the running TUI). We cannot
            // judge, so we must not trigger fallbacks: a false `.failed` here
            // double-pastes and fires an AX insert that selects the whole
            // terminal screen.
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

    static func unverifiedPastePolicy(targetBundleID: String?) -> UnverifiedPastePolicy {
        guard targetBundleID?.caseInsensitiveCompare(codexBundleID) == .orderedSame else {
            return .assumeDeliveredAndRestoreClipboard
        }
        return .guardedRestoreAfterUnverifiedSuccess
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
        // Each step's time, for the timing line logged at the end.
        var stepStart = injectionStart
        func stepMs() -> Int {
            let now = CFAbsoluteTimeGetCurrent()
            defer { stepStart = now }
            return Int((now - stepStart) * 1000)
        }

        // Step 1: Check for a secure field before touching the clipboard.
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
        let secureCheckMs = stepMs()

        // Step 2: Save current pasteboard, then stage the transcript on it.
        var saved = await clipboard.save(giveUpAfterMs: ClipboardManager.saveLimitMs)
        if saved == nil {
            Logger.injection.warning(
                "Saving the clipboard took over \(ClipboardManager.saveLimitMs) ms; pasting without it, so the transcript stays on the clipboard"
            )
        }
        clipboard.setString(text)
        var stagedClipboardChangeCount = clipboard.changeCount
        let clipboardSaveMs = stepMs()

        // Step 4: Activate the target app so the paste goes to it, not Orttaai.
        let appKey = adaptiveKey(for: appToActivate)
        let targetBundleID = appToActivate?.bundleIdentifier
        let unverifiedPolicy = unverifiedPastePolicyProvider(targetBundleID)
        let timingProfile = adaptiveTiming(for: appKey, textLength: text.count)
        let wasInFront = appToActivate.map(isInFront) ?? true
        var activationMs = await activateTargetAppIfNeeded(
            appToActivate,
            timeoutMs: timingProfile.activationTimeoutMs
        )
        var returnWaitMs = 0

        if let app = appToActivate, app.bundleIdentifier != Bundle.main.bundleIdentifier {
            let inFront = isInFront(app)
            Logger.injection.info("Target app active: \(inFront), bundle: \(app.bundleIdentifier ?? "?")")
            if !inFront {
                // Something else took the front while this dictation was
                // processed, and the app can't be brought back: wait for it.
                returnWaitMs = await waitForReturn(of: app)
                if isInFront(app) {
                    // Meanwhile another field may have been focused, or
                    // something else copied: check the field again, and stage
                    // the transcript again over the newer copy, which goes
                    // back afterwards instead.
                    if Self.assessSecureField(inspector.focusedElementDetails(processIdentifier: targetPid)) == .blocked {
                        restoreClipboardIfUnchanged(saved, expectedChangeCount: stagedClipboardChangeCount)
                        Logger.injection.info("Blocked: focused element is a secure text field")
                        return .blockedSecureField
                    }
                    if clipboard.changeCount != stagedClipboardChangeCount {
                        saved = await clipboard.save(giveUpAfterMs: ClipboardManager.saveLimitMs)
                        clipboard.setString(text)
                        stagedClipboardChangeCount = clipboard.changeCount
                    }
                }
            }
            guard isInFront(app) else {
                let injectionMs = Int((CFAbsoluteTimeGetCurrent() - injectionStart) * 1000)
                clipboard.setString(text)
                lastInjectionTelemetry = InjectionTelemetry(
                    appActivationMs: activationMs + returnWaitMs,
                    clipboardRestoreDelayMs: 0,
                    totalInjectionMs: injectionMs,
                    targetBundleID: targetBundleID,
                    method: .failed,
                    pasteAttempts: 0
                )
                Logger.injection.error(
                    "Target app did not become active. Transcript left on clipboard"
                )
                return .failedAllMethods
            }
        }

        // Step 5: Snapshot the focused element's text so verification can
        // detect "nothing changed" after the synthetic paste.
        let activationStepMs = stepMs()
        let preSnapshot = inspector.focusedElementTextSnapshot(processIdentifier: targetPid)
        let snapshotMs = stepMs()

        // Step 6: Paste + bounded verification, with one activation+paste retry.
        var restoreDelayMs = 0
        var pasteWaitMs = 0
        var verdict: PasteVerificationOutcome = .failed
        var pasteAttempts = 0
        var method: InjectionMethod = .paste
        var settleMs = 0

        for attempt in 1...2 {
            if attempt == 2 {
                // Retry: re-activate in case the first paste raced focus transfer.
                Logger.injection.warning("Paste verification failed; retrying activation + paste")
                activationMs += await activateTargetAppIfNeeded(
                    appToActivate,
                    timeoutMs: timingProfile.activationTimeoutMs
                )
            }

            // Brief stabilization delay after activation so the window server
            // finishes transferring keyboard focus before the CGEvent arrives.
            if unverifiedPolicy == .guardedRestoreAfterUnverifiedSuccess {
                // Codex's Electron editor transfers focus and consumes the
                // pasteboard asynchronously. Give it a real focus-settling
                // window before sending the single, non-duplicating paste.
                try? await Task.sleep(nanoseconds: 120_000_000) // 120ms
            } else if !wasInFront || attempt == 2 {
                // Only when focus moved. Activating an app already in front
                // often takes 1-4 ms, which added this pause to about half of
                // all pastes, with no focus to transfer.
                try? await Task.sleep(nanoseconds: 30_000_000) // 30ms
            }
            if attempt == 1 { settleMs = stepMs() }

            keyPoster.postPasteChord()
            pasteAttempts += 1

            if unverifiedPolicy == .guardedRestoreAfterUnverifiedSuccess {
                // The clipboard goes back as soon as the text shows up in the
                // field, or after Codex's budget. Codex is never pasted twice:
                // it can commit a paste later than Accessibility shows it, so
                // one that hasn't shown up yet still counts as sent.
                restoreDelayMs += Self.codexPasteBudgetMs
                let delivery = await awaitPasteDelivery(
                    expectedText: text,
                    pre: preSnapshot,
                    pid: targetPid,
                    budgetMs: Self.codexPasteBudgetMs,
                    verifiesAfterBudget: false
                )
                pasteWaitMs += delivery.waitedMs
                verdict = delivery.outcome == .confirmed ? .confirmed : .inconclusive
                break
            }

            // Wait for the paste to be delivered before verifying/restoring.
            let delay = resolvedRestoreDelayMs(
                for: timingProfile,
                activationMs: activationMs,
                activationSucceeded: appToActivate.map(isInFront) ?? true
            )
            restoreDelayMs += delay
            let delivery = await awaitPasteDelivery(
                expectedText: text, pre: preSnapshot, pid: targetPid, budgetMs: delay
            )
            pasteWaitMs += delivery.waitedMs
            verdict = delivery.outcome
            if verdict != .failed { break }
        }

        // Step 7: Fallbacks — AX insertion, then typed unicode keystrokes.
        if verdict == .failed {
            Logger.injection.warning("Paste retry failed verification; attempting AX insertion")
            if inspector.insertTextAtFocus(text, processIdentifier: targetPid) {
                verdict = await verifyInjection(expectedText: text, pre: preSnapshot, pid: targetPid)
                if verdict != .failed {
                    method = .axInsert
                }
            }
        }

        if verdict == .failed {
            Logger.injection.warning("AX insertion failed; attempting typed keystrokes")
            keyPoster.postTypedText(text)
            try? await Task.sleep(nanoseconds: 60_000_000) // 60ms for events to land
            verdict = await verifyInjection(expectedText: text, pre: preSnapshot, pid: targetPid)
            if verdict != .failed {
                method = .typed
            }
        }

        let activationSucceeded = appToActivate.map(isInFront) ?? true
        updateAdaptiveTiming(
            for: appKey,
            activationMs: activationMs,
            restoreDelayMs: max(restoreDelayMs, 30),
            activationSucceeded: activationSucceeded
        )

        let injectionMs = Int((CFAbsoluteTimeGetCurrent() - injectionStart) * 1000)
        // Numbers only, kept by the system log (notice level), for measuring
        // where a paste's time goes: `log show --predicate 'subsystem ==
        // "com.orttaai.app" AND category == "injection"'`.
        Logger.injection.notice(
            "Paste into \(targetBundleID ?? "?", privacy: .public): password check \(secureCheckMs) ms, clipboard save \(clipboardSaveMs) ms, activation \(activationStepMs) ms (\(wasInFront ? "already in front" : "brought to front", privacy: .public)), snapshot \(snapshotMs) ms, settle \(settleMs) ms, paste to confirmation \(pasteWaitMs) ms (\(String(describing: verdict), privacy: .public)), total \(injectionMs) ms"
        )

        if verdict == .failed {
            // Honest failure: keep the transcript on the clipboard (do NOT
            // restore the old pasteboard) so the user can paste manually.
            clipboard.setString(text)
            lastInjectionTelemetry = InjectionTelemetry(
                appActivationMs: activationMs + returnWaitMs,
                clipboardRestoreDelayMs: pasteWaitMs,
                totalInjectionMs: injectionMs,
                targetBundleID: appToActivate?.bundleIdentifier,
                method: .failed,
                pasteAttempts: pasteAttempts
            )
            Logger.injection.error(
                "All injection methods failed for \(appToActivate?.bundleIdentifier ?? "?", privacy: .public). Transcript left on clipboard"
            )
            return .failedAllMethods
        }

        if verdict == .inconclusive, unverifiedPolicy == .guardedRestoreAfterUnverifiedSuccess {
            // The text didn't show up in Codex's field within its budget, but
            // Codex has read the clipboard by then, so the single paste counts
            // as sent. Restore the prior clipboard only if no app or nearby
            // device replaced it in the meantime.
            let clipboardRestored = restoreClipboardIfUnchanged(
                saved,
                expectedChangeCount: stagedClipboardChangeCount
            )
            lastInjectionTelemetry = InjectionTelemetry(
                appActivationMs: activationMs + returnWaitMs,
                clipboardRestoreDelayMs: pasteWaitMs,
                totalInjectionMs: injectionMs,
                targetBundleID: targetBundleID,
                method: .unverifiedPaste,
                pasteAttempts: pasteAttempts
            )
            if clipboardRestored {
                Logger.injection.info(
                    "Codex paste sent but not seen in the field within \(Self.codexPasteBudgetMs) ms. Prior clipboard restored"
                )
            }
            return .success(method: .unverifiedPaste)
        }

        // Step 8: Restore pasteboard after a verified/assumed-good injection.
        restoreClipboardIfUnchanged(
            saved,
            expectedChangeCount: stagedClipboardChangeCount
        )

        lastInjectionTelemetry = InjectionTelemetry(
            appActivationMs: activationMs + returnWaitMs,
            clipboardRestoreDelayMs: pasteWaitMs,
            totalInjectionMs: injectionMs,
            targetBundleID: targetBundleID,
            method: method,
            pasteAttempts: pasteAttempts
        )

        Logger.injection.info(
            "Text injected via \(method.rawValue, privacy: .public): \(text.prefix(50))... [activation=\(activationMs)ms, restoreDelay=\(restoreDelayMs)ms, total=\(injectionMs)ms, verification=\(String(describing: verdict), privacy: .public)]"
        )
        return .success(method: method)
    }

    /// Restores the clipboard only while the transcript staged by this
    /// injection is still the newest pasteboard write. This prevents a copy
    /// from another Mac app or Universal Clipboard from being overwritten by
    /// a delayed restore. With nothing saved, the transcript stays.
    @discardableResult
    private func restoreClipboardIfUnchanged(
        _ saved: [ClipboardManager.SavedItem]?,
        expectedChangeCount: Int
    ) -> Bool {
        guard let saved else { return false }
        guard clipboard.changeCount == expectedChangeCount else {
            Logger.injection.info(
                "Clipboard changed after transcript staging; preserving newer contents"
            )
            return false
        }
        clipboard.restore(saved)
        return true
    }

    // MARK: - Verification

    /// Waits up to `budgetMs` for the paste to land. Text that shows up in the
    /// field means the app has read the pasteboard, so the clipboard can be
    /// restored straight away rather than after the whole budget. A field
    /// Accessibility can't read gives no such signal and waits the budget
    /// out, as before; a field that still lacks the text when the budget ends
    /// gets the usual verification polls, unless `verifiesAfterBudget` is off.
    private func awaitPasteDelivery(
        expectedText: String,
        pre: AXInspection<FocusedTextSnapshot>,
        pid: pid_t?,
        budgetMs: Int,
        verifiesAfterBudget: Bool = true
    ) async -> (outcome: PasteVerificationOutcome, waitedMs: Int) {
        let start = CFAbsoluteTimeGetCurrent()
        func elapsedMs() -> Int { Int((CFAbsoluteTimeGetCurrent() - start) * 1000) }
        func sleep(_ ms: Int) async {
            guard ms > 0 else { return }
            try? await Task.sleep(nanoseconds: UInt64(ms) * 1_000_000)
        }

        await sleep(min(budgetMs, Self.pasteDeliveryFirstCheckMs))
        while true {
            let post = inspector.focusedElementTextSnapshot(processIdentifier: pid)
            let outcome = Self.evaluatePasteVerification(pre: pre, post: post, expectedText: expectedText)
            let remaining = budgetMs - elapsedMs()
            switch outcome {
            case .confirmed:
                return (.confirmed, elapsedMs())
            case .inconclusive:
                await sleep(remaining)
                return (.inconclusive, elapsedMs())
            case .failed:
                guard remaining > 0 else {
                    guard verifiesAfterBudget else { return (.failed, elapsedMs()) }
                    return (await verifyInjection(expectedText: expectedText, pre: pre, pid: pid), elapsedMs())
                }
                await sleep(min(remaining, Self.pasteDeliveryPollMs))
            }
        }
    }

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
        requestFront(app)
        if isInFront(app) {
            return Int((CFAbsoluteTimeGetCurrent() - start) * 1000)
        }

        let pollIntervalNs: UInt64 = 10_000_000 // 10ms
        let timeoutNs = UInt64(max(0, timeoutMs)) * 1_000_000
        var elapsedNs: UInt64 = 0

        while elapsedNs < timeoutNs, !isInFront(app) {
            try? await Task.sleep(nanoseconds: pollIntervalNs)
            elapsedNs += pollIntervalNs
        }

        return Int((CFAbsoluteTimeGetCurrent() - start) * 1000)
    }

    /// Waits up to `returnTimeoutMs` for `app` to come back to the front,
    /// and returns how long it waited.
    private func waitForReturn(of app: NSRunningApplication) async -> Int {
        let start = CFAbsoluteTimeGetCurrent()
        func waitedMs() -> Int { Int((CFAbsoluteTimeGetCurrent() - start) * 1000) }
        let bundleID = app.bundleIdentifier ?? "?"
        Logger.injection.notice("\(bundleID, privacy: .public) isn't in front; waiting for it to come back")
        while !isInFront(app), !app.isTerminated, waitedMs() < returnTimeoutMs {
            try? await Task.sleep(nanoseconds: UInt64(Self.targetReturnPollMs) * 1_000_000)
        }
        let waited = waitedMs()
        let cameBack = isInFront(app)
        Logger.injection.notice(
            "\(bundleID, privacy: .public) \(cameBack ? "came back" : "didn't come back", privacy: .public) after \(waited) ms"
        )
        return waited
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
