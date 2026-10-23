// WordBoostChunks.swift
// Orttaai

import Foundation

/// Word Boost's per-frame CTC scores, split into the same 15 s chunks with
/// 2 s of overlap that FluidAudio uses for long audio, so a recording can be
/// scored chunk by chunk while the user is still speaking. Stitched together,
/// the chunks give exactly the scores FluidAudio computes for the whole
/// recording at once; scoring a 10-minute recording takes about 5 s, nearly
/// all of which now happens before key release.
nonisolated enum WordBoostChunks {
    /// FluidAudio's `ASRConstants.maxModelSamples`: 15 s at 16 kHz.
    static let chunkSampleCount = 240_000
    /// FluidAudio's `CtcKeywordSpotter.chunkOverlapSamples`: 2 s.
    static let overlapSampleCount = 32_000
    static let strideSampleCount = chunkSampleCount - overlapSampleCount
    private static let sampleRate = 16_000.0

    /// The chunks FluidAudio scores for a recording of `sampleCount` samples:
    /// one chunk up to 15 s, otherwise 15 s chunks every 13 s, the last one
    /// ending at the end of the recording.
    static func chunks(forSampleCount sampleCount: Int) -> [Range<Int>] {
        guard sampleCount > 0 else { return [] }
        guard sampleCount > chunkSampleCount else { return [0..<sampleCount] }
        var chunks: [Range<Int>] = []
        var start = 0
        while start < sampleCount {
            let end = min(start + chunkSampleCount, sampleCount)
            chunks.append(start..<end)
            if end >= sampleCount { break }
            start += strideSampleCount
        }
        return chunks
    }

    /// The full 15 s chunks a recording that has reached `sampleCount`
    /// samples already contains. Each is also a chunk of the finished
    /// recording, however long it grows.
    static func completeChunks(inPrefixOf sampleCount: Int) -> [Range<Int>] {
        guard sampleCount >= chunkSampleCount else { return [] }
        let count = (sampleCount - chunkSampleCount) / strideSampleCount + 1
        return (0..<count).map { index in
            let start = index * strideSampleCount
            return start..<(start + chunkSampleCount)
        }
    }

    /// Joins chunk scores the way FluidAudio does: frames where two chunks
    /// overlap are averaged in probability space, and the first chunk's frame
    /// duration sets the overlap length.
    static func stitch(_ chunks: [[[Float]]], frameDuration: Double) -> [[Float]] {
        guard frameDuration > 0 else { return [] }
        let overlapFrames = Int(Double(overlapSampleCount) / sampleRate / frameDuration)
        var stitched: [[Float]] = []
        for (index, frames) in chunks.enumerated() where !frames.isEmpty {
            guard index > 0 else {
                stitched.append(contentsOf: frames)
                continue
            }
            let overlap = min(overlapFrames, stitched.count, frames.count)
            let existingStart = stitched.count - overlap
            for offset in 0..<overlap {
                stitched[existingStart + offset] = averagedFrame(stitched[existingStart + offset], frames[offset])
            }
            stitched.append(contentsOf: frames.dropFirst(overlap))
        }
        return stitched
    }

    /// log((exp(a) + exp(b)) / 2) for each token, computed stably.
    static func averagedFrame(_ existing: [Float], _ incoming: [Float]) -> [Float] {
        let count = min(existing.count, incoming.count)
        guard count > 0 else { return existing }
        let log2: Float = 0.69314718
        return (0..<count).map { index in
            let a = existing[index]
            let b = incoming[index]
            let m = max(a, b)
            guard m != -Float.infinity else { return -Float.infinity }
            return m + logf(expf(a - m) + expf(b - m)) - log2
        }
    }

    /// Identifies a chunk's audio, so scores computed during recording are
    /// reused only for exactly the same samples (the quiet-tail lift can
    /// change the last 1.5 s before the final decode).
    static func fingerprint(_ samples: ArraySlice<Float>) -> Int {
        var hasher = Hasher()
        hasher.combine(samples.count)
        samples.withUnsafeBytes { hasher.combine(bytes: $0) }
        return hasher.finalize()
    }
}
