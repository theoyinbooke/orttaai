// HandsFreeAutoStop.swift
// Orttaai

import Foundation

/// Silence-based auto-stop policy for hands-free dictation, and the
/// per-session speech accounting it decides from.
///
/// Reuses the energy framing the transcription pipeline already applies
/// (100ms frames), but accounts for frames incrementally: `advance` scans
/// only the samples recorded since the previous call, so each poll costs a
/// few frames no matter how long the recording or how wide the silence window.
///
/// The recording arms only on sustained speech at the EnergyVAD 0.02 RMS
/// threshold (a single loud frame — a click, a bump, a cough — never arms
/// it). Once armed, the 0.02 threshold alone is too high to tell soft speech
/// from silence: a quiet speaker's words can sit below it for seconds at a
/// time. So voice also continues on two consecutive frames above a
/// noise-aware threshold, measured from the session's own room noise like
/// pause commits. That threshold never exceeds 0.02, so the policy never
/// stops sooner than the plain VAD threshold would.
nonisolated struct HandsFreeAutoStopPolicy: Equatable {
    static let sampleRate = 16_000
    /// Total speech-level audio required before the policy arms (300ms).
    static let minimumSpeechSampleCount = TranscriptionService.energyFrameSampleCount * 3
    /// Consecutive frames above the noise-aware threshold that count as voice.
    /// One frame alone is usually a click or a key press.
    static let quietVoiceRunFrameCount = 2
    /// Margin over the measured background, as for pause commits.
    static let backgroundMargin: Float = 1.8
    /// Background histogram resolution. Backgrounds at or above the top bin
    /// already put the threshold at its 0.02 ceiling.
    private static let backgroundBinWidth: Float = 0.0002
    private static let backgroundBinCount =
        Int((TranscriptionService.speechEnergyThreshold / backgroundMargin / backgroundBinWidth).rounded(.up)) + 1

    /// Samples accounted for so far; always a whole number of frames.
    private(set) var scannedSampleCount = 0
    /// Frames at or above the speech energy threshold.
    private(set) var speechFrameCount = 0
    private(set) var peakFrameRMS: Float = 0
    private var lastSpeechEndSample: Int?
    /// Frame energies so far, binned, for the background estimate.
    private var backgroundHistogram = [Int](repeating: 0, count: backgroundBinCount)
    private var quietVoiceRun = 0

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
            let bin = min(Self.backgroundBinCount - 1, Int(rms / Self.backgroundBinWidth))
            backgroundHistogram[bin] += 1
            if rms >= TranscriptionService.speechEnergyThreshold {
                speechFrameCount += 1
                lastSpeechEndSample = scannedSampleCount
            }
            if rms >= silenceThresholdRMS {
                quietVoiceRun += 1
                if quietVoiceRun >= Self.quietVoiceRunFrameCount, isArmed {
                    lastSpeechEndSample = scannedSampleCount
                }
            } else {
                quietVoiceRun = 0
            }
            frameStart += frame
        }
    }

    /// Frames below this RMS count as silence once the policy is armed: the
    /// quietest tenth of frames so far, plus a margin, bounded between the
    /// dead-silence floor and the speech threshold.
    var silenceThresholdRMS: Float {
        let frameCount = scannedSampleCount / TranscriptionService.energyFrameSampleCount
        guard frameCount > 0 else { return TranscriptionService.faintEnergyFloor }
        let target = (frameCount - 1) / 10
        var seen = 0
        var bin = 0
        while bin < Self.backgroundBinCount - 1 {
            seen += backgroundHistogram[bin]
            if seen > target { break }
            bin += 1
        }
        let background = (Float(bin) + 1) * Self.backgroundBinWidth
        return min(
            TranscriptionService.speechEnergyThreshold,
            max(TranscriptionService.faintEnergyFloor, background * Self.backgroundMargin)
        )
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
