// HandsFreeAutoStop.swift
// Orttaai

import Foundation

/// Silence-based auto-stop policy for hands-free dictation, and the
/// per-session speech accounting it decides from.
///
/// Uses the transcription pipeline's energy framing (100ms frames), and
/// accounts for frames incrementally: `advance` scans only the samples
/// recorded since the previous call, so each poll costs a few frames no
/// matter how long the recording or how wide the silence window.
///
/// What counts as speech adapts to the session. A fixed 0.02 RMS line (the
/// EnergyVAD threshold) cut people off mid-sentence when their microphone ran
/// quiet: on a test Mac, speech peaking at 0.025 left only 4 of 520 frames
/// over the line, and the six-second silence window stopped a recording the
/// person was still talking into. Speech is now a frame well above the
/// session's own background (2.5 times its quietest 5%) and not far below its
/// loudest (a tenth of the peak), never stricter than 0.02 (loud setups and
/// noisy rooms behave as before) nor looser than 0.006.
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
    /// What counts as speech now; the transcription's 0.02 until a second of
    /// audio shows the session's background.
    private(set) var speechThreshold = TranscriptionService.speechEnergyThreshold
    /// Every frame's loudness so far, in bins a fifth of a decade wide from
    /// 0.0001 RMS, for the session's background without keeping every frame.
    private var loudness = [Int](repeating: 0, count: Self.loudnessBins)
    private var frameCount = 0

    private static let loudnessBins = 26
    /// Never counts audio this quiet as speech (the transcription's faint floor, plus a margin).
    static let quietestSpeech: Float = 0.006

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
            heard(rms)
            if rms >= speechThreshold {
                speechFrameCount += 1
                lastSpeechEndSample = scannedSampleCount
            }
            frameStart += frame
        }
    }

    /// Counts the frame's loudness, and sets what counts as speech from the
    /// session so far.
    private mutating func heard(_ rms: Float) {
        let bin = rms > 0.0001 ? min(Self.loudnessBins - 1, Int((log10(rms) + 4) * 5)) : 0
        loudness[bin] += 1
        frameCount += 1
        guard frameCount >= 10 else { return }
        // The quietest 5% of frames: pauses and breaths, or the room.
        var seen = 0
        var background: Float = 0
        for (index, count) in loudness.enumerated() {
            seen += count
            if seen * 20 >= frameCount {
                background = index == 0 ? 0 : pow(10, (Float(index) + 0.5) / 5 - 4)
                break
            }
        }
        let adaptive = max(Self.quietestSpeech, background * 2.5, peakFrameRMS * 0.1)
        speechThreshold = min(TranscriptionService.speechEnergyThreshold, adaptive)
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
