// ExpressTranscriber.swift
// Orttaai

import ExpressAudio
import Foundation
import os

/// What TranscriptionService needs from a loaded Express model. A protocol so
/// the service can hold one without availability annotations and tests can
/// stand in for Fluid Speech Mini without Core ML models.
protocol ExpressBackend: Actor {
    func transcribe(_ audioSamples: [Float]) async throws -> String
}

/// Fluid Speech Mini through FluidAudio. Decoding is fast enough (about 40 ms
/// for a short dictation, under 300 ms for a 35 s one on the Neural Engine)
/// that it decodes the whole recording once at the end, with no live clips.
@available(macOS 15, *)
actor ExpressTranscriber: ExpressBackend {
    private static let sampleRate = 16_000
    /// FluidAudio rejects audio shorter than one second; silence is padded on.
    private static let minimumSampleCount = sampleRate

    private let asr: AsrManager

    private init(asr: AsrManager) {
        self.asr = asr
    }

    /// Loads the model package installed by `ExpressModelStore`. The first
    /// load on a Mac compiles the package for the Neural Engine (about 10 s);
    /// macOS caches the result, and later loads take a fraction of a second.
    static func load(from folder: URL) async throws -> ExpressTranscriber {
        let models = try AsrModels.loadLocal(from: folder, version: ExpressEngine.modelVersion)
        let asr = AsrManager()
        try await asr.loadModels(models)
        Logger.transcription.info("Express model loaded from \(folder.path, privacy: .public)")
        return ExpressTranscriber(asr: asr)
    }

    func transcribe(_ audioSamples: [Float]) async throws -> String {
        var samples = audioSamples
        if samples.count < Self.minimumSampleCount {
            samples.append(contentsOf: [Float](repeating: 0, count: Self.minimumSampleCount - samples.count))
        }
        var decoderState = TdtDecoderState.make()
        let result = try await asr.transcribe(samples, decoderState: &decoderState)
        return Self.cleanedText(result.text)
    }

    /// Mini occasionally emits `<unk>` where an apostrophe belongs ("I<unk>ll",
    /// once in 50 real recordings). Between letters it becomes an apostrophe;
    /// anywhere else it is dropped.
    nonisolated static func cleanedText(_ text: String) -> String {
        text
            .replacingOccurrences(of: #"(?<=\p{L})<unk>(?=\p{L})"#, with: "'", options: .regularExpression)
            .replacingOccurrences(of: "<unk>", with: " ")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
