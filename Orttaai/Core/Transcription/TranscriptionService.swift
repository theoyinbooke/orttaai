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
    func beginLiveTranscriptionSession()
    func processLiveAudioSnapshot(_ audioSamples: [Float])
    func finalizeLiveTranscription(audioSamples: [Float]) async throws -> String
    func cancelLiveTranscriptionSession()
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
    private struct LiveTranscriptionResult: Sendable {
        let sampleCount: Int
        let text: String
    }

    private struct LiveTranscriptionSession {
        let id = UUID()
        var latestResult: LiveTranscriptionResult?
        var lastQueuedSampleCount: Int = 0
        var activeSampleCount: Int = 0
        var task: Task<LiveTranscriptionResult?, Never>?
    }

    private static let liveTranscriptionMinSampleCount = 16_000 * 2
    private static let liveTranscriptionIncrementSampleCount = 16_000
    private static let liveTranscriptionReuseSlackSampleCount = 16_000 / 2
    private static let transcriptionSampleRate = 16_000
    private static let mergedTranscriptSeparator = " "
    private static let liveTranscriptionReuseMaxAudioSeconds = 15.0

    private var whisperKit: WhisperKit?
    private var loadedModelIDValue: String?
    private var liveSession: LiveTranscriptionSession?

    /// Language code for transcription (e.g. "en", "es", "auto").
    /// Set from AppSettings.dictationLanguage before transcribing.
    var language: String = "en"

    /// Compute mode string from settings. Maps to MLComputeUnits.
    var computeModeSetting: String = "cpuAndNeuralEngine"
    var lowLatencyModeEnabled: Bool = false
    var decodingPreferences = DecodingPreferences(
        preset: .fast,
        expertOverridesEnabled: false,
        temperature: 0.0,
        topK: 5,
        fallbackCount: 3,
        compressionRatioThreshold: 2.4,
        logProbThreshold: -1.0,
        noSpeechThreshold: 0.6,
        workerCount: 0
    )

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
        Logger.transcription.info("Transcribing \(audioSamples.count) samples")
        let text = try await performTranscription(audioSamples: audioSamples, allowCancellation: false)
        Logger.transcription.info("Transcription complete: \(text.prefix(50))...")
        return text
    }

    func beginLiveTranscriptionSession() {
        cancelLiveTranscriptionSession()
        liveSession = LiveTranscriptionSession()
        Logger.transcription.debug("Live transcription session started")
    }

    func processLiveAudioSnapshot(_ audioSamples: [Float]) {
        guard whisperKit != nil else { return }
        guard var session = liveSession else { return }
        guard audioSamples.count >= Self.liveTranscriptionMinSampleCount else { return }
        guard session.task == nil else { return }
        guard audioSamples.count - session.lastQueuedSampleCount >= Self.liveTranscriptionIncrementSampleCount else { return }

        let sessionID = session.id
        session.lastQueuedSampleCount = audioSamples.count
        session.activeSampleCount = audioSamples.count
        session.task = Task { [weak self] in
            guard let self else { return nil }
            return await self.runLiveTranscription(audioSamples: audioSamples, sessionID: sessionID)
        }
        liveSession = session
    }

    func finalizeLiveTranscription(audioSamples: [Float]) async throws -> String {
        let finalSampleCount = audioSamples.count
        let reuseThreshold = max(0, finalSampleCount - Self.liveTranscriptionReuseSlackSampleCount)
        let speculativeReuseEligible = Self.isSpeculativeReuseEligible(finalSampleCount: finalSampleCount)

        if var session = liveSession {
            if speculativeReuseEligible, session.activeSampleCount >= reuseThreshold, let task = session.task {
                if let result = await task.value, result.sampleCount >= reuseThreshold {
                    if let rejectionReason = Self.speculativeReuseRejectionReason(
                        for: result.text,
                        finalSampleCount: finalSampleCount
                    ) {
                        Logger.transcription.debug("Skipping speculative transcription reuse: \(rejectionReason)")
                    } else {
                        liveSession = nil
                        Logger.transcription.debug("Using speculative transcription result at \(result.sampleCount) samples")
                        return result.text
                    }
                }
                session.task = nil
                session.activeSampleCount = 0
                liveSession = session
            } else if let task = session.task {
                task.cancel()
                session.task = nil
                session.activeSampleCount = 0
                liveSession = session
            }

            if speculativeReuseEligible,
               let latestResult = session.latestResult,
               latestResult.sampleCount >= reuseThreshold {
                if let rejectionReason = Self.speculativeReuseRejectionReason(
                    for: latestResult.text,
                    finalSampleCount: finalSampleCount
                ) {
                    Logger.transcription.debug("Skipping cached speculative transcript reuse: \(rejectionReason)")
                } else {
                    liveSession = nil
                    Logger.transcription.debug("Reusing cached speculative transcript at \(latestResult.sampleCount) samples")
                    return latestResult.text
                }
            }
        }

        defer { liveSession = nil }
        return try await performTranscription(audioSamples: audioSamples, allowCancellation: false)
    }

    func cancelLiveTranscriptionSession() {
        liveSession?.task?.cancel()
        liveSession = nil
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

    private func runLiveTranscription(
        audioSamples: [Float],
        sessionID: UUID
    ) async -> LiveTranscriptionResult? {
        let result: LiveTranscriptionResult?

        do {
            let text = try await performTranscription(audioSamples: audioSamples, allowCancellation: true)
            result = Task.isCancelled ? nil : LiveTranscriptionResult(sampleCount: audioSamples.count, text: text)
        } catch {
            if !Task.isCancelled {
                Logger.transcription.debug("Speculative transcription skipped: \(error.localizedDescription)")
            }
            result = nil
        }

        if var session = liveSession, session.id == sessionID {
            session.task = nil
            session.activeSampleCount = 0
            if let result, result.sampleCount >= session.latestResult?.sampleCount ?? 0 {
                session.latestResult = result
            }
            liveSession = session
        }

        return result
    }

    private func performTranscription(
        audioSamples: [Float],
        allowCancellation: Bool
    ) async throws -> String {
        guard let wk = whisperKit else {
            throw OrttaaiError.modelNotLoaded
        }

        try Task.checkCancellation()
        let callback: TranscriptionCallback = allowCancellation ? { _ in
            Task.isCancelled ? false : nil
        } : nil
        let primaryOptions = makeDecodingOptions()

        let results = try await wk.transcribe(
            audioArray: audioSamples,
            decodeOptions: primaryOptions,
            callback: callback
        )

        try Task.checkCancellation()
        if let text = Self.mergedTranscriptionText(from: results) {
            return text
        }

        guard !allowCancellation else {
            throw Self.noTranscriptionResultError()
        }

        let relaxedOptions = Self.relaxedDecodingOptions(from: primaryOptions)
        Logger.transcription.info("Primary decode returned empty transcript; retrying with relaxed thresholds")

        let retriedResults = try await wk.transcribe(
            audioArray: audioSamples,
            decodeOptions: relaxedOptions,
            callback: nil
        )

        try Task.checkCancellation()
        guard let retriedText = Self.mergedTranscriptionText(from: retriedResults) else {
            throw Self.noTranscriptionResultError()
        }
        return retriedText
    }

    private func makeDecodingOptions() -> DecodingOptions {
        let decodingLanguage: String? = (language == "auto") ? nil : language
        let resolvedDecoding = resolvedDecodingOptions()

        return DecodingOptions(
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
    }

    private func transcriptionText(from results: [TranscriptionResult]) throws -> String {
        guard let text = Self.mergedTranscriptionText(from: results) else {
            throw Self.noTranscriptionResultError()
        }
        return text
    }

    nonisolated static func relaxedDecodingOptions(from options: DecodingOptions) -> DecodingOptions {
        var relaxed = options
        relaxed.chunkingStrategy = ChunkingStrategy.none
        relaxed.noSpeechThreshold = nil
        relaxed.logProbThreshold = nil
        relaxed.compressionRatioThreshold = nil
        relaxed.firstTokenLogProbThreshold = nil
        relaxed.temperatureFallbackCount = max(options.temperatureFallbackCount, 3)
        relaxed.topK = max(options.topK, 5)
        return relaxed
    }

    nonisolated static func noTranscriptionResultError() -> OrttaaiError {
        OrttaaiError.transcriptionFailed(underlying: NSError(
            domain: "com.orttaai",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: "No transcription result"]
        ))
    }

    nonisolated static func mergedTranscriptionText(from results: [TranscriptionResult]) -> String? {
        let merged = results
            .map { normalizedTranscriptionText($0.text) }
            .filter { !$0.isEmpty }
            .joined(separator: mergedTranscriptSeparator)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return merged.isEmpty ? nil : merged
    }

    nonisolated static func normalizedTranscriptionText(_ text: String) -> String {
        text
            .replacingOccurrences(of: #"\[BLANK_AUDIO\]"#, with: " ", options: [.regularExpression, .caseInsensitive])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated static func isSpeculativeReuseEligible(finalSampleCount: Int) -> Bool {
        let audioSeconds = Double(finalSampleCount) / Double(transcriptionSampleRate)
        return audioSeconds <= liveTranscriptionReuseMaxAudioSeconds
    }

    nonisolated static func speculativeReuseRejectionReason(
        for text: String,
        finalSampleCount: Int
    ) -> String? {
        let normalized = normalizedTranscriptionText(text)
        guard !normalized.isEmpty else {
            return "transcript was empty after normalization"
        }

        guard isSpeculativeReuseEligible(finalSampleCount: finalSampleCount) else {
            let audioSeconds = Double(finalSampleCount) / Double(transcriptionSampleRate)
            return "audio too long for speculative reuse (\(Int(audioSeconds.rounded()))s)"
        }

        let audioSeconds = Double(finalSampleCount) / Double(transcriptionSampleRate)
        if audioSeconds >= 8, normalized.count < max(8, Int(audioSeconds.rounded(.down))) {
            return "transcript too short for audio length"
        }

        return nil
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
