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

/// Plans the text that should be visible in the target field while recording.
/// Unlike `StreamingIncrementPlanner`, this includes the speculative tail so a
/// normal short dictation becomes visible after the first live decode instead
/// of waiting for a pause commit or the 15-second commit boundary.
struct LiveStreamingTextPlanner: Equatable, Sendable {
    enum Edit: Equatable, Sendable {
        case append(String)
        case replaceTail(deleteCharacters: Int, replacement: String)
    }

    private(set) var committedText = ""
    private(set) var speculativeText = ""

    var visibleText: String {
        Self.joined(committed: committedText, speculative: speculativeText)
    }

    mutating func editForCommittedText(_ text: String) -> Edit? {
        let oldVisible = visibleText
        let normalized = Self.flattened(text)
        if !normalized.isEmpty {
            committedText = committedText.isEmpty
                ? normalized
                : committedText + " " + normalized
        }
        // A commit covers the speculative tail decoded against the old base.
        speculativeText = ""
        return Self.edit(from: oldVisible, to: visibleText)
    }

    mutating func editForSpeculativeText(_ text: String) -> Edit? {
        let oldVisible = visibleText
        speculativeText = Self.flattened(text)
        return Self.edit(from: oldVisible, to: visibleText)
    }

    private static func joined(committed: String, speculative: String) -> String {
        if committed.isEmpty { return speculative }
        if speculative.isEmpty { return committed }
        return committed + " " + speculative
    }

    private static func flattened(_ text: String) -> String {
        TranscriptionService.normalizedTranscriptionText(text)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    private static func edit(from oldText: String, to newText: String) -> Edit? {
        guard oldText != newText else { return nil }
        let commonPrefixCount = StreamingReconciliation.commonPrefixCharacterCount(oldText, newText)
        let replacement = String(newText.dropFirst(commonPrefixCount))
        if commonPrefixCount == oldText.count {
            return .append(replacement)
        }
        return .replaceTail(
            deleteCharacters: oldText.count - commonPrefixCount,
            replacement: replacement
        )
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
    nonisolated static func quoteFolded(_ text: String) -> String {
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
    nonisolated static func normalized(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }

    /// Editors with smart substitutions rewrite typed straight quotes into
    /// typographic ones (verified live against TextEdit). Those are 1:1
    /// character swaps, so folding them keeps every count-based decision
    /// valid while stopping cosmetic substitutions from reading as
    /// user-typed-mid-stream mismatches.
    nonisolated static func typographicallyNormalized(_ text: String) -> String {
        normalized(text)
            .replacingOccurrences(of: "\u{2018}", with: "'")
            .replacingOccurrences(of: "\u{2019}", with: "'")
            .replacingOccurrences(of: "\u{201C}", with: "\"")
            .replacingOccurrences(of: "\u{201D}", with: "\"")
    }

    /// Some controlled editors echo synthetic typing through their document
    /// model and expose a cosmetically transformed AX value (capitalization,
    /// non-breaking spaces, or invisible markers). If the field was empty at
    /// session start, the caret is still at the end, and the whole current
    /// value loosely equals the text Orttaai streamed, replacing that entire
    /// value is both safe and more truthful than leaving provisional text
    /// behind while putting the final result on the clipboard.
    static func canReplaceTransformedEmptyField(
        preStreamFieldValue: String?,
        streamedText: String,
        currentFieldValue: String,
        caret: FocusedTextRange?
    ) -> Bool {
        guard preStreamFieldValue == "",
              !streamedText.isEmpty,
              !currentFieldValue.isEmpty,
              let caret,
              caret.length == 0,
              caret.location == currentFieldValue.utf16.count else {
            return false
        }
        return looseFieldComparisonText(streamedText) == looseFieldComparisonText(currentFieldValue)
    }

    nonisolated private static func looseFieldComparisonText(_ text: String) -> String {
        typographicallyNormalized(text)
            .precomposedStringWithCanonicalMapping
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            .replacingOccurrences(of: "\u{200B}", with: "")
            .replacingOccurrences(of: "\u{200C}", with: "")
            .replacingOccurrences(of: "\u{200D}", with: "")
            .replacingOccurrences(of: "\u{FEFF}", with: "")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }
}

// MARK: - Blind reconciliation planning (pure)

/// Count-based finalize planning for blind-mode sessions (terminals and
/// unreadable fields), where no AX read-back exists to verify anything.
///
/// The plan is append-biased: compute the common prefix between the streamed
/// span and the final pipeline text; when the final text extends the streamed
/// span, type only the remainder; when it diverges, backspace exactly the
/// divergent-tail character count of the streamed span, then type the
/// replacement. By construction the plan never deletes more characters than
/// this session itself typed, immediately after its own last increment — if
/// nothing was streamed, there is nothing to delete.
///
/// All reconciliation text is compared and delivered with newlines flattened
/// to single spaces — never pasted, never a raw Return: a streamed Return
/// submits chat inputs and executes shell commands. Blind-mode dictation
/// therefore trades exact multi-line formatting for in-place delivery; the
/// streamed increments (already newline-free) plus this flattening keep the
/// delivered text equal to the final pipeline text modulo line breaks.
enum BlindStreamingReconciliation {
    /// The final pipeline text as blind mode is allowed to type it: every
    /// whitespace run that contains at least one line break (\r, \n, or the
    /// Unicode line/paragraph separators) becomes exactly one space; text
    /// without line breaks is untouched. The greedy `\s*` on both sides of
    /// the single anchored line-break character swallows the whole mixed run
    /// in one match. `\u{2028}`/`\u{2029}` are Swift string escapes (not a
    /// raw string), so ICU sees the literal characters.
    static func flattenedForBlindTyping(_ text: String) -> String {
        text.replacingOccurrences(
            of: "\\s*[\r\n\u{2028}\u{2029}]\\s*",
            with: " ",
            options: .regularExpression
        )
    }

    /// Plans the finalize edit from character counts alone. Never produces
    /// `.abortFieldMismatch` — with no field to read there is no mismatch to
    /// detect; the delete bound above is the safety story.
    static func plan(streamedText: String, finalText: String) -> StreamingReconciliationPlan {
        let flattenedFinal = flattenedForBlindTyping(finalText)
        guard !streamedText.isEmpty else {
            return flattenedFinal.isEmpty ? .alreadyExact : .appendRemainder(flattenedFinal)
        }
        if flattenedFinal == streamedText {
            return .alreadyExact
        }
        let commonPrefixCount = StreamingReconciliation.commonPrefixCharacterCount(streamedText, flattenedFinal)
        let remainder = String(flattenedFinal.dropFirst(commonPrefixCount))
        if commonPrefixCount == streamedText.count {
            return .appendRemainder(remainder)
        }
        return .replaceDivergentTail(
            deleteCharacters: streamedText.count - commonPrefixCount,
            replacement: remainder
        )
    }
}

// MARK: - Safety gates (pure)

/// Why a session stopped typing into the field. Stopping is silent — the
/// pill never displays transcript text in any mode — and one-way for the
/// rest of the session; whatever was already streamed is reconciled at
/// finalize. None of these fails the dictation itself.
enum InFieldStreamingStopReason: String, Equatable, Sendable {
    /// The focused element is (or became) a secure/password field. Never
    /// streamed, never typed, in any mode.
    case secureField
    /// The target app is no longer frontmost — keystrokes would land in the
    /// wrong app. Streaming never re-activates the target mid-recording.
    case focusLost
    /// Readable mode only: the field's text stopped matching the streamed
    /// span (the element swallowed the keystrokes, the user edited
    /// mid-stream, or the caret moved).
    case fieldMismatch
    /// The destination has a confirmed crash or corruption path when it
    /// receives synthetic per-chunk key events. Final delivery must fall back
    /// to the normal single-paste injection path.
    case unsafeBlindTarget
}

/// Why a session streams blind: typed keystrokes verifiably land in these
/// targets (measured live against cmux/Ghostty), but their text can never be
/// read back over AX, so no mid-stream visibility check or exact finalize
/// reconciliation is possible.
enum InFieldStreamingBlindReason: String, Equatable, Sendable {
    /// The target app is a known terminal emulator — its screen text is not
    /// exposed to AX.
    case terminalBundle
    /// The focused element looks like a terminal screen: an AXTextArea whose
    /// value reads as the empty string (how Ghostty/cmux expose their grid;
    /// see the paste-verification history).
    case terminalHeuristic
    /// AX cannot read the focused element's details or text at all.
    case unreadableField
}

/// How a session may deliver dictated text into the focused element.
enum InFieldStreamingStartDecision: Equatable, Sendable {
    /// AX can read the field: stream with mid-stream visibility checks, the
    /// caret guard, and exact finalize reconciliation (C7 — unchanged).
    case streamReadable
    /// The field cannot be read back (terminal, unreadable element): stream
    /// typed increments blind and reconcile by count at finalize.
    case streamBlind(InFieldStreamingBlindReason)
    /// Never type into this target: secure fields and lost focus stop the
    /// session silently before the first keystroke.
    case refuse(InFieldStreamingStopReason)
}

enum InFieldStreamingGate {
    /// Apps whose editors have a confirmed crash path under synthetic
    /// per-chunk key events. Codex exposes its composer as unreadable over AX;
    /// blind Unicode streaming crashed its NSTextInputContext on 2026-07-28.
    /// Keep these targets on the normal one-paste final delivery path.
    static let unsafeStreamingBundleIDs: Set<String> = [
        "com.openai.codex"
    ]

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

    static func isUnsafeStreamingBundleID(_ bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return unsafeStreamingBundleIDs.contains(bundleID.lowercased())
    }

    /// Decides how a session may start delivering into the focused element.
    /// Readable fields get the fully verified C7 path; unreadable fields and
    /// terminals stream blind (typed increments, count-based reconciliation);
    /// secure fields and lost focus refuse outright — nothing is ever typed.
    static func assessStart(
        bundleID: String?,
        targetFrontmost: Bool,
        details: AXInspection<FocusedElementDetails>,
        snapshot: AXInspection<FocusedTextSnapshot>
    ) -> InFieldStreamingStartDecision {
        guard targetFrontmost else {
            return .refuse(.focusLost)
        }
        if isUnsafeStreamingBundleID(bundleID) {
            return .refuse(.unsafeBlindTarget)
        }
        if isTerminalBundleID(bundleID) {
            // Typed unicode keystrokes verifiably land in terminals, but
            // their screens can't be read back — stream blind.
            return .streamBlind(.terminalBundle)
        }
        guard case .value(let elementDetails) = details else {
            // AX cannot see the element at all. Plain injection fails open
            // here and pastes once; blind streaming is the streaming
            // equivalent of that policy.
            return .streamBlind(.unreadableField)
        }
        if TextInjectionService.assessSecureField(details) == .blocked {
            return .refuse(.secureField)
        }
        guard case .value(let textSnapshot) = snapshot, let value = textSnapshot.value else {
            return .streamBlind(.unreadableField)
        }
        if value.isEmpty, elementDetails.role == (kAXTextAreaRole as String) {
            // Terminals expose their whole grid as an AXTextArea with an
            // empty-string value even when text is visibly present. An empty
            // genuine document streams blind too — increments still land and
            // the count-based reconciliation stays within what was typed.
            return .streamBlind(.terminalHeuristic)
        }
        return .streamReadable
    }
}

// MARK: - Streaming session

/// One dictation session's in-field streaming state machine. Owned by the
/// coordinator for dictation sessions when the setting is on; edit sessions
/// never create one.
///
/// Lifecycle (states × events):
///
///   pending             --commit, readable gate-->            streaming[readable] (types first increment)
///   pending             --commit, terminal/unreadable gate--> streaming[blind]    (types first increment)
///   pending             --commit, secure field/focus lost-->  stopped(reason)     (nothing typed, silent)
///   streaming[readable] --commit, frontmost & field intact--> streaming (types increment)
///   streaming[blind]    --commit, frontmost & not secure-->   streaming (types increment; no AX checks — they cannot work)
///   streaming[any]      --commit/speculative, target not frontmost--> stopped(.focusLost)
///   streaming[any]      --commit, field became secure-->            stopped(.secureField)
///   streaming[readable] --commit, streamed span not visible/caret moved--> stopped(.fieldMismatch)
///   any                 --finalize--> finished (readable: exact reconciliation with caret guard;
///                                     blind: count-based, append-biased, newline-flattened)
///
/// Stopping is one-way and silent: once a session stops streaming it never
/// resumes, and the pill shows nothing in any mode (only the compact
/// waveform). Text already streamed stays in the field and is reconciled at
/// finalize.
final class InFieldStreamingSession {
    enum Phase: Equatable {
        case pending
        case streaming
        case stopped(InFieldStreamingStopReason)
        case finished
    }

    /// How increments are delivered and reconciled once streaming starts.
    enum Mode: Equatable {
        /// AX-readable field: mid-stream visibility checks, caret guard, and
        /// exact finalize reconciliation (C7 — byte-for-byte unchanged).
        case readable
        /// Terminal or unreadable field: typed increments with no AX
        /// read-back, count-based reconciliation at finalize.
        case blind(InFieldStreamingBlindReason)
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
    /// Meaningful once streaming has started; readable until the start gate
    /// says otherwise.
    private(set) var mode: Mode = .readable
    private enum LiveTextUpdate {
        case committed(String)
        case speculative(String)
    }

    private var planner = LiveStreamingTextPlanner()
    /// Field value captured right before the first increment, the baseline
    /// for detecting mid-stream edits at finalize (readable mode only).
    private(set) var preStreamFieldValue: String?

    var isStreaming: Bool { phase == .streaming }
    var streamedText: String { planner.visibleText }

    private let targetApp: NSRunningApplication?
    /// Bundle ID used by the terminal gate. Injectable so unit tests can
    /// exercise the terminal-bundle path without a real NSRunningApplication;
    /// production passes nothing and the target app's own ID is used.
    private let targetBundleID: String?
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
        targetBundleID: String? = nil,
        inspector: any AccessibilityInspecting = SystemAccessibilityInspector(),
        keyPoster: any KeyEventPosting = CGKeyEventPoster(),
        clipboard: any ClipboardManaging = ClipboardManager(),
        settleNanoseconds: UInt64 = 60_000_000,
        isTargetFrontmost: (() -> Bool)? = nil
    ) {
        self.targetApp = targetApp
        self.targetBundleID = targetBundleID ?? targetApp?.bundleIdentifier
        self.inspector = inspector
        self.keyPoster = keyPoster
        self.clipboard = clipboard
        self.settleNanoseconds = settleNanoseconds
        self.isTargetFrontmost = isTargetFrontmost ?? { targetApp?.isActive ?? false }
    }

    // MARK: Streaming

    /// Handles one committed clip while recording. A commit supersedes the
    /// provisional tail and becomes the stable visible prefix.
    func ingestCommit(_ text: String) async {
        await ingestLiveTextUpdate(.committed(text))
    }

    /// Shows and revises the speculative tail in the target field. This is the
    /// path that makes ordinary sub-15-second dictations visibly live.
    func ingestSpeculative(_ text: String) async {
        await ingestLiveTextUpdate(.speculative(text))
    }

    private func ingestLiveTextUpdate(_ update: LiveTextUpdate) async {
        switch phase {
        case .stopped, .finished:
            return
        case .pending, .streaming:
            break
        }

        var candidatePlanner = planner
        let edit: LiveStreamingTextPlanner.Edit?
        switch update {
        case .committed(let text):
            edit = candidatePlanner.editForCommittedText(text)
        case .speculative(let text):
            edit = candidatePlanner.editForSpeculativeText(text)
        }
        guard let edit else {
            // The visible text can stay identical while a commit moves the
            // speculative text into the stable prefix.
            planner = candidatePlanner
            return
        }

        if phase == .pending {
            switch evaluateStartGate() {
            case .refuse(let reason):
                stop(reason)
                return
            case .streamBlind(let reason):
                mode = .blind(reason)
                phase = .streaming
                Logger.injection.info(
                    "In-field streaming started blind: \(reason.rawValue, privacy: .public)"
                )
            case .streamReadable:
                mode = .readable
                phase = .streaming
            }
        }

        // Unreadable targets (notably terminals) cannot prove where their
        // caret sits or whether the user edited the command. Keep their
        // established commit-only behavior; speculative backspace/retype
        // revisions require a readable field.
        if case .speculative = update, case .blind = mode {
            return
        }

        // Per-increment gates, both modes: never type into a different app,
        // never type into a field that became secure mid-session.
        guard isTargetFrontmost() else {
            stop(.focusLost)
            return
        }
        if TextInjectionService.assessSecureField(
            inspector.focusedElementDetails(processIdentifier: targetPid)
        ) == .blocked {
            stop(.secureField)
            return
        }

        // Caret guard for non-first increments (readable mode only — blind
        // targets expose no caret): if the user clicked elsewhere (no
        // keystrokes, so the field-content check can't see it), typing would
        // land mid-document. A readable caret must sit at the end of the
        // streamed span; unreadable carets keep the status quo (the post-type
        // visibility check plus finalize verification stay the honest
        // backstop).
        if mode == .readable,
           !planner.visibleText.isEmpty,
           case .value(let preTypeSnapshot) = inspector.focusedElementTextSnapshot(processIdentifier: targetPid),
           let caret = preTypeSnapshot.selectedRange,
           let fieldValue = preTypeSnapshot.value,
           !caretSitsAtStreamedSpanEnd(caret, currentValue: fieldValue) {
            stop(.fieldMismatch)
            return
        }

        switch edit {
        case .append(let text):
            keyPoster.postTypedText(text)
        case .replaceTail(let deleteCharacters, let replacement):
            keyPoster.postBackspaces(count: deleteCharacters)
            if settleNanoseconds > 0 {
                try? await Task.sleep(nanoseconds: settleNanoseconds)
            }
            if !replacement.isEmpty {
                keyPoster.postTypedText(replacement)
            }
        }
        planner = candidatePlanner

        // Visibility check (readable mode only — blind targets cannot echo
        // anything back): if the element exposes readable text and the
        // streamed span is not in it, the element swallowed the keystrokes
        // (terminal-like) or the user rewrote the field. Stop streaming; the
        // finalize reconciliation will detect the mismatch and stay honest.
        guard mode == .readable else { return }
        if settleNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: settleNanoseconds)
        }
        if case .value(let snapshot) = inspector.focusedElementTextSnapshot(processIdentifier: targetPid),
           let value = snapshot.value,
           !StreamingReconciliation.typographicallyNormalized(value)
                .contains(StreamingReconciliation.typographicallyNormalized(planner.visibleText)) {
            stop(.fieldMismatch)
        }
    }

    /// Cheap focus re-check ridden by speculative events (~sub-second cadence)
    /// so an app switch stops the typing quickly instead of waiting for the
    /// next commit.
    func refreshFocusGate() {
        guard phase == .streaming, !isTargetFrontmost() else { return }
        stop(.focusLost)
    }

    private func evaluateStartGate() -> InFieldStreamingStartDecision {
        let details = inspector.focusedElementDetails(processIdentifier: targetPid)
        let snapshot = inspector.focusedElementTextSnapshot(processIdentifier: targetPid)
        let decision = InFieldStreamingGate.assessStart(
            bundleID: targetBundleID,
            targetFrontmost: isTargetFrontmost(),
            details: details,
            snapshot: snapshot
        )
        if decision == .streamReadable, case .value(let textSnapshot) = snapshot {
            preStreamFieldValue = textSnapshot.value
        }
        return decision
    }

    private func stop(_ reason: InFieldStreamingStopReason) {
        phase = .stopped(reason)
        Logger.injection.info(
            "In-field streaming stopped silently: \(reason.rawValue, privacy: .public)"
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
    /// Blind-mode sessions take the count-based path instead.
    func finalize(finalText: String) async -> FinalizeOutcome {
        defer { phase = .finished }
        guard !planner.visibleText.isEmpty else { return .notStreamed }

        if case .blind = mode {
            return await finalizeBlind(finalText: finalText)
        }

        await activateTargetOnce()

        var currentValue: String?
        var caretRange: FocusedTextRange?
        if case .value(let snapshot) = inspector.focusedElementTextSnapshot(processIdentifier: targetPid) {
            currentValue = snapshot.value
            caretRange = snapshot.selectedRange
        }

        let plan = StreamingReconciliation.plan(
            streamedText: planner.visibleText,
            finalText: finalText,
            preStreamFieldValue: preStreamFieldValue,
            currentFieldValue: currentValue
        )

        switch plan {
        case .abortFieldMismatch:
            if let currentValue,
               StreamingReconciliation.canReplaceTransformedEmptyField(
                   preStreamFieldValue: preStreamFieldValue,
                   streamedText: planner.visibleText,
                   currentFieldValue: currentValue,
                   caret: caretRange
               ) {
                Logger.injection.info(
                    "Recovering transformed empty-field stream with a verified whole-span replacement"
                )
                keyPoster.postBackspaces(count: currentValue.count)
                if settleNanoseconds > 0 {
                    try? await Task.sleep(nanoseconds: settleNanoseconds)
                }
                await deliverReconciliationText(finalText)
                return await verifyReconciliation(finalText: finalText)
            }
            clipboard.setString(finalText)
            Logger.injection.warning(
                "Streaming reconciliation aborted — field no longer matches the streamed span [preChars=\(self.preStreamFieldValue?.count ?? -1), streamedChars=\(self.planner.visibleText.count), currentChars=\(currentValue?.count ?? -1)]; final text left on clipboard"
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

    /// Blind-mode finalize: no AX read-back exists, so the edit is planned
    /// from character counts alone (`BlindStreamingReconciliation.plan`) and
    /// applied unverified. The readable-mode caret guard cannot apply — blind
    /// mode's protection is that it only ever backspaces at most the
    /// character count this session itself typed, immediately after its own
    /// last increment, and every character it types has newlines flattened to
    /// spaces (never pasted, never a raw Return — Enter submits chat inputs
    /// and executes shell commands). Blind dictation trades exact multi-line
    /// formatting for in-place delivery.
    private func finalizeBlind(finalText: String) async -> FinalizeOutcome {
        await activateTargetOnce()

        // The only checks blind mode can run: the keystrokes must go to the
        // target app, and never into a field that became secure.
        guard isTargetFrontmost() else {
            clipboard.setString(finalText)
            Logger.injection.warning(
                "Blind streaming reconciliation aborted — target app not frontmost; final text left on clipboard"
            )
            return .failedNeedsManualPaste
        }
        if TextInjectionService.assessSecureField(
            inspector.focusedElementDetails(processIdentifier: targetPid)
        ) == .blocked {
            clipboard.setString(finalText)
            Logger.injection.warning(
                "Blind streaming reconciliation aborted — focused element is a secure field; final text left on clipboard"
            )
            return .failedNeedsManualPaste
        }

        switch BlindStreamingReconciliation.plan(streamedText: planner.visibleText, finalText: finalText) {
        case .alreadyExact:
            Logger.injection.info("Blind streaming reconciliation: streamed span already matches the flattened final text")
            return .completed

        case .appendRemainder(let remainder):
            keyPoster.postTypedText(remainder)

        case .replaceDivergentTail(let deleteCharacters, let replacement):
            // deleteCharacters is bounded by the streamed span's length by
            // construction — never more than this session itself typed.
            keyPoster.postBackspaces(count: deleteCharacters)
            if settleNanoseconds > 0 {
                try? await Task.sleep(nanoseconds: settleNanoseconds)
            }
            keyPoster.postTypedText(replacement)

        case .abortFieldMismatch:
            // Unreachable: the blind planner never produces this case (there
            // is no field to mismatch). Kept exhaustive and honest anyway.
            clipboard.setString(finalText)
            return .failedNeedsManualPaste
        }
        if settleNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: settleNanoseconds)
        }
        return .completed
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
            streamed: planner.visibleText,
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
