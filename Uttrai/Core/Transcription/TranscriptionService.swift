// TranscriptionService.swift
// Uttrai

import Foundation
import WhisperKit
import os

actor TranscriptionService {
    private var whisperKit: WhisperKit?

    var isLoaded: Bool {
        whisperKit != nil
    }

    func loadModel(named modelName: String) async throws {
        Logger.transcription.info("Loading model: \(modelName)")

        let config = WhisperKitConfig(
            model: modelName,
            computeOptions: ModelComputeOptions(
                audioEncoderCompute: .cpuAndNeuralEngine,
                textDecoderCompute: .cpuAndNeuralEngine
            )
        )

        let wk = try await WhisperKit(config)
        whisperKit = wk

        Logger.transcription.info("Model loaded: \(modelName)")
    }

    func transcribe(audioSamples: [Float]) async throws -> String {
        guard let wk = whisperKit else {
            throw UttraiError.modelNotLoaded
        }

        Logger.transcription.info("Transcribing \(audioSamples.count) samples")

        let results = try await wk.transcribe(audioArray: audioSamples)

        guard let result = results.first, !result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw UttraiError.transcriptionFailed(underlying: NSError(
                domain: "com.uttrai",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "No transcription result"]
            ))
        }

        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        Logger.transcription.info("Transcription complete: \(text.prefix(50))...")
        return text
    }

    func unloadModel() {
        whisperKit = nil
        Logger.transcription.info("Model unloaded")
    }

    func warmUp() async {
        guard whisperKit != nil else { return }

        Logger.transcription.info("Warming up model with 1s silence")
        let silentSamples = [Float](repeating: 0, count: 16000) // 1 second at 16kHz

        do {
            _ = try await transcribe(audioSamples: silentSamples)
        } catch {
            // Warm-up transcription of silence may produce empty results — that's fine
            Logger.transcription.info("Warm-up complete (result may be empty, that's expected)")
        }
    }
}
