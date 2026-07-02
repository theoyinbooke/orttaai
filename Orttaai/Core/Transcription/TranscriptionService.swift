// TranscriptionService.swift
// Orttaai

import Foundation
import CoreML
import WhisperKit
import os

protocol Transcribing: Actor {
    var isLoaded: Bool { get }
    func loadedModelID() -> String?
    func loadModel(named modelName: String) async throws
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
    private struct SpeculativeTailResult: Sendable {
        /// `committedSampleCount` at the time the tail decode started.
        let base: Int
        /// Absolute samples covered: base + tail length.
        let coveredSampleCount: Int
        let text: String
    }

    /// Live session state. Audio is committed in fixed 15s clips as the
    /// recording progresses (matching the clip grid the final batch decode has
    /// always used), so finalize only has to decode the short uncommitted tail
    /// no matter how long the dictation ran.
    private struct LiveTranscriptionSession {
        let id = UUID()
        var committedTexts: [String] = []
        var committedSampleCount: Int = 0
        var commitTask: Task<Void, Never>?
        var speculativeResult: SpeculativeTailResult?
        var lastQueuedSampleCount: Int = 0
        var speculativeTask: Task<Void, Never>?
    }

    private static let liveTranscriptionMinSampleCount = 16_000 * 2
    private static let liveTranscriptionIncrementSampleCount = 16_000
    private static let liveTranscriptionReuseSlackSampleCount = 16_000 / 2
    private static let transcriptionSampleRate = 16_000
    private static let mergedTranscriptSeparator = " "
    private static let liveTranscriptionReuseMaxAudioSeconds = 15.0
    private static let finalDecodeClipSeconds: Float = 15.0
    /// Live clips are committed on the same 15s grid the final decode uses.
    private static let liveCommitClipSampleCount = Int(finalDecodeClipSeconds) * transcriptionSampleRate

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
            voiceActivityDetector: EnergyVAD(),
            load: true
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
        // One decode in flight at a time; the ANE serializes work anyway.
        guard session.commitTask == nil, session.speculativeTask == nil else { return }
        guard audioSamples.count >= session.committedSampleCount else { return }

        // Commit finished 15s clips as soon as they exist so finalize only has
        // to decode the short tail, regardless of total recording length.
        let pendingSamples = audioSamples.count - session.committedSampleCount
        if pendingSamples >= Self.liveCommitClipSampleCount {
            let clipCount = pendingSamples / Self.liveCommitClipSampleCount
            let start = session.committedSampleCount
            let end = start + clipCount * Self.liveCommitClipSampleCount
            let clipAudio = Array(audioSamples[start..<end])
            let sessionID = session.id
            session.commitTask = Task { [weak self] in
                await self?.runLiveCommit(clipAudio: clipAudio, startSample: start, sessionID: sessionID)
            }
            liveSession = session
            return
        }

        // Otherwise speculatively decode the uncommitted tail.
        guard pendingSamples >= Self.liveTranscriptionMinSampleCount else { return }
        guard audioSamples.count - session.lastQueuedSampleCount >= Self.liveTranscriptionIncrementSampleCount else { return }

        let sessionID = session.id
        let base = session.committedSampleCount
        let tailAudio = Array(audioSamples[base...])
        session.lastQueuedSampleCount = audioSamples.count
        session.speculativeTask = Task { [weak self] in
            await self?.runLiveTranscription(tailAudio: tailAudio, base: base, sessionID: sessionID)
        }
        liveSession = session
    }

    func finalizeLiveTranscription(audioSamples: [Float]) async throws -> String {
        defer { liveSession = nil }

        guard liveSession != nil else {
            return try await performTranscription(audioSamples: audioSamples, allowCancellation: false)
        }

        let reuseThreshold = max(0, audioSamples.count - Self.liveTranscriptionReuseSlackSampleCount)

        // An in-flight clip commit always advances the committed prefix, so
        // waiting for it is never wasted work.
        if let commitTask = liveSession?.commitTask {
            await commitTask.value
        }
        // An in-flight tail decode is only worth waiting for if it covers the
        // final audio within slack; otherwise cancel it to free the engine.
        if let inFlight = liveSession, let speculativeTask = inFlight.speculativeTask {
            if inFlight.lastQueuedSampleCount >= reuseThreshold {
                await speculativeTask.value
            } else {
                speculativeTask.cancel()
            }
        }

        guard let session = liveSession else {
            // Session was cancelled while awaiting.
            return try await performTranscription(audioSamples: audioSamples, allowCancellation: false)
        }

        let base = min(session.committedSampleCount, audioSamples.count)
        let tailAudio = Array(audioSamples[base...])

        var tailText: String?
        if let speculative = session.speculativeResult,
           speculative.base == base,
           speculative.coveredSampleCount >= reuseThreshold {
            if let rejectionReason = Self.speculativeReuseRejectionReason(
                for: speculative.text,
                finalSampleCount: tailAudio.count
            ) {
                Logger.transcription.debug("Skipping speculative tail reuse: \(rejectionReason)")
            } else {
                Logger.transcription.debug("Reusing speculative tail covering \(speculative.coveredSampleCount) samples")
                tailText = speculative.text
            }
        }

        if tailText == nil, !tailAudio.isEmpty {
            do {
                tailText = try await performTranscription(audioSamples: tailAudio, allowCancellation: false)
            } catch {
                // The tail may legitimately be silence; committed clips can
                // still carry the transcript.
                Logger.transcription.debug("Tail decode produced no text: \(error.localizedDescription)")
            }
        }

        if let combined = Self.mergedLiveTranscript(
            committedTexts: session.committedTexts,
            tailText: tailText
        ) {
            Logger.transcription.debug(
                "Finalized with \(session.committedTexts.count) committed clip(s) and \(tailAudio.count) tail samples"
            )
            return combined
        }

        // Nothing anywhere — fall back to a full decode (with its relaxed
        // retry) to preserve the previous behavior for quiet recordings.
        return try await performTranscription(audioSamples: audioSamples, allowCancellation: false)
    }

    func cancelLiveTranscriptionSession() {
        liveSession?.commitTask?.cancel()
        liveSession?.speculativeTask?.cancel()
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

    /// Decodes one or more complete 15s clips and folds them into the
    /// session's committed prefix. On failure the clip stays uncommitted so
    /// finalize re-decodes it; an empty (silent) clip commits as empty text.
    private func runLiveCommit(clipAudio: [Float], startSample: Int, sessionID: UUID) async {
        var committed: String?
        do {
            committed = try await performClipTranscription(audioSamples: clipAudio) ?? ""
        } catch {
            if !Task.isCancelled {
                Logger.transcription.debug("Live clip commit skipped: \(error.localizedDescription)")
            }
        }

        guard var session = liveSession, session.id == sessionID else { return }
        session.commitTask = nil
        if let committed, session.committedSampleCount == startSample {
            if !committed.isEmpty {
                session.committedTexts.append(committed)
            }
            session.committedSampleCount = startSample + clipAudio.count
            // Tail results decoded against the previous base now overlap
            // committed audio and must not be reused.
            session.speculativeResult = nil
        }
        liveSession = session
    }

    private func runLiveTranscription(
        tailAudio: [Float],
        base: Int,
        sessionID: UUID
    ) async {
        var result: SpeculativeTailResult?
        do {
            let text = try await performTranscription(audioSamples: tailAudio, allowCancellation: true)
            if !Task.isCancelled {
                result = SpeculativeTailResult(
                    base: base,
                    coveredSampleCount: base + tailAudio.count,
                    text: text
                )
            }
        } catch {
            if !Task.isCancelled {
                Logger.transcription.debug("Speculative transcription skipped: \(error.localizedDescription)")
            }
        }

        guard var session = liveSession, session.id == sessionID else { return }
        session.speculativeTask = nil
        if let result,
           result.base == session.committedSampleCount,
           result.coveredSampleCount >= session.speculativeResult?.coveredSampleCount ?? 0 {
            session.speculativeResult = result
        }
        liveSession = session
    }

    /// Decode used for committing live clips: same fixed clip grid as the
    /// final decode, cancellable, no relaxed retry. Returns nil when the audio
    /// decoded successfully but contained no speech.
    private func performClipTranscription(audioSamples: [Float]) async throws -> String? {
        guard let wk = whisperKit else {
            throw OrttaaiError.modelNotLoaded
        }

        try Task.checkCancellation()
        let callback: TranscriptionCallback = { _ in
            Task.isCancelled ? false : nil
        }
        let options = Self.finalTranscriptionOptions(
            from: makeDecodingOptions(),
            sampleCount: audioSamples.count
        )

        let results = try await wk.transcribe(
            audioArray: audioSamples,
            decodeOptions: options,
            callback: callback
        )

        try Task.checkCancellation()
        return Self.mergedTranscriptionText(from: results)
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
        var primaryOptions = makeDecodingOptions()
        if !allowCancellation {
            primaryOptions = Self.finalTranscriptionOptions(
                from: primaryOptions,
                sampleCount: audioSamples.count
            )
        }

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

    nonisolated static func finalTranscriptionOptions(
        from options: DecodingOptions,
        sampleCount: Int
    ) -> DecodingOptions {
        var finalOptions = options
        finalOptions.chunkingStrategy = ChunkingStrategy.none
        finalOptions.clipTimestamps = fixedDecodeClipTimestamps(sampleCount: sampleCount)
        return finalOptions
    }

    nonisolated static func fixedDecodeClipTimestamps(
        sampleCount: Int,
        clipSeconds: Float = finalDecodeClipSeconds
    ) -> [Float] {
        guard sampleCount > 0, clipSeconds > 0 else { return [] }

        let audioSeconds = Float(sampleCount) / Float(transcriptionSampleRate)
        guard audioSeconds > clipSeconds else { return [] }

        var timestamps: [Float] = []
        var start: Float = 0
        while start < audioSeconds {
            let end = min(start + clipSeconds, audioSeconds)
            timestamps.append(start)
            timestamps.append(end)
            start = end
        }
        return timestamps
    }

    nonisolated static func noTranscriptionResultError() -> OrttaaiError {
        OrttaaiError.transcriptionFailed(underlying: NSError(
            domain: "com.orttaai",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: "No transcription result"]
        ))
    }

    nonisolated static func mergedLiveTranscript(
        committedTexts: [String],
        tailText: String?
    ) -> String? {
        let merged = (committedTexts + [tailText ?? ""])
            .map { normalizedTranscriptionText($0) }
            .filter { !$0.isEmpty }
            .joined(separator: mergedTranscriptSeparator)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return merged.isEmpty ? nil : merged
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
