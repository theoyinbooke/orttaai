// TranscriptionService.swift
// Orttaai

import Foundation
import CoreML
import WhisperKit
import os

protocol Transcribing: Actor {
    var isLoaded: Bool { get }
    func loadedModelID() -> String?
    func transcribe(audioSamples: [Float]) async throws -> String
    func updateSettings(
        language: String,
        computeMode: String,
        lowLatencyMode: Bool,
        decodingPreferences: DecodingPreferences
    )
}

enum SetupModelLoadStage: Sendable {
    case downloading
    case loading
}

actor TranscriptionService: Transcribing {
    private var whisperKit: WhisperKit?
    private var loadedModelIDValue: String?

    /// Language code for transcription (e.g. "en", "es", "auto").
    /// Set from AppSettings.dictationLanguage before transcribing.
    var language: String = "en"

    /// Compute mode string from settings. Maps to MLComputeUnits.
    var computeModeSetting: String = "cpuAndNeuralEngine"
    var lowLatencyModeEnabled: Bool = false
    var decodingPreferences: DecodingPreferences = .default

    var isLoaded: Bool {
        whisperKit != nil
    }

    func loadedModelID() -> String? {
        loadedModelIDValue
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
        loadedModelIDValue = modelName

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
        loadedModelIDValue = modelName
        Logger.transcription.info("Setup model prepared: \(modelName)")
    }

    func transcribe(audioSamples: [Float]) async throws -> String {
        guard let wk = whisperKit else {
            throw OrttaaiError.modelNotLoaded
        }

        Logger.transcription.info("Transcribing \(audioSamples.count) samples")

        let decodingLanguage: String? = (language == "auto") ? nil : language
        let resolvedDecoding = resolvedDecodingOptions()

        let options = DecodingOptions(
            language: decodingLanguage,
            temperature: resolvedDecoding.temperature,
            temperatureFallbackCount: resolvedDecoding.fallbackCount,
            topK: resolvedDecoding.topK,
            skipSpecialTokens: true,
            withoutTimestamps: true,
            wordTimestamps: false,
            compressionRatioThreshold: resolvedDecoding.compressionRatioThreshold,
            logProbThreshold: resolvedDecoding.logProbThreshold,
            noSpeechThreshold: resolvedDecoding.noSpeechThreshold,
            concurrentWorkerCount: resolvedDecoding.workerCount,
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
        loadedModelIDValue = nil
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

    func updateSettings(
        language: String,
        computeMode: String,
        lowLatencyMode: Bool,
        decodingPreferences: DecodingPreferences
    ) {
        self.language = language
        self.computeModeSetting = computeMode
        self.lowLatencyModeEnabled = lowLatencyMode
        self.decodingPreferences = decodingPreferences.clamped()
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

    private func preferredConcurrentWorkerCount() -> Int {
        guard lowLatencyModeEnabled else { return 4 }

        let modelID = loadedModelIDValue?.lowercased() ?? ""
        if modelID.contains("tiny") || modelID.contains("small") || modelID.contains("base") {
            return 2
        }
        return 3
    }

    private func resolvedDecodingOptions() -> (
        temperature: Float,
        topK: Int,
        fallbackCount: Int,
        compressionRatioThreshold: Float?,
        logProbThreshold: Float?,
        noSpeechThreshold: Float?,
        workerCount: Int
    ) {
        let prefs = decodingPreferences.clamped()
        let autoWorkerCount = preferredConcurrentWorkerCount()

        // Preset baselines keep fast defaults safe for onboarding.
        var temperature: Float
        var topK: Int
        var fallbackCount: Int
        var compressionRatioThreshold: Float?
        var logProbThreshold: Float?
        var noSpeechThreshold: Float?

        switch prefs.preset {
        case .fast:
            temperature = 0.0
            topK = 3
            fallbackCount = 1
            compressionRatioThreshold = 2.4
            logProbThreshold = -1.0
            noSpeechThreshold = 0.65
        case .balanced:
            temperature = 0.0
            topK = 5
            fallbackCount = 3
            compressionRatioThreshold = 2.4
            logProbThreshold = -1.0
            noSpeechThreshold = 0.6
        case .accuracy:
            temperature = 0.2
            topK = 8
            fallbackCount = 5
            compressionRatioThreshold = 2.8
            logProbThreshold = -1.2
            noSpeechThreshold = 0.5
        }

        var workerCount = autoWorkerCount

        if prefs.expertOverridesEnabled {
            temperature = Float(prefs.temperature)
            topK = prefs.topK
            fallbackCount = prefs.fallbackCount
            compressionRatioThreshold = Float(prefs.compressionRatioThreshold)
            logProbThreshold = Float(prefs.logProbThreshold)
            noSpeechThreshold = Float(prefs.noSpeechThreshold)
            workerCount = prefs.workerCount == 0 ? autoWorkerCount : prefs.workerCount
        }

        return (
            temperature: temperature,
            topK: topK,
            fallbackCount: fallbackCount,
            compressionRatioThreshold: compressionRatioThreshold,
            logProbThreshold: logProbThreshold,
            noSpeechThreshold: noSpeechThreshold,
            workerCount: workerCount
        )
    }
}
