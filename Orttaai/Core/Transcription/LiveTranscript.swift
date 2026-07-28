// LiveTranscript.swift
// Orttaai

import Foundation

/// Events emitted by the live transcription session as text becomes
/// available while the user is still speaking. Committed text comes from
/// clip commits (15s grid and early-pause commits) and is stable; the
/// speculative tail is a provisional decode of the uncommitted audio and
/// may be revised or superseded.
enum LiveTranscriptEvent: Equatable, Sendable {
    /// A new live session started; any prior partial text is stale.
    case sessionBegan
    /// A clip commit landed. The text (possibly empty for silent clips)
    /// is final for its audio range and supersedes any speculative tail
    /// decoded against the previous committed base.
    case committed(String)
    /// A speculative decode of the uncommitted tail finished. Replaces the
    /// previous speculative text; never touches committed text.
    case speculative(String)
}

/// In-progress transcript assembled from `LiveTranscriptEvent`s with the
/// same semantics the transcription session uses internally: commits append
/// (and invalidate the speculative tail), speculative decodes replace one
/// another, and a new session clears everything. Feeds the in-field
/// streaming machinery; it is never rendered in the floating pill (the pill
/// shows no dictated text by design).
struct LiveTranscript: Equatable, Sendable {
    /// Committed text kept in memory. Head-trimming keeps long dictations
    /// bounded; consumers only ever need the trailing portion.
    static let maxCommittedDisplayCharacters = 2_000

    private(set) var committedText: String = ""
    private(set) var speculativeText: String = ""

    var isEmpty: Bool {
        committedText.isEmpty && speculativeText.isEmpty
    }

    mutating func apply(_ event: LiveTranscriptEvent) {
        switch event {
        case .sessionBegan:
            self = LiveTranscript()

        case .committed(let text):
            let normalized = TranscriptionService.normalizedTranscriptionText(text)
            if !normalized.isEmpty {
                committedText = committedText.isEmpty
                    ? normalized
                    : committedText + " " + normalized
                if committedText.count > Self.maxCommittedDisplayCharacters {
                    committedText = String(committedText.suffix(Self.maxCommittedDisplayCharacters))
                }
            }
            // The tail was decoded against the pre-commit base; the commit
            // covers that audio now, so the stale tail must not linger.
            speculativeText = ""

        case .speculative(let text):
            speculativeText = TranscriptionService.normalizedTranscriptionText(text)
        }
    }
}
