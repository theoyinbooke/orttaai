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
/// noisy rooms behave as before) nor looser than 0.0015.
///
/// That last floor was 0.006 until a wireless microphone with a near-silent
/// room (about 0.0005) recorded soft speech peaking at 0.0145: only 25 of 360
/// frames cleared 0.006, and a 36-second recording of 117 words stopped as
/// "silent". The background and peak terms already set the line for each
/// microphone, so the floor only has to sit above near-digital silence.
///
/// The recording arms only on sustained speech (a single loud frame — a
/// click, a bump, a cough — never arms it) and stops only once the trailing
/// silence since the last speech frame reaches the configured window.
///
/// Loudness can't tell a soft word from a quiet room, or a fan from a voice.
/// When the Silero voice detector is available, its verdicts decide instead
/// (`heardVoice`): on the real-voice corpus it heard 95–96% of speech at any
/// microphone level, against 28–73% for loudness, and it was the only one to
/// notice silence over fan noise. Loudness stays as the fallback, and its
/// numbers stay in the trace either way.
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
    /// Never counts audio this quiet as speech: well above a muted or
    /// near-silent input, below soft speech on a quiet microphone.
    static let quietestSpeech: Float = 0.0015

    /// True once the voice detector's verdicts decide, rather than loudness.
    private(set) var usesVoiceDetector = false
    /// Samples the voice detector has judged so far.
    private(set) var voiceScannedSampleCount = 0
    /// Audio the voice detector judged to be speech.
    private(set) var voiceSpeechSampleCount = 0
    private var lastVoiceEndSample: Int?

    /// True once enough speech has been heard for silence to mean "finished".
    var isArmed: Bool {
        if usesVoiceDetector {
            return voiceSpeechSampleCount >= Self.minimumSpeechSampleCount
        }
        return speechFrameCount * TranscriptionService.energyFrameSampleCount >= Self.minimumSpeechSampleCount
    }

    /// Silence trailing the last speech (or the whole recording so far when
    /// none was heard), in milliseconds.
    var trailingSilenceMs: Int {
        if usesVoiceDetector {
            return (voiceScannedSampleCount - (lastVoiceEndSample ?? 0)) * 1_000 / Self.sampleRate
        }
        return (scannedSampleCount - (lastSpeechEndSample ?? 0)) * 1_000 / Self.sampleRate
    }

    /// The voice detector's verdicts on consecutive chunks of
    /// `chunkSampleCount` samples, starting where its last verdict ended.
    /// From the first call on, these decide when the recording has gone quiet.
    mutating func heardVoice(_ speech: [Bool], chunkSampleCount: Int) {
        usesVoiceDetector = true
        for isSpeech in speech {
            voiceScannedSampleCount += chunkSampleCount
            if isSpeech {
                voiceSpeechSampleCount += chunkSampleCount
                lastVoiceEndSample = voiceScannedSampleCount
            }
        }
    }

    /// Goes back to loudness for the rest of the recording, when the voice
    /// detector fails partway.
    mutating func abandonVoiceDetector() {
        usesVoiceDetector = false
        voiceDetectorFailed = true
    }

    /// The voice detector failed during this recording; don't ask it again.
    private(set) var voiceDetectorFailed = false

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
