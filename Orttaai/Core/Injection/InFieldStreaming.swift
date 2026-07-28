// InFieldStreaming.swift
// Orttaai

import Cocoa
import os

// MARK: - Increment planning (pure)

/// Builds the exact keystroke increments for in-field streaming and tracks
/// the full span of text streamed so far. Mirrors the transcription
/// finalizer's merge semantics (single-space joins, whitespace collapsed) so
/// the streamed span stays a prefix-compatible rendition of the final raw
/// transcript. Increments never contain newlines — a streamed line break
/// could submit a form or execute a terminal command, so all whitespace is
/// flattened to single spaces.
struct StreamingIncrementPlanner: Equatable, Sendable {
    private(set) var streamedText: String = ""

    /// The keystrokes to type for a clip commit, or nil when the commit is
    /// silent/blank. Joins segments with a single space, exactly like
    /// `TranscriptionService.mergedLiveTranscript` joins committed clips.
    mutating func increment(forCommittedText text: String) -> String? {
        let flattened = TranscriptionService.normalizedTranscriptionText(text)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        guard !flattened.isEmpty else { return nil }

        let increment = streamedText.isEmpty ? flattened : " " + flattened
        streamedText += increment
        return increment
    }
}

// MARK: - Reconciliation planning (pure)

/// What finalize must do so the target field ends up containing exactly the
/// pipeline's final text, given what was already streamed.
enum StreamingReconciliationPlan: Equatable, Sendable {
    /// The streamed span already equals the final text — nothing to do.
    case alreadyExact
    /// The final text extends the streamed span — type only the remainder.
    case appendRemainder(String)
    /// The final text diverges from the streamed span after a common prefix:
    /// delete the divergent tail (`deleteCharacters` grapheme clusters of the
    /// streamed span) and insert the replacement. Never deletes more than
    /// what this session streamed.
    case replaceDivergentTail(deleteCharacters: Int, replacement: String)
    /// The field no longer contains the streamed span as the only change
    /// since streaming began (user typed mid-stream, the app transformed the
    /// text, or the field became unreadable). Destructive edits are unsafe —
    /// leave the field alone and fall back honestly.
    case abortFieldMismatch
}

enum StreamingReconciliation {
    /// Plans the finalize edit. `preStreamFieldValue` is the field's AX value
    /// captured before the first increment; `currentFieldValue` is the value
    /// read at finalize (nil when unreadable).
    static func plan(
        streamedText: String,
        finalText: String,
        preStreamFieldValue: String?,
        currentFieldValue: String?
    ) -> StreamingReconciliationPlan {
        guard !streamedText.isEmpty else {
            return finalText.isEmpty ? .alreadyExact : .appendRemainder(finalText)
        }
        guard let current = currentFieldValue.map(typographicallyNormalized) else {
            return .abortFieldMismatch
        }
        guard spliceMatches(
            pre: preStreamFieldValue.map(typographicallyNormalized),
            streamed: typographicallyNormalized(streamedText),
            current: current
        ) else {
            return .abortFieldMismatch
        }

        if finalText == streamedText {
            return .alreadyExact
        }

        let commonPrefixCount = commonPrefixCharacterCount(streamedText, finalText)
        let remainder = String(finalText.dropFirst(commonPrefixCount))
        if commonPrefixCount == streamedText.count {
            return .appendRemainder(remainder)
        }
        return .replaceDivergentTail(
            deleteCharacters: streamedText.count - commonPrefixCount,
            replacement: remainder
        )
    }

    /// True when `current` is exactly `pre` with `streamed` inserted at one
    /// position — i.e. the only change to the field since streaming began is
    /// the text this session typed. Detects user keystrokes and app-side
    /// transformations (autocorrect, smart quotes) that make caret-relative
    /// deletion unsafe. Without a pre-stream baseline, falls back to a
    /// containment check.
    static func spliceMatches(pre: String?, streamed: String, current: String) -> Bool {
        guard let pre else {
            return current.contains(streamed)
        }
        guard current.count == pre.count + streamed.count else {
            return false
        }
        var searchStart = current.startIndex
        while let range = current.range(of: streamed, range: searchStart..<current.endIndex) {
            var candidate = current
            candidate.removeSubrange(range)
            if candidate == pre {
                return true
            }
            guard range.lowerBound < current.endIndex else { break }
            searchStart = current.index(after: range.lowerBound)
        }
        return false
    }

    /// UTF-16 offsets (in the RAW `current` string) at which the streamed
    /// span can validly end — i.e. every splice position whose removal
    /// reproduces `pre`. Caret-relative edits are only safe when the caret
    /// sits at one of these offsets. Quote substitutions are folded 1:1 (so
    /// offsets stay valid); strings containing bare CR are not folded — a
    /// mismatch there simply yields no candidates, which callers treat
    /// conservatively.
    static func validCaretUTF16Offsets(pre: String?, streamed: String, current: String) -> [Int] {
        let foldedCurrent = quoteFolded(current)
        let foldedStreamed = quoteFolded(streamed)
        let foldedPre = pre.map(quoteFolded)
        guard !foldedStreamed.isEmpty else { return [] }

        var offsets: [Int] = []
        var searchStart = foldedCurrent.startIndex
        while let range = foldedCurrent.range(of: foldedStreamed, range: searchStart..<foldedCurrent.endIndex) {
            var isValid = true
            if let foldedPre {
                var candidate = foldedCurrent
                candidate.removeSubrange(range)
                isValid = candidate == foldedPre
            }
            if isValid {
                // Quote folding is strictly 1 character -> 1 character, so
                // character offsets in the folded string map directly onto
                // the raw string.
                let endCharOffset = foldedCurrent.distance(from: foldedCurrent.startIndex, to: range.upperBound)
                let rawEndIndex = current.index(current.startIndex, offsetBy: endCharOffset)
                offsets.append(current.utf16.distance(from: current.utf16.startIndex, to: rawEndIndex))
            }
            guard range.lowerBound < foldedCurrent.endIndex else { break }
            searchStart = foldedCurrent.index(after: range.lowerBound)
        }
        return offsets
    }

    /// Quote folding only (1:1 character swaps) — safe for offset math,
    /// unlike line-ending normalization which changes lengths.
    static func quoteFolded(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{2018}", with: "'")
            .replacingOccurrences(of: "\u{2019}", with: "'")
            .replacingOccurrences(of: "\u{201C}", with: "\"")
            .replacingOccurrences(of: "\u{201D}", with: "\"")
    }

    static func commonPrefixCharacterCount(_ a: String, _ b: String) -> Int {
        var count = 0
        var indexA = a.startIndex
        var indexB = b.startIndex
        while indexA < a.endIndex, indexB < b.endIndex, a[indexA] == b[indexB] {
            count += 1
            indexA = a.index(after: indexA)
            indexB = b.index(after: indexB)
        }
        return count
    }

    /// Same line-ending normalization as paste verification, so AX values
    /// from apps that report \r\n compare cleanly.
    static func normalized(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }

    /// Editors with smart substitutions rewrite typed straight quotes into
    /// typographic ones (verified live against TextEdit). Those are 1:1
    /// character swaps, so folding them keeps every count-based decision
    /// valid while stopping cosmetic substitutions from reading as
    /// user-typed-mid-stream mismatches.
    static func typographicallyNormalized(_ text: String) -> String {
        normalized(text)
            .replacingOccurrences(of: "\u{2018}", with: "'")
            .replacingOccurrences(of: "\u{2019}", with: "'")
            .replacingOccurrences(of: "\u{201C}", with: "\"")
            .replacingOccurrences(of: "\u{201D}", with: "\"")
    }
}

// MARK: - Safety gates (pure)

/// Why a session is not streaming into the field. Every reason falls back to
/// the pill-transcript display; none of them fails the dictation.
enum InFieldStreamingFallbackReason: String, Equatable, Sendable {
    /// The target app is a known terminal — streamed keystrokes could reach a
    /// shell prompt.
    case terminalBundle
    /// The focused element looks like a terminal screen: an AXTextArea whose
    /// value reads as the empty string (how Ghostty/cmux expose their grid;
    /// see the paste-verification history).
    case terminalHeuristic
    /// The focused element is a secure/password field.
    case secureField
    /// AX cannot read the focused element's text, so neither mid-stream
    /// verification nor finalize reconciliation could ever be judged.
    case unreadableField
    /// The target app is no longer frontmost — keystrokes would land in the
    /// wrong app. Streaming never re-activates the target mid-recording.
    case focusLost
    /// The field's text stopped matching the streamed span (the element
    /// swallowed the keystrokes, or the user edited mid-stream).
    case fieldMismatch
}

enum InFieldStreamingGate {
    /// Known terminal emulators by bundle ID. Streaming keystrokes into a
    /// shell is never safe regardless of what AX reports.
    static let terminalBundleIDs: Set<String> = [
        "com.apple.terminal",
        "com.googlecode.iterm2",
        "com.mitchellh.ghostty",
        "com.cmuxterm.app",
        "dev.warp.warp-stable",
        "dev.warp.warp",
        "net.kovidgoyal.kitty",
        "org.alacritty",
        "io.alacritty",
        "com.github.wez.wezterm",
        "co.zeit.hyper",
        "com.termius-dmg.mac",
        "dev.tabby",
        "com.raphaelamorim.rio"
    ]

    static func isTerminalBundleID(_ bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return terminalBundleIDs.contains(bundleID.lowercased())
    }

    /// Decides whether a session may start streaming into the focused
    /// element. Returns nil when streaming is allowed. Deliberately
    /// conservative: anything unverifiable falls back to the pill transcript,
    /// which works everywhere.
    static func assessStart(
        bundleID: String?,
        targetFrontmost: Bool,
        details: AXInspection<FocusedElementDetails>,
        snapshot: AXInspection<FocusedTextSnapshot>
    ) -> InFieldStreamingFallbackReason? {
        if isTerminalBundleID(bundleID) {
            return .terminalBundle
        }
        guard targetFrontmost else {
            return .focusLost
        }
        guard case .value(let elementDetails) = details else {
            // Unlike plain injection (which fails open on AX errors and pastes
            // once), streaming types keystrokes it may later need to revise —
            // it must be able to see the element it is editing.
            return .unreadableField
        }
        if TextInjectionService.assessSecureField(details) == .blocked {
            return .secureField
        }
        guard case .value(let textSnapshot) = snapshot, let value = textSnapshot.value else {
            return .unreadableField
        }
        if value.isEmpty, elementDetails.role == (kAXTextAreaRole as String) {
            // Terminals expose their whole grid as an AXTextArea with an
            // empty-string value even when text is visibly present. An empty
            // genuine document falls back too — the pill transcript covers it.
            return .terminalHeuristic
        }
        return nil
    }
}

// MARK: - Streaming session

/// One dictation session's in-field streaming state machine. Owned by the
/// coordinator for dictation sessions when the setting is on; edit sessions
/// never create one.
///
/// Lifecycle (states × events):
///
///   pending    --commit, gates pass-->   streaming (types first increment)
///   pending    --commit, gate fails-->   fallback(reason)   [pill transcript]
///   streaming  --commit, target frontmost & field intact--> streaming (types increment)
///   streaming  --commit/speculative, target not frontmost--> fallback(.focusLost)
///   streaming  --commit, field became secure-->             fallback(.secureField)
///   streaming  --commit, streamed span not visible-->       fallback(.fieldMismatch)
///   any        --finalize-->             finished (reconciles if anything streamed)
///
/// Fallback is one-way: once a session stops streaming it never resumes, and
/// the pill transcript (which accumulates regardless) takes over. Text
/// already streamed stays in the field and is reconciled at finalize.
final class InFieldStreamingSession {
    enum Phase: Equatable {
        case pending
        case streaming
        case fallback(InFieldStreamingFallbackReason)
        case finished
    }

    enum FinalizeOutcome: Equatable {
        /// Nothing was streamed — the caller should inject normally.
        case notStreamed
        /// The field now contains exactly the final pipeline text.
        case completed
        /// Reconciliation was unsafe or failed verification. The streamed
        /// text is left as-is and the final text is on the clipboard.
        case failedNeedsManualPaste
    }

    private(set) var phase: Phase = .pending
    private var planner = StreamingIncrementPlanner()
    /// Field value captured right before the first increment, the baseline
    /// for detecting mid-stream edits at finalize.
    private(set) var preStreamFieldValue: String?

    var isStreaming: Bool { phase == .streaming }
    var streamedText: String { planner.streamedText }

    private let targetApp: NSRunningApplication?
    private let inspector: any AccessibilityInspecting
    private let keyPoster: any KeyEventPosting
    private let clipboard: any ClipboardManaging
    /// Delay for synthetic keystrokes to land before AX verification reads.
    private let settleNanoseconds: UInt64
    /// Seam for "is the target app still frontmost" so gate logic is
    /// deterministic under test (NSRunningApplication.isActive is not).
    private let isTargetFrontmost: () -> Bool

    private var targetPid: pid_t? { targetApp?.processIdentifier }

    init(
        targetApp: NSRunningApplication?,
        inspector: any AccessibilityInspecting = SystemAccessibilityInspector(),
        keyPoster: any KeyEventPosting = CGKeyEventPoster(),
        clipboard: any ClipboardManaging = ClipboardManager(),
        settleNanoseconds: UInt64 = 60_000_000,
        isTargetFrontmost: (() -> Bool)? = nil
    ) {
        self.targetApp = targetApp
        self.inspector = inspector
        self.keyPoster = keyPoster
        self.clipboard = clipboard
        self.settleNanoseconds = settleNanoseconds
        self.isTargetFrontmost = isTargetFrontmost ?? { targetApp?.isActive ?? false }
    }

    // MARK: Streaming

    /// Handles one committed clip while recording. Evaluates the start gates
    /// on the first commit, re-checks the cheap per-increment gates on every
    /// commit, and types the increment at the caret. Any gate failure flips
    /// the session to fallback (pill transcript) without typing.
    func ingestCommit(_ text: String) async {
        switch phase {
        case .fallback, .finished:
            return
        case .pending:
            if let reason = evaluateStartGate() {
                fallBack(reason)
                return
            }
            phase = .streaming
        case .streaming:
            break
        }

        // Per-increment gates: never type into a different app, never type
        // into a field that became secure mid-session.
        guard isTargetFrontmost() else {
            fallBack(.focusLost)
            return
        }
        if TextInjectionService.assessSecureField(
            inspector.focusedElementDetails(processIdentifier: targetPid)
        ) == .blocked {
            fallBack(.secureField)
            return
        }

        // Caret guard for non-first increments: if the user clicked elsewhere
        // (no keystrokes, so the field-content check can't see it), typing
        // would land mid-document. A readable caret must sit at the end of
        // the streamed span; unreadable carets keep the status quo (the
        // post-type visibility check plus finalize verification stay the
        // honest backstop).
        if !planner.streamedText.isEmpty,
           case .value(let preTypeSnapshot) = inspector.focusedElementTextSnapshot(processIdentifier: targetPid),
           let caret = preTypeSnapshot.selectedRange,
           let fieldValue = preTypeSnapshot.value,
           !caretSitsAtStreamedSpanEnd(caret, currentValue: fieldValue) {
            fallBack(.fieldMismatch)
            return
        }

        guard let increment = planner.increment(forCommittedText: text) else { return }
        keyPoster.postTypedText(increment)

        // Visibility check: if the element exposes readable text and the
        // streamed span is not in it, the element swallowed the keystrokes
        // (terminal-like) or the user rewrote the field. Stop streaming; the
        // finalize reconciliation will detect the mismatch and stay honest.
        if settleNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: settleNanoseconds)
        }
        if case .value(let snapshot) = inspector.focusedElementTextSnapshot(processIdentifier: targetPid),
           let value = snapshot.value,
           !StreamingReconciliation.typographicallyNormalized(value)
                .contains(StreamingReconciliation.typographicallyNormalized(planner.streamedText)) {
            fallBack(.fieldMismatch)
        }
    }

    /// Cheap focus re-check ridden by speculative events (~sub-second cadence)
    /// so an app switch flips the pill back to the transcript quickly instead
    /// of waiting for the next commit.
    func refreshFocusGate() {
        guard phase == .streaming, !isTargetFrontmost() else { return }
        fallBack(.focusLost)
    }

    private func evaluateStartGate() -> InFieldStreamingFallbackReason? {
        let details = inspector.focusedElementDetails(processIdentifier: targetPid)
        let snapshot = inspector.focusedElementTextSnapshot(processIdentifier: targetPid)
        let reason = InFieldStreamingGate.assessStart(
            bundleID: targetApp?.bundleIdentifier,
            targetFrontmost: isTargetFrontmost(),
            details: details,
            snapshot: snapshot
        )
        if reason == nil, case .value(let textSnapshot) = snapshot {
            preStreamFieldValue = textSnapshot.value
        }
        return reason
    }

    private func fallBack(_ reason: InFieldStreamingFallbackReason) {
        phase = .fallback(reason)
        Logger.injection.info(
            "In-field streaming fell back to pill transcript: \(reason.rawValue, privacy: .public)"
        )
    }

    // MARK: Finalize reconciliation

    /// Brings the field to exactly `finalText` for the span this session
    /// streamed. Activates the target once (mirroring the normal inject
    /// path), verifies the streamed span is still the only change to the
    /// field, then applies the minimal edit: nothing, append the remainder,
    /// or delete only the divergent tail and insert the replacement. Any
    /// unverifiable or failed step leaves the field alone (or as-edited),
    /// puts the final text on the clipboard, and reports failure honestly.
    func finalize(finalText: String) async -> FinalizeOutcome {
        defer { phase = .finished }
        guard !planner.streamedText.isEmpty else { return .notStreamed }

        await activateTargetOnce()

        var currentValue: String?
        var caretRange: FocusedTextRange?
        if case .value(let snapshot) = inspector.focusedElementTextSnapshot(processIdentifier: targetPid) {
            currentValue = snapshot.value
            caretRange = snapshot.selectedRange
        }

        let plan = StreamingReconciliation.plan(
            streamedText: planner.streamedText,
            finalText: finalText,
            preStreamFieldValue: preStreamFieldValue,
            currentFieldValue: currentValue
        )

        switch plan {
        case .abortFieldMismatch:
            clipboard.setString(finalText)
            Logger.injection.warning(
                "Streaming reconciliation aborted — field no longer matches the streamed span; final text left on clipboard"
            )
            return .failedNeedsManualPaste

        case .alreadyExact:
            Logger.injection.info("Streaming reconciliation: streamed span already equals final text")
            return .completed

        case .appendRemainder(let remainder):
            // Caret guard: typing at a moved caret would insert the remainder
            // in the middle of unrelated text. When the caret is readable it
            // must sit at the end of the streamed span; when unreadable, the
            // append proceeds (non-destructive) and post-verification stays
            // the honest backstop.
            if let currentValue, caretGuardFails(caretRange, currentValue: currentValue) {
                clipboard.setString(finalText)
                Logger.injection.warning(
                    "Streaming reconciliation aborted — caret moved off the streamed span; final text left on clipboard"
                )
                return .failedNeedsManualPaste
            }
            await deliverReconciliationText(remainder)
            return await verifyReconciliation(finalText: finalText)

        case .replaceDivergentTail(let deleteCharacters, let replacement):
            // Destructive edit: backspaces delete at the caret. The caret
            // MUST verifiably sit at the end of the streamed span — an
            // unreadable caret aborts rather than risk deleting pre-existing
            // text (the field-content splice check cannot see caret moves).
            guard let currentValue,
                  let caret = caretRange,
                  caretSitsAtStreamedSpanEnd(caret, currentValue: currentValue) else {
                clipboard.setString(finalText)
                Logger.injection.warning(
                    "Streaming reconciliation aborted — caret not verifiably at the streamed span end before deletion; final text left on clipboard"
                )
                return .failedNeedsManualPaste
            }
            keyPoster.postBackspaces(count: deleteCharacters)
            if settleNanoseconds > 0 {
                try? await Task.sleep(nanoseconds: settleNanoseconds)
            }
            await deliverReconciliationText(replacement)
            return await verifyReconciliation(finalText: finalText)
        }
    }

    /// True when the caret is readable but NOT at a valid streamed-span end.
    private func caretGuardFails(_ caret: FocusedTextRange?, currentValue: String) -> Bool {
        guard let caret else { return false }
        return !caretSitsAtStreamedSpanEnd(caret, currentValue: currentValue)
    }

    /// The caret must be a zero-length selection sitting exactly where the
    /// streamed span ends (any valid splice position counts).
    private func caretSitsAtStreamedSpanEnd(_ caret: FocusedTextRange, currentValue: String) -> Bool {
        guard caret.length == 0 else { return false }
        let validOffsets = StreamingReconciliation.validCaretUTF16Offsets(
            pre: preStreamFieldValue,
            streamed: planner.streamedText,
            current: currentValue
        )
        return validOffsets.contains(caret.location)
    }

    /// Inserts reconciliation text. Plain text goes through the typed-unicode
    /// path (no clipboard involvement at all). Text containing line breaks is
    /// pasted instead — a typed "\n" can read as Return and submit in chat
    /// apps — with the user's clipboard saved and restored exactly once.
    private func deliverReconciliationText(_ text: String) async {
        guard !text.isEmpty else { return }
        if text.contains(where: \.isNewline) {
            let saved = clipboard.save()
            clipboard.setString(text)
            keyPoster.postPasteChord()
            if settleNanoseconds > 0 {
                try? await Task.sleep(nanoseconds: settleNanoseconds * 2)
            }
            clipboard.restore(saved)
        } else {
            keyPoster.postTypedText(text)
            if settleNanoseconds > 0 {
                try? await Task.sleep(nanoseconds: settleNanoseconds)
            }
        }
    }

    /// Post-reconciliation check. A readable field that does not contain the
    /// final text means the edit did not land — final text goes to the
    /// clipboard and the failure is reported. Unreadable reads are treated as
    /// landed, matching the paste-verification fail-open policy.
    private func verifyReconciliation(finalText: String) async -> FinalizeOutcome {
        guard case .value(let snapshot) = inspector.focusedElementTextSnapshot(processIdentifier: targetPid),
              let value = snapshot.value,
              !value.isEmpty else {
            return .completed
        }
        let normalizedValue = StreamingReconciliation.typographicallyNormalized(value)
        let normalizedFinal = StreamingReconciliation.typographicallyNormalized(finalText)
        if normalizedFinal.isEmpty || normalizedValue.contains(normalizedFinal) {
            return .completed
        }
        clipboard.setString(finalText)
        Logger.injection.warning(
            "Streaming reconciliation did not verify — final text left on clipboard"
        )
        return .failedNeedsManualPaste
    }

    /// One activation before reconciliation, mirroring the normal inject
    /// path's contract (activate once; never yank focus mid-recording).
    private func activateTargetOnce() async {
        guard let targetApp, targetApp.bundleIdentifier != Bundle.main.bundleIdentifier else { return }
        guard !targetApp.isActive else { return }
        _ = targetApp.activate()
        let pollIntervalNs: UInt64 = 10_000_000 // 10ms
        var waitedNs: UInt64 = 0
        while waitedNs < 300_000_000, !targetApp.isActive {
            try? await Task.sleep(nanoseconds: pollIntervalNs)
            waitedNs += pollIntervalNs
        }
        // Focus-transfer stabilization, matching the inject path.
        try? await Task.sleep(nanoseconds: 30_000_000)
    }
}
