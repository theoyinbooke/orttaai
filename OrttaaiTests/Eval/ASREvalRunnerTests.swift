// ASREvalRunnerTests.swift
// OrttaaiTests
//
// Heavyweight WER eval runner for gauntlet/asr_eval. Env-gated so the normal
// unit suite never touches it: set ORTTAAI_ASR_EVAL=1 (via TEST_RUNNER_
// prefixed variables when invoking xcodebuild) to run.
//
// The runner decodes every corpus item through BOTH production paths of the
// real TranscriptionService actor:
//   whole — transcribe(audioSamples:), the single whole-utterance decode.
//   live  — beginLiveTranscriptionSession + incremental
//           processLiveAudioSnapshot feeding (the same growing-snapshot
//           polling DictationCoordinator performs, paced at a configurable
//           multiple of realtime) + finalizeLiveTranscription, i.e. the real
//           clip-commit/pause-commit/speculative-tail machinery.
//
// Environment:
//   ORTTAAI_ASR_EVAL=1            enable
//   ORTTAAI_ASR_EVAL_MANIFEST     path to corpus/manifest.json (required)
//   ORTTAAI_ASR_EVAL_OUT          path for the raw decode JSON (required)
//   ORTTAAI_ASR_EVAL_MODEL        model name (default openai_whisper-large-v3)
//   ORTTAAI_ASR_EVAL_PRESET       fast|balanced|accuracy (default balanced —
//                                 the user's active preset)
//   ORTTAAI_ASR_EVAL_SPEEDUP      live feed pacing multiple of realtime
//                                 (default 4; snapshots grow by 250 ms of
//                                 audio and the poll sleep is 250 ms / N)
//   ORTTAAI_ASR_EVAL_PATHS        both|whole|live (default both)
//   ORTTAAI_ASR_EVAL_IDS          comma-separated item subset
//   ORTTAAI_ASR_EVAL_BIAS         1 to snapshot the manifest's bias_vocabulary
//                                 into the service's vocabulary biasing (the
//                                 production dictionary-snapshot mechanism)

import XCTest
@testable import Orttaai

final class ASREvalRunnerTests: XCTestCase {
    private struct Manifest: Decodable {
        struct Item: Decodable {
            let id: String
            let category: String
            let adversarial: String?
            let reference: String
            let wav: String
            let duration_seconds: Double
        }

        let sample_rate: Int
        let bias_vocabulary: [String]
        let items: [Item]
    }

    private struct PathResult: Encodable {
        let text: String
        let ms: Int
        let error: String?
    }

    private struct ItemResult: Encodable {
        let id: String
        let whole: PathResult?
        let live: PathResult?
    }

    private struct RunOutput: Encodable {
        let model: String
        let preset: String
        let speedup: Double
        let biasEnabled: Bool
        let biasTermCount: Int
        let items: [ItemResult]
    }

    func testRunASREval() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["ORTTAAI_ASR_EVAL"] == "1" else {
            throw XCTSkip("ORTTAAI_ASR_EVAL not set; eval runner disabled")
        }
        guard let manifestPath = env["ORTTAAI_ASR_EVAL_MANIFEST"],
              let outPath = env["ORTTAAI_ASR_EVAL_OUT"] else {
            XCTFail("ORTTAAI_ASR_EVAL_MANIFEST and ORTTAAI_ASR_EVAL_OUT are required")
            return
        }

        let manifest = try JSONDecoder().decode(
            Manifest.self,
            from: Data(contentsOf: URL(fileURLWithPath: manifestPath))
        )
        let corpusDir = URL(fileURLWithPath: manifestPath).deletingLastPathComponent()

        let modelName = env["ORTTAAI_ASR_EVAL_MODEL"] ?? "openai_whisper-large-v3"
        let presetName = env["ORTTAAI_ASR_EVAL_PRESET"] ?? "balanced"
        let speedup = Double(env["ORTTAAI_ASR_EVAL_SPEEDUP"] ?? "4") ?? 4
        let paths = env["ORTTAAI_ASR_EVAL_PATHS"] ?? "both"
        let biasEnabled = env["ORTTAAI_ASR_EVAL_BIAS"] == "1"
        let idFilter: Set<String>? = env["ORTTAAI_ASR_EVAL_IDS"].map {
            Set($0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
        }
        guard let preset = DecodingPreset(rawValue: presetName) else {
            XCTFail("Unknown preset \(presetName)")
            return
        }

        let service = TranscriptionService()
        await service.updateSettings(
            language: "en",
            computeMode: "cpuAndNeuralEngine",
            lowLatencyMode: false,
            decodingPreferences: DecodingPreferences(
                preset: preset,
                expertOverridesEnabled: false,
                temperature: DecodingPreferences.defaultTemperature,
                topK: DecodingPreferences.defaultTopK,
                fallbackCount: DecodingPreferences.defaultFallbackCount,
                compressionRatioThreshold: DecodingPreferences.defaultCompressionRatioThreshold,
                logProbThreshold: DecodingPreferences.defaultLogProbThreshold,
                noSpeechThreshold: DecodingPreferences.defaultNoSpeechThreshold,
                workerCount: DecodingPreferences.defaultWorkerCount
            )
        )
        if biasEnabled {
            // Same production API DictationCoordinator uses to snapshot the
            // user dictionary at session start.
            await service.setVocabularyBias(terms: manifest.bias_vocabulary)
        }

        print("ASR-EVAL: loading model \(modelName)")
        try await service.loadModel(named: modelName)
        await service.warmUp()

        let items = manifest.items.filter { idFilter?.contains($0.id) ?? true }
        var results: [ItemResult] = []

        for (index, item) in items.enumerated() {
            let samples = try Self.loadFloat32WAV(url: corpusDir.appendingPathComponent(item.wav))
            var whole: PathResult?
            var live: PathResult?

            if paths == "both" || paths == "whole" {
                whole = await Self.timedDecode {
                    try await service.transcribe(audioSamples: samples)
                }
            }

            if paths == "both" || paths == "live" {
                await service.beginLiveTranscriptionSession()
                // Growing-snapshot polling: 250 ms of audio per poll, sleep
                // scaled by the speedup factor. Same call sequence as
                // DictationCoordinator.startLiveDecodeLoop.
                let increment = manifest.sample_rate / 4
                let sleepNs = UInt64(250_000_000.0 / speedup)
                var fed = 0
                while fed < samples.count {
                    fed = min(fed + increment, samples.count)
                    await service.processLiveAudioSnapshot(Array(samples[0..<fed]))
                    try? await Task.sleep(nanoseconds: sleepNs)
                }
                live = await Self.timedDecode {
                    try await service.finalizeLiveTranscription(audioSamples: samples)
                }
            }

            results.append(ItemResult(id: item.id, whole: whole, live: live))
            print("ASR-EVAL [\(index + 1)/\(items.count)] \(item.id) whole=\(whole?.ms ?? -1)ms live_finalize=\(live?.ms ?? -1)ms")
        }

        let output = RunOutput(
            model: modelName,
            preset: presetName,
            speedup: speedup,
            biasEnabled: biasEnabled,
            biasTermCount: biasEnabled ? manifest.bias_vocabulary.count : 0,
            items: results
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(output).write(to: URL(fileURLWithPath: outPath))
        print("ASR-EVAL: wrote \(results.count) item results to \(outPath)")
    }

    private static func timedDecode(_ body: () async throws -> String) async -> PathResult {
        let start = CFAbsoluteTimeGetCurrent()
        do {
            let text = try await body()
            return PathResult(text: text, ms: Int((CFAbsoluteTimeGetCurrent() - start) * 1000), error: nil)
        } catch {
            return PathResult(text: "", ms: Int((CFAbsoluteTimeGetCurrent() - start) * 1000), error: "\(error)")
        }
    }

    /// Minimal RIFF parser for the mono Float32 16 kHz WAVs the corpus
    /// builder emits.
    private static func loadFloat32WAV(url: URL) throws -> [Float] {
        let data = try Data(contentsOf: url)
        guard data.count > 44,
              data[0..<4].elementsEqual("RIFF".utf8),
              data[8..<12].elementsEqual("WAVE".utf8) else {
            throw NSError(domain: "asr-eval", code: 1, userInfo: [NSLocalizedDescriptionKey: "not a wav: \(url.path)"])
        }

        var pos = 12
        var formatCode: UInt16 = 0
        var samples: [Float] = []
        while pos + 8 <= data.count {
            let chunkID = data[pos..<pos + 4]
            let size = Int(data.readLittleEndian(UInt32.self, at: pos + 4))
            let bodyStart = pos + 8
            let bodyEnd = min(bodyStart + size, data.count)
            if chunkID.elementsEqual("fmt ".utf8) {
                formatCode = data.readLittleEndian(UInt16.self, at: bodyStart)
            } else if chunkID.elementsEqual("data".utf8) {
                let count = (bodyEnd - bodyStart) / 4
                samples = [Float](unsafeUninitializedCapacity: count) { buffer, initialized in
                    for i in 0..<count {
                        let bits = data.readLittleEndian(UInt32.self, at: bodyStart + i * 4)
                        buffer[i] = Float(bitPattern: bits)
                    }
                    initialized = count
                }
            }
            pos = bodyStart + size + (size & 1)
        }
        guard formatCode == 3, !samples.isEmpty else {
            throw NSError(domain: "asr-eval", code: 2, userInfo: [NSLocalizedDescriptionKey: "expected float32 wav: \(url.path)"])
        }
        return samples
    }
}

private extension Data {
    func readLittleEndian<T: FixedWidthInteger>(_ type: T.Type, at offset: Int) -> T {
        let start = startIndex + offset
        var value: T = 0
        for i in 0..<MemoryLayout<T>.size {
            value |= T(self[start + i]) << (8 * i)
        }
        return value
    }
}
