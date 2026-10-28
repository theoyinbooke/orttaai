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
//           clip-commit/pause-commit/speculative-tail machinery. Each item's
//           raw JSON also carries the finalize_trace (path, tail energy,
//           per-stage timings) from finalizeLiveTranscriptionDetailed.
//
// Environment:
//   ORTTAAI_ASR_EVAL=1            enable
//   ORTTAAI_ASR_EVAL_MANIFEST     path to corpus/manifest.json or
//                                 corpus_realistic/manifest_realistic.json (required)
//   ORTTAAI_ASR_EVAL_OUT          path for the raw decode JSON (required)
//   ORTTAAI_ASR_EVAL_MODEL        model name (default openai_whisper-large-v3);
//                                 fluid-speech-mini runs Express, installing it
//                                 into ORTTAAI_ASR_EVAL_MODEL_ROOT when missing
//   ORTTAAI_ASR_EVAL_PRESET       fast|balanced|accuracy (default balanced —
//                                 the user's active preset)
//   ORTTAAI_ASR_EVAL_SPEEDUP      live feed pacing multiple of realtime
//                                 (default 4; snapshots grow by 250 ms of
//                                 audio and the poll sleep is 250 ms / N)
//   ORTTAAI_ASR_EVAL_PATHS        both|whole|live (default both)
//   ORTTAAI_ASR_EVAL_IDS          comma-separated item subset
//   ORTTAAI_ASR_EVAL_RULES        1 to also record each transcript after the app's
//                                 rule stage (filler cleanup, then spoken formatting,
//                                 as RuleBasedTextProcessor runs them with an empty
//                                 dictionary) as rules_text, the polish stage's input
//   ORTTAAI_ASR_EVAL_BIAS         1 to snapshot the manifest's bias_vocabulary
//                                 (for fluid-speech-mini: the Word Boost vocabulary)
//   ORTTAAI_ASR_EVAL_EXPRESS_SEGMENTS 1 for fluid-speech-mini's live segments
//                                 on the live path (whole stays one decode)
//   ORTTAAI_ASR_EVAL_TRAILING_SILENCE_MS  quiet appended to every recording,
//                                 both paths, as a speaker leaves before
//                                 letting go of the key (1300 was the median
//                                 on this Mac in October 2026): the item's
//                                 quietest 100 ms frame, repeated
//   ORTTAAI_ASR_EVAL_MODEL_ROOT   a storage base laid out like WhisperKit's (models/argmaxinc/whisperkit-coreml/<variant>,
//                                 models/openai/whisper-*); loads from there instead of scanning ~/Documents, the custom
//                                 storage folder and the caches, so the eval never triggers a macOS folder-access prompt
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
        var rules_text: String?
    }

    private struct ItemResult: Encodable {
        let id: String
        let whole: PathResult?
        let live: PathResult?
        /// How the live finalize got its transcript; nil when the live path
        /// was not run or finalize threw.
        let finalize_trace: FinalizeTrace?
        /// The process's physical footprint after the item and its peak so
        /// far, in MB (what Activity Monitor reports as Memory).
        let footprint_mb: Int?
        let peak_footprint_mb: Int?
    }

    private struct RunOutput: Encodable {
        let model: String
        let preset: String
        let speedup: Double
        let biasEnabled: Bool
        let biasTermCount: Int
        /// The test host's footprint before any speech model loaded.
        let footprint_before_load_mb: Int?
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
        let trailingSilenceMs = Int(env["ORTTAAI_ASR_EVAL_TRAILING_SILENCE_MS"] ?? "0") ?? 0
        let paths = env["ORTTAAI_ASR_EVAL_PATHS"] ?? "both"
        let biasEnabled = env["ORTTAAI_ASR_EVAL_BIAS"] == "1"
        let rulesEnabled = env["ORTTAAI_ASR_EVAL_RULES"] == "1"
        let idFilter: Set<String>? = env["ORTTAAI_ASR_EVAL_IDS"].map {
            Set($0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
        }
        guard let preset = DecodingPreset(rawValue: presetName) else {
            XCTFail("Unknown preset \(presetName)")
            return
        }

        let service: TranscriptionService
        if let rootPath = env["ORTTAAI_ASR_EVAL_MODEL_ROOT"] {
            let base = URL(fileURLWithPath: rootPath, isDirectory: true)
            let probes = ModelProbeTestSupport.probes(
                roots: [ModelProbeTestSupport.repositoryRoot(under: base)],
                beginAccessBase: base
            )
            service = TranscriptionService(
                modelLocator: ModelProbeTestSupport.locator(probes: probes, probeTimeout: 60, cacheLifetime: 3600),
                legacyTokenizerBase: nil
            )
        } else {
            service = TranscriptionService()
        }
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

        if modelName == ExpressEngine.modelID, let rootPath = env["ORTTAAI_ASR_EVAL_MODEL_ROOT"] {
            // Express goes through the same installer Settings uses, into the
            // eval's storage base, so the run also checks the pinned download.
            let base = URL(fileURLWithPath: rootPath, isDirectory: true)
            if !ExpressModelStore.packages.allSatisfy({ ExpressModelStore.isInstalled($0, in: base) }) {
                print("ASR-EVAL: installing \(ExpressEngine.displayName) into \(rootPath)")
                try await ExpressModelStore.installMissing(into: base) { _ in }
            }
        }
        if biasEnabled {
            // Express's Word Boost takes the same manifest vocabulary as the
            // simulated user dictionary; WhisperKit ignores it.
            await service.setWordBoostVocabulary(manifest.bias_vocabulary.map { WordBoostTerm(text: $0, aliases: []) })
        }

        let footprintBeforeLoad = Self.footprintMB()?.current
        print("ASR-EVAL: loading model \(modelName)")
        try await service.loadModel(named: modelName)
        await service.warmUp()

        await service.setExpressLiveSegments(env["ORTTAAI_ASR_EVAL_EXPRESS_SEGMENTS"] == "1")
        let items = manifest.items.filter { idFilter?.contains($0.id) ?? true }
        var results: [ItemResult] = []

        for (index, item) in items.enumerated() {
            var samples = try Self.loadFloat32WAV(url: corpusDir.appendingPathComponent(item.wav))
            if trailingSilenceMs > 0 {
                samples += Self.roomTone(from: samples, sampleCount: trailingSilenceMs * manifest.sample_rate / 1_000)
            }
            var whole: PathResult?
            var live: PathResult?
            var finalizeTrace: FinalizeTrace?

            if paths == "both" || paths == "whole" {
                whole = await Self.timedDecode {
                    try await service.transcribe(audioSamples: samples)
                }
            }

            if paths == "both" || paths == "live" {
                await service.beginLiveTranscriptionSession()
                // Growing-snapshot polling: 250 ms of audio per poll, sleep
                // scaled by the speedup factor. Same call sequence as
                // DictationCoordinator.startBackgroundDecodeLoop.
                let increment = manifest.sample_rate / 4
                let sleepNs = UInt64(250_000_000.0 / speedup)
                var fed = 0
                while fed < samples.count {
                    fed = min(fed + increment, samples.count)
                    if let start = await service.liveAudioSnapshotStart(capturedSampleCount: fed) {
                        await service.processLiveAudio(Array(samples[start..<fed]), startingAt: start)
                    }
                    try? await Task.sleep(nanoseconds: sleepNs)
                }
                live = await Self.timedDecode {
                    let finalized = try await service.finalizeLiveTranscriptionDetailed(audioSamples: samples)
                    finalizeTrace = finalized.trace
                    return finalized.text
                }
            }

            if rulesEnabled {
                if let text = whole?.text { whole?.rules_text = Self.ruleStageText(text) }
                if let text = live?.text { live?.rules_text = Self.ruleStageText(text) }
            }

            let footprint = Self.footprintMB()
            results.append(ItemResult(
                id: item.id,
                whole: whole,
                live: live,
                finalize_trace: finalizeTrace,
                footprint_mb: footprint?.current,
                peak_footprint_mb: footprint?.peak
            ))
            print("ASR-EVAL [\(index + 1)/\(items.count)] \(item.id) whole=\(whole?.ms ?? -1)ms live_finalize=\(live?.ms ?? -1)ms")
        }

        let output = RunOutput(
            model: modelName,
            preset: presetName,
            speedup: speedup,
            biasEnabled: biasEnabled,
            biasTermCount: biasEnabled ? manifest.bias_vocabulary.count : 0,
            footprint_before_load_mb: footprintBeforeLoad,
            items: results
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(output).write(to: URL(fileURLWithPath: outPath))
        print("ASR-EVAL: wrote \(results.count) item results to \(outPath)")
    }

    private static func footprintMB() -> (current: Int, peak: Int)? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return (Int(info.phys_footprint >> 20), Int(info.ledger_phys_footprint_peak >> 20))
    }

    private static func ruleStageText(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return text }
        return SpokenFormattingFormatter.format(DisfluencyCleaner.clean(trimmed).text).text
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

    /// The recording's quietest 100 ms frame, repeated for `sampleCount`
    /// samples: the room as the mic heard it, for the quiet a speaker leaves
    /// before letting go of the key.
    static func roomTone(from samples: [Float], sampleCount: Int) -> [Float] {
        let frame = TranscriptionService.energyFrameSampleCount
        guard samples.count >= frame else { return [Float](repeating: 0, count: sampleCount) }
        var quietest = 0
        var lowest = Float.greatestFiniteMagnitude
        var start = 0
        while start + frame <= samples.count {
            let rms = TranscriptionService.frameRMS(samples[start..<start + frame])
            if rms < lowest {
                lowest = rms
                quietest = start
            }
            start += frame
        }
        return (0..<sampleCount).map { samples[quietest + $0 % frame] }
    }

    /// Minimal RIFF parser for the mono Float32 16 kHz WAVs the corpus
    /// builder emits.
    static func loadFloat32WAV(url: URL) throws -> [Float] {
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
