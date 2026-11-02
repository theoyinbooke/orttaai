// VadBenchTests.swift
// OrttaaiTests
//
// Bench: Silero VAD (FluidAudio) against the hands-free loudness
// detector, on the real-voice corpus. Run with ORTTAAI_VAD_BENCH=1 and
// ORTTAAI_VAD_MANIFEST=<corpus_real/manifest_real.json>.

import AVFoundation
import XCTest
import ExpressAudio
@testable import Orttaai

final class VadBenchTests: XCTestCase {
    private let sampleRate = 16_000
    private let frame = 1_600 // 100 ms, as the loudness detector frames

    func testSileroAgainstLoudnessDetector() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["ORTTAAI_VAD_BENCH"] == "1", let manifestPath = env["ORTTAAI_VAD_MANIFEST"] else {
            throw XCTSkip("Set ORTTAAI_VAD_BENCH=1 and ORTTAAI_VAD_MANIFEST to run the VAD bench.")
        }
        let manifestURL = URL(fileURLWithPath: manifestPath)
        let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as! [String: Any]
        let items = manifest["items"] as! [[String: Any]]
        let clips: [(id: String, category: String, samples: [Float])] = try items.map { item in
            let url = manifestURL.deletingLastPathComponent().appendingPathComponent(item["wav"] as! String)
            return (item["id"] as! String, item["category"] as! String, try readMono16k(url))
        }
        log("clips=\(clips.count) seconds=\(clips.reduce(0) { $0 + $1.samples.count } / sampleRate)")

        let loadStart = Date()
        let vad = try await VadManager()
        log("silero_load_s=\(fmt(Date().timeIntervalSince(loadStart)))")

        var rows: [String] = []
        // name, target peak frame RMS (nil = as recorded), room-tone RMS
        let levels: [(String, Float?, Float)] = [
            ("as_recorded", nil, 0.001),
            ("quiet_wireless", 0.0145, 0.0005),
            ("loud_airpods", 0.10, 0.002),
        ]
        let sileroUnit = Double(VadManager.chunkSize) / Double(sampleRate)
        var noise = SeededNoise(seed: 7)
        // Each clip's speech: from the first to the last moment either
        // detector heard speech in the as-recorded audio. Silence inside it
        // is a pause between words, never the clip's lead-in or tail.
        var regions: [(Double, Double)] = []

        for (levelName, peak, roomRMS) in levels {
            // A long dictation: every clip, separated by 1.5 s thinking pauses.
            var dictation: [Float] = []
            var spans: [(Double, Double)] = []
            for clip in clips {
                let scaled = peak.map { scale(clip.samples, toPeakFrameRMS: $0) } ?? clip.samples
                dictation += noise.tone(seconds: 1.5, rms: roomRMS)
                let start = Double(dictation.count) / Double(sampleRate)
                dictation += scaled
                spans.append((start, Double(dictation.count) / Double(sampleRate)))
            }
            let dictationSeconds = Double(dictation.count) / Double(sampleRate)

            // Ending: real silence in a quiet room, then in a noisy one (fan).
            let quietEnding = dictation + noise.tone(seconds: 8, rms: roomRMS)
            let noisyEnding = dictation + noise.tone(seconds: 8, rms: 0.015)

            // The copy below must match the shipping policy at its floor.
            var policy = HandsFreeAutoStopPolicy()
            policy.advance(totalSampleCount: dictation.count, samplesFrom: { Array(dictation.dropFirst($0)) })
            let copied = loudnessDecisions(dictation, floor: HandsFreeAutoStopPolicy.quietestSpeech).filter { $0 }.count
            XCTAssertEqual(copied, policy.speechFrameCount, "Bench copy drifted from HandsFreeAutoStopPolicy")

            let start = Date()
            let probs = try await vad.process(dictation).map(\.probability)
            let elapsed = Date().timeIntervalSince(start)
            let quietProbs = try await vad.process(quietEnding).map(\.probability)
            let noisyProbs = try await vad.process(noisyEnding).map(\.probability)
            log("silero_speed level=\(levelName) audio_s=\(fmt(dictationSeconds)) compute_s=\(fmt(elapsed)) realtime_x=\(fmt(dictationSeconds / max(elapsed, 0.0001)))")

            var candidates: [(name: String, unit: Double, speech: [Bool], quiet: [Bool], noisy: [Bool])] = []
            for floor in [Float(0.006), Float(0.0015)] {
                candidates.append((
                    "loudness_floor_\(floor)", 0.1, loudnessDecisions(dictation, floor: floor),
                    loudnessDecisions(quietEnding, floor: floor), loudnessDecisions(noisyEnding, floor: floor)
                ))
            }
            for threshold in [Float(0.3), 0.5, 0.85] {
                candidates.append((
                    "silero_\(threshold)", sileroUnit, probs.map { $0 >= threshold },
                    quietProbs.map { $0 >= threshold }, noisyProbs.map { $0 >= threshold }
                ))
            }

            if regions.isEmpty {
                let reference = candidates.filter { $0.name == "loudness_floor_0.0015" || $0.name == "silero_0.5" }
                regions = spans.map { span in
                    var first = span.1, last = span.0
                    for candidate in reference {
                        for (index, isSpeech) in candidate.speech.enumerated() where isSpeech {
                            let t0 = Double(index) * candidate.unit, t1 = t0 + candidate.unit
                            guard t1 > span.0, t0 < span.1 else { continue }
                            first = min(first, max(t0, span.0))
                            last = max(last, min(t1, span.1))
                        }
                    }
                    return (first, last)
                }
                let speechSeconds = regions.reduce(0) { $0 + max(0, $1.1 - $1.0) }
                log("speech_regions seconds=\(fmt(speechSeconds))")
            }

            for candidate in candidates {
                rows.append(row(
                    detector: candidate.name, level: levelName, unitSeconds: candidate.unit,
                    speech: candidate.speech, regions: regions,
                    quietEnding: candidate.quiet, noisyEnding: candidate.noisy
                ))
            }
        }
        rows.forEach(log)
        if let out = env["ORTTAAI_VAD_OUT"] {
            try rows.joined(separator: "\n").write(toFile: out, atomically: true, encoding: .utf8)
        }
    }

    // MARK: - Measures

    /// Inside each clip's speech (first to last word), the longest stretch
    /// judged silent and how many would have hit a 4 s or 6 s window: speech
    /// mistaken for silence. Also how much of that speech counted as speech,
    /// and how much real silence at the end was noticed (stopping needs 4-6 s).
    private func row(
        detector: String, level: String, unitSeconds: Double, speech: [Bool],
        regions: [(Double, Double)], quietEnding: [Bool], noisyEnding: [Bool]
    ) -> String {
        var runs: [Double] = []
        var heard = 0.0, total = 0.0
        for region in regions where region.1 > region.0 {
            let first = Int((region.0 / unitSeconds).rounded(.down))
            let last = min(speech.count, Int((region.1 / unitSeconds).rounded(.up)))
            guard first < last else { continue }
            let slice = Array(speech[first..<last])
            runs += silentRuns(slice).map { Double($0) * unitSeconds }
            heard += Double(slice.filter { $0 }.count) * unitSeconds
            total += Double(slice.count) * unitSeconds
        }
        let longest = runs.max() ?? 0
        let over2 = runs.filter { $0 >= 2 }.count
        let over4 = runs.filter { $0 >= 4 }.count
        let over6 = runs.filter { $0 >= 6 }.count
        let quietTail = Double(trailingSilent(quietEnding)) * unitSeconds
        let noisyTail = Double(trailingSilent(noisyEnding)) * unitSeconds
        return "ROW detector=\(detector) level=\(level) longest_inside_speech_s=\(fmt(longest)) gaps_2s=\(over2) gaps_4s=\(over4) gaps_6s=\(over6) speech_heard=\(fmt(heard / max(total, 0.001))) quiet_end_silence_s=\(fmt(quietTail)) noisy_end_silence_s=\(fmt(noisyTail))"
    }

    private func silentRuns(_ speech: [Bool]) -> [Int] {
        var runs: [Int] = []
        var current = 0
        for isSpeech in speech {
            if isSpeech { if current > 0 { runs.append(current) }; current = 0 } else { current += 1 }
        }
        if current > 0 { runs.append(current) }
        return runs
    }

    private func trailingSilent(_ speech: [Bool]) -> Int {
        speech.reversed().prefix { !$0 }.count
    }

    /// The hands-free policy's frame decisions, with its floor as a parameter
    /// (0.006 shipped in 1.18.0; 0.0015 on the quiet-mic branch).
    private func loudnessDecisions(_ samples: [Float], floor: Float) -> [Bool] {
        var bins = [Int](repeating: 0, count: 26)
        var count = 0
        var peak: Float = 0
        var threshold = TranscriptionService.speechEnergyThreshold
        var decisions: [Bool] = []
        var start = 0
        while start + frame <= samples.count {
            let rms = TranscriptionService.frameRMS(samples[start..<start + frame])
            peak = max(peak, rms)
            let bin = rms > 0.0001 ? min(25, Int((log10(rms) + 4) * 5)) : 0
            bins[bin] += 1
            count += 1
            if count >= 10 {
                var seen = 0
                var background: Float = 0
                for (index, n) in bins.enumerated() {
                    seen += n
                    if seen * 20 >= count {
                        background = index == 0 ? 0 : pow(10, (Float(index) + 0.5) / 5 - 4)
                        break
                    }
                }
                threshold = min(TranscriptionService.speechEnergyThreshold, max(floor, background * 2.5, peak * 0.1))
            }
            decisions.append(rms >= threshold)
            start += frame
        }
        return decisions
    }

    // MARK: - Audio

    private func readMono16k(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        XCTAssertEqual(Int(format.sampleRate), sampleRate, url.lastPathComponent)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: buffer)
        return Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
    }

    private func scale(_ samples: [Float], toPeakFrameRMS target: Float) -> [Float] {
        var peak: Float = 0
        var start = 0
        while start + frame <= samples.count {
            peak = max(peak, TranscriptionService.frameRMS(samples[start..<start + frame]))
            start += frame
        }
        guard peak > 0 else { return samples }
        let gain = target / peak
        return samples.map { $0 * gain }
    }

    private func fmt(_ value: Double) -> String { String(format: "%.2f", value) }

    private func log(_ line: String) { print("VADBENCH \(line)") }
}

/// Deterministic room tone.
private struct SeededNoise {
    private var state: UInt64
    init(seed: UInt64) { state = seed }

    mutating func next() -> Float {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Float(state >> 40) / Float(1 << 24) * 2 - 1
    }

    mutating func tone(seconds: Double, rms: Float) -> [Float] {
        // Uniform noise in [-a, a] has RMS a / sqrt(3).
        let amplitude = rms * 3.0.squareRoot().float
        return (0..<Int(seconds * 16_000)).map { _ in next() * amplitude }
    }
}

private extension Double {
    var float: Float { Float(self) }
}
