// TranscriptionService.swift
// Orttaai

import Foundation
import CoreML
import WhisperKit
import os

protocol Transcribing: Actor {
    var isLoaded: Bool { get }
    func transcribe(audioSamples: [Float]) async throws -> String
    func updateSettings(language: String, computeMode: String)
}

enum SetupModelLoadStage: Sendable {
    case downloading
    case loading
}

actor TranscriptionService: Transcribing {
    private var whisperKit: WhisperKit?

    /// Language code for transcription (e.g. "en", "es", "auto").
    /// Set from AppSettings.dictationLanguage before transcribing.
    var language: String = "en"

    /// Compute mode string from settings. Maps to MLComputeUnits.
    var computeModeSetting: String = "cpuAndNeuralEngine"

    var isLoaded: Bool {
        whisperKit != nil
    }

    func loadModel(named modelName: String) async throws {
        Logger.transcription.info("Loading model: \(modelName)")

        let config = WhisperKitConfig(
            model: modelName,
            computeOptions: computeOptions(),
            voiceActivityDetector: EnergyVAD()
        )

        let wk = try await WhisperKit(config)
        whisperKit = wk

        Logger.transcription.info("Model loaded: \(modelName)")
    }

    func prepareModelForSetup(
        named modelName: String,
        onProgress: (@Sendable (Double) -> Void)? = nil,
        onStageChange: (@Sendable (SetupModelLoadStage) -> Void)? = nil
    ) async throws {
        Logger.transcription.info("Preparing model for setup with progress: \(modelName)")
        onStageChange?(.downloading)
        onProgress?(0)

        let modelFolder = try await WhisperKit.download(
            variant: modelName,
            progressCallback: { progress in
                let clamped = max(0, min(progress.fractionCompleted, 1))
                onProgress?(clamped)
            }
        )

        onProgress?(1)
        onStageChange?(.loading)

        let config = WhisperKitConfig(
            modelFolder: modelFolder.path,
            computeOptions: computeOptions(),
            voiceActivityDetector: EnergyVAD(),
            load: true,
            download: false
        )

        let wk = try await WhisperKit(config)
        whisperKit = wk
        Logger.transcription.info("Setup model prepared: \(modelName)")
    }

    func transcribe(audioSamples: [Float]) async throws -> String {
        guard let wk = whisperKit else {
            throw OrttaaiError.modelNotLoaded
        }

        Logger.transcription.info("Transcribing \(audioSamples.count) samples")

        let decodingLanguage: String? = (language == "auto") ? nil : language

        let options = DecodingOptions(
            language: decodingLanguage,
            temperature: 0.0,
            skipSpecialTokens: true,
            withoutTimestamps: true,
            wordTimestamps: false,
            concurrentWorkerCount: 4,
            chunkingStrategy: .vad
        )

        let results = try await wk.transcribe(audioArray: audioSamples, decodeOptions: options)

        guard let result = results.first else {
            throw OrttaaiError.transcriptionFailed(underlying: NSError(
                domain: "com.orttaai",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "No transcription result"]
            ))
        }

        let text = result.text.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw OrttaaiError.transcriptionFailed(underlying: NSError(
                domain: "com.orttaai",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "No transcription result"]
            ))
        }

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

    func updateSettings(language: String, computeMode: String) {
        self.language = language
        self.computeModeSetting = computeMode
    }

    private func computeOptions() -> ModelComputeOptions {
        let units: MLComputeUnits
        switch computeModeSetting {
        case "cpuAndGPU":
            units = .cpuAndGPU
        case "cpuOnly":
            units = .cpuOnly
        default:
            units = .cpuAndNeuralEngine
        }
        return ModelComputeOptions(
            audioEncoderCompute: units,
            textDecoderCompute: units
        )
    }
}
