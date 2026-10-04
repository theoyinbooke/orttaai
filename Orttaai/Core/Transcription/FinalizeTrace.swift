// FinalizeTrace.swift
// Orttaai

import Foundation
import os

/// Which route `finalizeLiveTranscription` took to produce its transcript.
nonisolated enum FinalizePath: Sendable, Equatable {
    /// The speculative tail decode covered the final audio and was reused.
    case reusedSpeculative
    /// The uncommitted tail was decoded at finalize.
    case tailDecoded
    /// The uncommitted tail trimmed to nothing (dead silence); the committed
    /// prefix alone was returned.
    case tailEmptyNoAudio
    /// The tail decoded to nothing (or a stock hallucination) but never
    /// reached speech-level energy, so the committed prefix was returned
    /// instead of re-decoding the whole recording.
    case tailEmptyAccepted
    /// The background result was unusable and the whole recording was
    /// decoded again.
    case wholeFallback(FinalizeFallbackReason)
    /// No live session existed (or it was cancelled while finalizing), so the
    /// whole recording was decoded.
    case noLiveSession
}

nonisolated enum FinalizeFallbackReason: Sendable, Equatable {
    /// The tail was non-empty but its decode (including the relaxed retry)
    /// produced no text.
    case tailNoResult
    /// The assembled transcript failed the integrity gate. The associated
    /// value is the gate's fixed reason string, never transcript text.
    case integrityRejected(String)
    /// Nothing was committed and the tail was empty.
    case nothingCommitted
}

/// Timing and audio facts for one finalize, for diagnosing slow finalizes.
/// Numbers and enums only: a trace never carries transcript text.
nonisolated struct FinalizeTrace: Sendable, Equatable {
    var path: FinalizePath = .noLiveSession
    /// Tail samples actually decoded (after dead-silence trimming).
    var tailSampleCount = 0
    /// Peak and median 100ms-frame RMS of the trimmed tail.
    var tailPeakFrameRMS: Float = 0
    var tailMedianFrameRMS: Float = 0
    /// True when a decode at finalize fell through to the relaxed-threshold
    /// retry (whether or not the retry produced text).
    var relaxedRetryRan = false
    var msAwaitingCommit = 0
    var msAwaitingSpeculative = 0
    var msTailDecode = 0
    var msFallbackDecode = 0
    var msTotal = 0
    /// Clips that contributed non-empty committed text.
    var committedClipCount = 0
    var totalAudioSeconds = 0.0
    /// True when finalize cancelled an in-flight speculative tail decode.
    var speculativeCancelled = false
}

nonisolated extension FinalizeTrace: Encodable {
    private enum CodingKeys: String, CodingKey {
        case path
        case fallbackReason = "fallback_reason"
        case integrityReason = "integrity_reason"
        case tailSampleCount = "tail_sample_count"
        case tailPeakFrameRMS = "tail_peak_frame_rms"
        case tailMedianFrameRMS = "tail_median_frame_rms"
        case relaxedRetryRan = "relaxed_retry_ran"
        case msAwaitingCommit = "ms_awaiting_commit"
        case msAwaitingSpeculative = "ms_awaiting_speculative"
        case msTailDecode = "ms_tail_decode"
        case msFallbackDecode = "ms_fallback_decode"
        case msTotal = "ms_total"
        case committedClipCount = "committed_clip_count"
        case totalAudioSeconds = "total_audio_seconds"
        case speculativeCancelled = "speculative_cancelled"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch path {
        case .reusedSpeculative:
            try container.encode("reused_speculative", forKey: .path)
        case .tailDecoded:
            try container.encode("tail_decoded", forKey: .path)
        case .tailEmptyNoAudio:
            try container.encode("tail_empty_no_audio", forKey: .path)
        case .tailEmptyAccepted:
            try container.encode("tail_empty_accepted", forKey: .path)
        case .noLiveSession:
            try container.encode("no_live_session", forKey: .path)
        case .wholeFallback(let reason):
            try container.encode("whole_fallback", forKey: .path)
            switch reason {
            case .tailNoResult:
                try container.encode("tail_no_result", forKey: .fallbackReason)
            case .integrityRejected(let detail):
                try container.encode("integrity_rejected", forKey: .fallbackReason)
                try container.encode(detail, forKey: .integrityReason)
            case .nothingCommitted:
                try container.encode("nothing_committed", forKey: .fallbackReason)
            }
        }
        try container.encode(tailSampleCount, forKey: .tailSampleCount)
        try container.encode(tailPeakFrameRMS, forKey: .tailPeakFrameRMS)
        try container.encode(tailMedianFrameRMS, forKey: .tailMedianFrameRMS)
        try container.encode(relaxedRetryRan, forKey: .relaxedRetryRan)
        try container.encode(msAwaitingCommit, forKey: .msAwaitingCommit)
        try container.encode(msAwaitingSpeculative, forKey: .msAwaitingSpeculative)
        try container.encode(msTailDecode, forKey: .msTailDecode)
        try container.encode(msFallbackDecode, forKey: .msFallbackDecode)
        try container.encode(msTotal, forKey: .msTotal)
        try container.encode(committedClipCount, forKey: .committedClipCount)
        try container.encode(totalAudioSeconds, forKey: .totalAudioSeconds)
        try container.encode(speculativeCancelled, forKey: .speculativeCancelled)
    }
}

/// Why a recording ended. The cases are the diagnostic vocabulary of
/// `RecordingEndTrace`; raw values are the strings written to the log.
nonisolated enum RecordingEndReason: String, Sendable, Equatable {
    /// The push-to-talk key was held and released.
    case holdRelease = "hold_release"
    /// The pill's stop button (or any caller that gave no other reason).
    case pillStop = "pill_stop"
    /// A second hotkey tap ended a hands-free session.
    case hotkeyTapStop = "hotkey_tap_stop"
    /// Sustained trailing silence ended a hands-free session.
    case silenceAutoStop = "silence_auto_stop"
    /// The duration cap fired.
    case capTimer = "cap_timer"
    /// The captured audio did not cover the recording's duration.
    case audioDropped = "audio_dropped"
    /// The recording ended before the minimum duration and was skipped.
    case tooShort = "too_short"
    /// The microphone could not start, or failed to recover mid-session.
    case captureFailed = "capture_failed"
    case cancelled
    case other
}

/// Why and how one recording ended, for diagnosing cut-off reports. Numbers
/// and enums only: a trace never carries transcript text.
nonisolated struct RecordingEndTrace: Sendable, Equatable {
    var reason: RecordingEndReason
    var recordingDurationMs: Int
    var isHandsFree: Bool
    /// The configured silence window, or nil when auto-stop was off (or the
    /// recording was push-to-talk).
    var silenceStopSeconds: Double?
    /// 100ms frames at or above the speech energy threshold.
    var speechFrameCount: Int
    var peakFrameRMS: Float
    var trailingSilenceMs: Int
    /// True once a hands-free recording had heard sustained speech.
    var handsFreeArmed: Bool
    /// The noise-aware RMS below which a hands-free recording counted
    /// frames as silence; nil for push-to-talk.
    var silenceThresholdRMS: Float? = nil
}

nonisolated extension RecordingEndTrace: Encodable {
    private enum CodingKeys: String, CodingKey {
        case reason
        case recordingDurationMs = "recording_duration_ms"
        case mode
        case silenceStopSeconds = "silence_stop_seconds"
        case speechFrameCount = "speech_frame_count"
        case peakFrameRMS = "peak_frame_rms"
        case trailingSilenceMs = "trailing_silence_ms"
        case handsFreeArmed = "hands_free_armed"
        case silenceThresholdRMS = "silence_threshold_rms"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(reason.rawValue, forKey: .reason)
        try container.encode(recordingDurationMs, forKey: .recordingDurationMs)
        try container.encode(isHandsFree ? "hands_free" : "push_to_talk", forKey: .mode)
        try container.encode(silenceStopSeconds, forKey: .silenceStopSeconds)
        try container.encode(speechFrameCount, forKey: .speechFrameCount)
        try container.encode(peakFrameRMS, forKey: .peakFrameRMS)
        try container.encode(trailingSilenceMs, forKey: .trailingSilenceMs)
        try container.encode(handsFreeArmed, forKey: .handsFreeArmed)
        try container.encode(silenceThresholdRMS, forKey: .silenceThresholdRMS)
    }
}

/// Appends one JSON line per finalize or recording end to
/// `finalize-trace.jsonl` (each tagged with a `kind`), rotating to
/// `finalize-trace.1.jsonl` once the file would exceed `maxBytes`. Purely a
/// diagnostic side channel: every failure is swallowed and logged at debug.
nonisolated final class FinalizeTraceLog: Sendable {
    static let fileName = "finalize-trace.jsonl"
    static let rotatedFileName = "finalize-trace.1.jsonl"
    static let defaultMaxBytes = 1_000_000

    private struct Line<Trace: Encodable>: Encodable {
        let ts: String
        let kind: String
        let trace: Trace

        private enum CodingKeys: String, CodingKey { case ts, kind }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(ts, forKey: .ts)
            try container.encode(kind, forKey: .kind)
            try trace.encode(to: encoder)
        }
    }

    private let directory: URL
    private let maxBytes: Int
    private let queue = DispatchQueue(label: "com.orttaai.finalize-trace-log", qos: .utility)

    init(directory: URL, maxBytes: Int = FinalizeTraceLog.defaultMaxBytes) {
        self.directory = directory
        self.maxBytes = maxBytes
    }

    /// The production log in the app's Application Support folder, or nil
    /// when that folder cannot be located.
    @MainActor static func makeDefault() -> FinalizeTraceLog? {
        do {
            return FinalizeTraceLog(directory: try AppStoragePaths.applicationSupportURL())
        } catch {
            Logger.transcription.debug("Finalize trace log unavailable: \(error.localizedDescription)")
            return nil
        }
    }

    /// Queues the trace for writing off the caller's executor.
    func record(_ trace: FinalizeTrace) {
        let timestamp = Date()
        queue.async { [self] in
            append(trace, at: timestamp)
        }
    }

    /// Queues the recording-end trace for writing off the caller's executor.
    func record(_ trace: RecordingEndTrace) {
        let timestamp = Date()
        queue.async { [self] in
            append(trace, at: timestamp)
        }
    }

    /// Blocks until every queued write has finished.
    func flush() {
        queue.sync {}
    }

    func append(_ trace: FinalizeTrace, at timestamp: Date) {
        write(Line(ts: timestamp.formatted(.iso8601), kind: "finalize", trace: trace))
    }

    func append(_ trace: RecordingEndTrace, at timestamp: Date) {
        write(Line(ts: timestamp.formatted(.iso8601), kind: "recording_end", trace: trace))
    }

    private func write(_ line: some Encodable) {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            var data = try encoder.encode(line)
            data.append(0x0A)

            let fileManager = FileManager.default
            let current = directory.appendingPathComponent(Self.fileName)
            let rotated = directory.appendingPathComponent(Self.rotatedFileName)

            let currentSize = (try? fileManager.attributesOfItem(atPath: current.path)[.size] as? Int) ?? 0
            if currentSize > 0, currentSize + data.count > maxBytes {
                try? fileManager.removeItem(at: rotated)
                try fileManager.moveItem(at: current, to: rotated)
            }
            if !fileManager.fileExists(atPath: current.path) {
                guard fileManager.createFile(atPath: current.path, contents: nil) else {
                    Logger.transcription.debug("Finalize trace log: could not create \(current.lastPathComponent)")
                    return
                }
            }

            let handle = try FileHandle(forWritingTo: current)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } catch {
            Logger.transcription.debug("Finalize trace log write failed: \(error.localizedDescription)")
        }
    }
}
