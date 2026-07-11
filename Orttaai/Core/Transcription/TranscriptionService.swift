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

    /// Live session state. Audio is committed as the recording progresses —
    /// in fixed 15s clips (matching the clip grid the final batch decode has
    /// always used) and early at speech pauses — so finalize only has to
    /// decode the short uncommitted tail no matter how long the dictation ran.
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
    /// Energy framing matches WhisperKit's EnergyVAD (100ms frames, 0.02 RMS).
    static let energyFrameSampleCount = transcriptionSampleRate / 10
    static let speechEnergyThreshold: Float = 0.02
    /// Below this RMS a frame is treated as dead silence (muted or absent
    /// mic), not merely quiet speech. Used where discarding audio must be safe.
    static let faintEnergyFloor: Float = 0.005
    /// Audio kept around detected speech when trimming or committing at pauses.
    static let silencePadSampleCount = transcriptionSampleRate * 3 / 10
    /// Trimming that saves less than this isn't worth the copy.
    private static let trimMinSavingsSampleCount = transcriptionSampleRate / 2
    /// A speech gap this long counts as a pause worth committing at.
    static let pauseCommitSilenceSampleCount = transcriptionSampleRate * 7 / 10
    /// Pause commits below this length risk hallucinated decodes; skip them.
    static let pauseCommitMinClipSampleCount = liveTranscriptionMinSampleCount

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
        // One commit in flight at a time; the ANE serializes work anyway.
        guard session.commitTask == nil else { return }
        guard audioSamples.count >= session.committedSampleCount else { return }

        // Commit finished 15s clips as soon as they exist so finalize only has
        // to decode the short tail, regardless of total recording length. A
        // due commit preempts tail speculation: the commit invalidates the
        // speculative base anyway, and waiting a poll cycle only grows the
        // tail left for finalize.
        let pendingSamples = audioSamples.count - session.committedSampleCount
        if pendingSamples >= Self.liveCommitClipSampleCount {
            session.speculativeTask?.cancel()
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

        // Commit early at speech pauses so short dictations also finalize with
        // a near-empty tail instead of re-decoding everything at stop.
        if let pauseClipSampleCount = Self.pauseCommitSampleCount(
            pendingAudio: audioSamples[session.committedSampleCount...]
        ) {
            session.speculativeTask?.cancel()
            let start = session.committedSampleCount
            let clipAudio = Array(audioSamples[start..<(start + pauseClipSampleCount)])
            let sessionID = session.id
            session.commitTask = Task { [weak self] in
                await self?.runLiveCommit(clipAudio: clipAudio, startSample: start, sessionID: sessionID)
            }
            liveSession = session
            return
        }

        // Otherwise speculatively decode the uncommitted tail, one decode in
        // flight at a time.
        guard session.speculativeTask == nil else { return }
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

        // An in-flight clip commit always advances the committed prefix, so
        // waiting for it is never wasted work.
        if let commitTask = liveSession?.commitTask {
            await commitTask.value
        }
        // An in-flight tail decode is worth waiting for when it covers the
        // final audio within slack — or when everything queued after it is
        // silence, which is the common case of the user stopping speech just
        // before releasing the hotkey. Otherwise cancel it to free the engine.
        if let inFlight = liveSession, let speculativeTask = inFlight.speculativeTask {
            if Self.speculativeCoverageIsSufficient(
                coveredSampleCount: inFlight.lastQueuedSampleCount,
                audioSamples: audioSamples
            ) {
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
        let tailAudio = Self.trimmedTailAudio(from: Array(audioSamples[base...]))

        var tailText: String?
        if let speculative = session.speculativeResult,
           speculative.base == base,
           Self.speculativeCoverageIsSufficient(
               coveredSampleCount: speculative.coveredSampleCount,
               audioSamples: audioSamples
           ) {
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

    /// Decodes a committed clip — one or more complete 15s clips, or a
    /// shorter pause-bounded clip — and folds it into the session's committed
    /// prefix. On failure the clip stays uncommitted so finalize re-decodes
    /// it; an empty (silent) clip commits as empty text.
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

        // The relaxed retry exists to recover quiet speech the thresholds
        // filtered out. Dead-silent audio has nothing to recover — skip the
        // second full decode.
        guard Self.containsSpeechEnergy(audioSamples[...], threshold: Self.faintEnergyFloor) else {
            Logger.transcription.info("Primary decode empty and audio is silent; skipping relaxed retry")
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

    /// Sample count from the start of the slice through the end of the last
    /// 100ms frame whose RMS energy reaches `threshold`, or nil if none does.
    /// Frames are aligned from the end of the slice so the trailing-silence
    /// scan exits as soon as it meets speech.
    nonisolated static func lastSpeechSampleIndex(
        in samples: ArraySlice<Float>,
        threshold: Float = speechEnergyThreshold
    ) -> Int? {
        guard !samples.isEmpty else { return nil }
        let start = samples.startIndex
        var frameEnd = samples.endIndex
        while frameEnd > start {
            let frameStart = max(start, frameEnd - energyFrameSampleCount)
            if frameRMS(samples[frameStart..<frameEnd]) >= threshold {
                return frameEnd - start
            }
            frameEnd = frameStart
        }
        return nil
    }

    /// Offset from the start of the slice to the beginning of the first 100ms
    /// frame whose RMS energy reaches `threshold`, or nil if none does.
    nonisolated static func firstSpeechSampleIndex(
        in samples: ArraySlice<Float>,
        threshold: Float = speechEnergyThreshold
    ) -> Int? {
        guard !samples.isEmpty else { return nil }
        let start = samples.startIndex
        var frameStart = start
        while frameStart < samples.endIndex {
            let frameEnd = min(samples.endIndex, frameStart + energyFrameSampleCount)
            if frameRMS(samples[frameStart..<frameEnd]) >= threshold {
                return frameStart - start
            }
            frameStart = frameEnd
        }
        return nil
    }

    nonisolated static func containsSpeechEnergy(
        _ samples: ArraySlice<Float>,
        threshold: Float = speechEnergyThreshold
    ) -> Bool {
        lastSpeechSampleIndex(in: samples, threshold: threshold) != nil
    }

    nonisolated private static func frameRMS(_ samples: ArraySlice<Float>) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Float = 0
        for sample in samples {
            sum += sample * sample
        }
        return (sum / Float(samples.count)).squareRoot()
    }

    /// A speculative tail result can stand in for the final decode when it
    /// covers the recording up to the reuse slack, or when everything recorded
    /// after it carries no voice-level energy (the user stopped speaking
    /// before releasing the hotkey).
    nonisolated static func speculativeCoverageIsSufficient(
        coveredSampleCount: Int,
        audioSamples: [Float]
    ) -> Bool {
        guard coveredSampleCount >= 0 else { return false }
        guard coveredSampleCount < audioSamples.count else { return true }
        let reuseThreshold = max(0, audioSamples.count - liveTranscriptionReuseSlackSampleCount)
        if coveredSampleCount >= reuseThreshold {
            return true
        }
        return !containsSpeechEnergy(audioSamples[coveredSampleCount...])
    }

    /// Trims dead silence from both ends of tail audio before the final
    /// decode. The boundary uses the faint-energy floor, not the VAD
    /// threshold, so quiet speech is never discarded. Returns the input
    /// unchanged when trimming would save under half a second, and an empty
    /// array when the audio is dead silent throughout (nothing to decode).
    nonisolated static func trimmedTailAudio(from samples: [Float]) -> [Float] {
        guard !samples.isEmpty else { return samples }
        guard let lastEnd = lastSpeechSampleIndex(in: samples[...], threshold: faintEnergyFloor) else {
            return []
        }
        let firstStart = firstSpeechSampleIndex(in: samples[...], threshold: faintEnergyFloor) ?? 0
        let start = max(0, firstStart - silencePadSampleCount)
        let end = min(samples.count, lastEnd + silencePadSampleCount)
        guard start < end else { return samples }
        guard start + (samples.count - end) >= trimMinSavingsSampleCount else { return samples }
        return Array(samples[start..<end])
    }

    /// Length of the pending-audio prefix to commit early because the speaker
    /// paused: the pending audio must contain speech, end in a sustained
    /// silence gap, and yield a clip long enough to decode reliably.
    nonisolated static func pauseCommitSampleCount(pendingAudio: ArraySlice<Float>) -> Int? {
        guard pendingAudio.count >= pauseCommitMinClipSampleCount + pauseCommitSilenceSampleCount else {
            return nil
        }
        guard let lastSpeechEnd = lastSpeechSampleIndex(in: pendingAudio) else { return nil }
        guard pendingAudio.count - lastSpeechEnd >= pauseCommitSilenceSampleCount else { return nil }
        let clipSampleCount = min(pendingAudio.count, lastSpeechEnd + silencePadSampleCount)
        guard clipSampleCount >= pauseCommitMinClipSampleCount else { return nil }
        return clipSampleCount
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
