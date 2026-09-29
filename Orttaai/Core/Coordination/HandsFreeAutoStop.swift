// HandsFreeAutoStop.swift
// Orttaai

import Foundation

/// Silence-based auto-stop policy for hands-free dictation, and the
/// per-session speech accounting it decides from.
///
/// Reuses the exact energy framing the transcription pipeline already applies
/// for pause commits (100ms frames at the EnergyVAD 0.02 RMS threshold), but
/// accounts for frames incrementally: `advance` scans only the samples
/// recorded since the previous call, so each poll costs a few frames no
/// matter how long the recording or how wide the silence window.
///
/// The recording arms only on sustained speech (a single loud frame — a
/// click, a bump, a cough — never arms it) and stops only once the trailing
/// silence since the last speech frame reaches the configured window.
nonisolated struct HandsFreeAutoStopPolicy: Equatable {
    static let sampleRate = 16_000
    /// Total speech-level audio required before the policy arms (300ms).
    static let minimumSpeechSampleCount = TranscriptionService.energyFrameSampleCount * 3

    /// Samples accounted for so far; always a whole number of frames.
    private(set) var scannedSampleCount = 0
    /// Frames at or above the speech energy threshold.
    private(set) var speechFrameCount = 0
    private(set) var peakFrameRMS: Float = 0
    private var lastSpeechEndSample: Int?

    /// True once enough speech has been heard for silence to mean "finished".
    var isArmed: Bool {
        speechFrameCount * TranscriptionService.energyFrameSampleCount >= Self.minimumSpeechSampleCount
    }

    /// Silence trailing the last speech frame (or the whole recording so far
    /// when none was heard), in milliseconds.
    var trailingSilenceMs: Int {
        (scannedSampleCount - (lastSpeechEndSample ?? 0)) * 1_000 / Self.sampleRate
    }

    /// Accounts for the samples recorded since the last call. `samplesFrom`
    /// returns the recording from the given absolute sample index onward. A
    /// buffer that shrank (capture restarted) starts the accounting over. A
    /// trailing partial frame is left for the next call.
    mutating func advance(totalSampleCount: Int, samplesFrom: (Int) -> [Float]) {
        if totalSampleCount < scannedSampleCount {
            self = HandsFreeAutoStopPolicy()
        }
        let frame = TranscriptionService.energyFrameSampleCount
        guard totalSampleCount - scannedSampleCount >= frame else { return }

        let samples = samplesFrom(scannedSampleCount)
        var frameStart = 0
        while frameStart + frame <= samples.count {
            let rms = TranscriptionService.frameRMS(samples[frameStart..<frameStart + frame])
            peakFrameRMS = max(peakFrameRMS, rms)
            scannedSampleCount += frame
            if rms >= TranscriptionService.speechEnergyThreshold {
                speechFrameCount += 1
                lastSpeechEndSample = scannedSampleCount
            }
            frameStart += frame
        }
    }

    /// True when the recording should stop because the trailing silence has
    /// lasted `silenceWindow` seconds. Never fires before the policy is armed
    /// (a user still gathering their thoughts keeps the mic open; the
    /// hands-free duration cap remains the hard bound) or before
    /// `minimumDuration`, so an auto-stop always produces a real finalization.
    func shouldStop(
        silenceWindow: TimeInterval,
        recordingDuration: TimeInterval,
        minimumDuration: TimeInterval
    ) -> Bool {
        guard silenceWindow > 0, recordingDuration >= minimumDuration, isArmed else { return false }
        return trailingSilenceMs >= Int(silenceWindow * 1_000)
    }
}
