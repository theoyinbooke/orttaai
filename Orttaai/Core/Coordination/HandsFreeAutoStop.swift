// HandsFreeAutoStop.swift
// Orttaai

import Foundation

/// Silence-based auto-stop policy for hands-free dictation.
///
/// Reuses the exact energy framing the transcription pipeline already applies
/// for pause commits (`TranscriptionService.lastSpeechSampleIndex`: 100ms
/// frames at the EnergyVAD 0.02 RMS threshold) — no second audio-analysis
/// path exists. The coordinator feeds it the same sample snapshot the live
/// decode loop already takes every poll.
enum HandsFreeAutoStop {
    static let sampleRate = 16_000

    /// True when the recording should stop because the trailing span of
    /// `samples` carries no speech energy for at least `silenceDuration`.
    ///
    /// Never fires before any speech has been detected: a user who tapped the
    /// hotkey and is still gathering their thoughts keeps the mic open (the
    /// hands-free duration cap remains the hard bound).
    static func shouldAutoStop(
        samples: [Float],
        silenceDuration: TimeInterval
    ) -> Bool {
        guard silenceDuration > 0 else { return false }
        let requiredSilentSamples = Int(silenceDuration * Double(sampleRate))
        guard requiredSilentSamples > 0, samples.count >= requiredSilentSamples else { return false }

        // Only the trailing window plus one energy frame needs scanning: if
        // any speech lives inside it, the trailing silence is too short.
        let scanStart = max(0, samples.count - requiredSilentSamples - TranscriptionService.energyFrameSampleCount)
        if TranscriptionService.lastSpeechSampleIndex(in: samples[scanStart...]) != nil {
            // Speech energy inside (or overlapping) the trailing window.
            // Precise check: how much silence actually trails the last speech?
            guard let lastSpeechEnd = TranscriptionService.lastSpeechSampleIndex(in: samples[...]) else {
                return false
            }
            return samples.count - lastSpeechEnd >= requiredSilentSamples
        }

        // The whole trailing window is silent — but require that speech
        // occurred at some point before it.
        guard TranscriptionService.containsSpeechEnergy(samples[..<scanStart]) else {
            return false
        }
        return true
    }
}
