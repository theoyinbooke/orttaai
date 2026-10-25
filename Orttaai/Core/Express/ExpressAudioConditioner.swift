// ExpressAudioConditioner.swift
// Orttaai

import Accelerate
import Foundation

/// Lifts a final word spoken much more quietly than the rest of the
/// recording, which Fluid Speech Mini otherwise tends to drop ("with a good
/// book" -> "with a good"): 3 of 6 synthetic soft endings in the realistic
/// corpus kept their last word before, 6 of 6 after, with no change on 50
/// real recordings. Only the last 1.5 s can change, so a normal recording
/// comes back untouched.
nonisolated enum ExpressAudioConditioner {
    private static let sampleRate = 16_000
    /// 20 ms energy frames.
    private static let frameSampleCount = 320
    static let tailSampleCount = sampleRate * 3 / 2
    private static let rampSampleCount = sampleRate / 10
    private static let maximumGain: Float = 4
    /// The tail must hold at least this much speech (100 ms) to be lifted:
    /// a soft final word does, the hiss or room sound in the pause after the
    /// last word (common on Bluetooth headset mics) does not.
    static let minimumTailSpeechFrames = 5

    /// Returns the samples with the last 1.5 s raised toward the recording's
    /// typical speech level when its speech sits below half of it. Speech
    /// frames are those well above the quietest tenth of the recording, in
    /// the tail as in the body.
    static func liftingQuietTail(_ samples: [Float]) -> [Float] {
        let frameCount = (samples.count - 1) / frameSampleCount
        guard frameCount > tailSampleCount / frameSampleCount else { return samples }

        let frames = samples.withUnsafeBufferPointer { buffer in
            (0..<frameCount).map { index -> Float in
                var rms: Float = 0
                vDSP_rmsqv(buffer.baseAddress! + index * frameSampleCount, 1, &rms, vDSP_Length(frameSampleCount))
                return rms
            }
        }
        let floor = percentile(frames, 0.1)
        let speech = frames.filter { $0 > max(3 * floor, 0.008) }
        guard !speech.isEmpty else { return samples }
        let typical = percentile(speech, 0.5)

        let tailFrames = tailSampleCount / frameSampleCount
        // Same bar as speech in the body: noise a little above the floor
        // must not count, or the lift turns it into words.
        let tailSpeech = frames.suffix(tailFrames).filter { $0 > max(3 * floor, 0.008) }
        guard tailSpeech.count >= minimumTailSpeechFrames else { return samples }
        let tailLevel = percentile(tailSpeech, 0.5)
        guard tailLevel < 0.5 * typical else { return samples }

        let gain = min(maximumGain, typical / tailLevel)
        var lifted = samples
        let start = lifted.count - tailFrames * frameSampleCount
        for index in start..<lifted.count {
            let ramp = min(1, Float(index - start) / Float(rampSampleCount))
            lifted[index] = max(-1, min(1, lifted[index] * (1 + (gain - 1) * ramp)))
        }
        return lifted
    }

    /// The value at `fraction` of the sorted list (0.5 is the median).
    private static func percentile(_ values: [Float], _ fraction: Double) -> Float {
        let sorted = values.sorted()
        return sorted[min(sorted.count - 1, Int(Double(sorted.count) * fraction))]
    }
}
