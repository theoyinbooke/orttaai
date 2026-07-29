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
    func setLiveTranscriptEventHandler(_ handler: (@Sendable (LiveTranscriptEvent) -> Void)?)
    func setVocabularyBias(terms: [String])
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
        /// True when the most recent live decode tripped a quality fallback
        /// (temperature bump, compression-ratio or logprob threshold) or
        /// degenerated under conditioning. The next decode drops context
        /// conditioning so a bad prompt can never feed a hallucination loop.
        var lastDecodeTrippedFallback = false
    }

    private static let liveTranscriptionMinSampleCount = 16_000 * 2
    private static let liveTranscriptionIncrementSampleCount = 16_000
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
    /// Personal-dictionary targets and snippet triggers used to bias decoding.
    /// Snapshotted by the coordinator at session start — the database is never
    /// read on the audio hot path. Already normalized/deduped/capped on set.
    private var vocabularyBiasTerms: [String] = []
    /// Observer for in-progress transcript text (committed clips and
    /// speculative tails) so the UI can show a live transcript. Purely a
    /// side channel: it never influences finalization.
    private var liveTranscriptEventHandler: (@Sendable (LiveTranscriptEvent) -> Void)?

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
        let text = try await performTranscription(
            audioSamples: audioSamples,
            allowCancellation: false,
            promptTokens: wholeDecodePromptTokens(audioSamples: audioSamples)
        )
        Logger.transcription.info("Transcription complete: \(text.prefix(50))...")
        return text
    }

    func beginLiveTranscriptionSession() {
        cancelLiveTranscriptionSession()
        liveSession = LiveTranscriptionSession()
        liveTranscriptEventHandler?(.sessionBegan)
        Logger.transcription.debug("Live transcription session started")
    }

    func setLiveTranscriptEventHandler(_ handler: (@Sendable (LiveTranscriptEvent) -> Void)?) {
        liveTranscriptEventHandler = handler
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
            return try await performTranscription(
                audioSamples: audioSamples,
                allowCancellation: false,
                promptTokens: wholeDecodePromptTokens(audioSamples: audioSamples)
            )
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
            return try await performTranscription(
                audioSamples: audioSamples,
                allowCancellation: false,
                promptTokens: wholeDecodePromptTokens(audioSamples: audioSamples)
            )
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
                // Condition the tail decode on the committed session text and
                // bias vocabulary — but only when the tail actually carries
                // speech energy: conditioning a noise-only tail invites
                // prompt bleed-through.
                let tailPromptTokens = Self.containsSpeechEnergy(tailAudio[...])
                    ? currentLivePromptTokens(session: session)
                    : nil
                tailText = try await performTranscription(
                    audioSamples: tailAudio,
                    allowCancellation: false,
                    promptTokens: tailPromptTokens
                )
            } catch {
                // Do not fail the whole session here. The completeness check
                // below decides whether a committed prefix is safe to return
                // or whether the complete recording must be decoded again.
                Logger.transcription.debug("Tail decode produced no text: \(error.localizedDescription)")
            }
        }

        // A non-empty tail came from audio above the conservative faint-energy
        // floor. Returning only the committed prefix after that tail failed
        // would silently lose the end of the user's dictation.
        if !tailAudio.isEmpty, tailText == nil {
            Logger.transcription.info(
                "Background tail decode was unavailable; falling back to the complete recording"
            )
            return try await performWholeRecordingFallback(audioSamples)
        }

        if let combined = Self.mergedLiveTranscript(
            committedTexts: session.committedTexts,
            tailText: tailText
        ) {
            if let rejectionReason = Self.backgroundTranscriptRejectionReason(
                for: combined,
                audioSampleCount: audioSamples.count
            ) {
                Logger.transcription.info(
                    "Background transcript failed integrity check (\(rejectionReason)); falling back to the complete recording"
                )
                return try await performWholeRecordingFallback(audioSamples)
            }
            Logger.transcription.debug(
                "Finalized with \(session.committedTexts.count) committed clip(s) and \(tailAudio.count) tail samples"
            )
            return combined
        }

        // Nothing anywhere — fall back to a full decode (with its relaxed
        // retry) to preserve the previous behavior for quiet recordings.
        // Unconditioned: this path means the audio is likely near-silent, the
        // worst case for prompt bleed-through.
        return try await performTranscription(audioSamples: audioSamples, allowCancellation: false)
    }

    /// Authoritative recovery path when background decoding cannot prove a
    /// complete result. It uses the same whole-recording options and safe
    /// vocabulary-bias rules as a normal batch transcription.
    private func performWholeRecordingFallback(_ audioSamples: [Float]) async throws -> String {
        try await performTranscription(
            audioSamples: audioSamples,
            allowCancellation: false,
            promptTokens: wholeDecodePromptTokens(audioSamples: audioSamples)
        )
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

    /// Installs the vocabulary-bias term snapshot for subsequent decodes.
    /// Pass an empty array to disable biasing.
    func setVocabularyBias(terms: [String]) {
        vocabularyBiasTerms = Self.normalizedBiasTerms(terms)
    }

    // MARK: - Decode conditioning

    /// Token budget for the whole conditioning prompt. Kept under WhisperKit's
    /// own prompt cap (maxTokenContext / 2 - 1 = 111 in the pinned build,
    /// where maxTokenContext is 224) so WhisperKit never suffix-trims the
    /// prompt — a suffix trim would silently drop the bias terms, which sit
    /// at the front.
    nonisolated static let maxPromptTokenCount = 110
    /// Cap for the bias-vocabulary portion. Bias terms are fitted FIRST —
    /// they are the user's explicit vocabulary and must survive even when a
    /// long session supplies plenty of context text.
    // Prefill runs the decoder sequentially over every prompt token
    // (~35ms/token on cpuAndNeuralEngine, measured via gauntlet/asr_eval:
    // a ~130-token 36-term prompt added ~4.5s p50). 32 tokens bounds the
    // worst case near ~1.1s and covers ~8-10 typical dictionary terms;
    // vocabularyBiasTerms() orders by usage so an overflowing dictionary
    // keeps the names the user actually dictates.
    nonisolated static let maxBiasPromptTokenCount = 32
    /// Cap for the committed-session-text tail; it also never exceeds
    /// whatever the bias terms left of the total budget.
    nonisolated static let maxContextPromptTokenCount = 100
    nonisolated static let maxBiasTermCount = 40

    /// Trims, drops empties, dedupes case-insensitively (first spelling wins),
    /// orders longest-first (longer terms are the ones ASR mangles most and
    /// must survive the cap), and caps the term count.
    nonisolated static func normalizedBiasTerms(
        _ terms: [String],
        maxTerms: Int = maxBiasTermCount
    ) -> [String] {
        var seen = Set<String>()
        var unique: [String] = []
        for term in terms {
            let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let key = trimmed.lowercased()
            guard seen.insert(key).inserted else { continue }
            unique.append(trimmed)
        }
        unique.sort { lhs, rhs in
            if lhs.count != rhs.count { return lhs.count > rhs.count }
            return lhs.lowercased() < rhs.lowercased()
        }
        return Array(unique.prefix(maxTerms))
    }

    /// Builds the `promptTokens` for a conditioned decode: bias vocabulary
    /// first (as a comma-separated previous-context sentence), then the tail
    /// of the committed session text. Bias terms are fitted FIRST and whole —
    /// a term that would overflow the bias budget is dropped, never cut in
    /// half. The context tail takes whatever the bias terms left of the total
    /// budget, as a token suffix (most recent speech wins).
    /// `encode` is the tokenizer; ids >= `specialTokenBegin` are filtered so
    /// budget accounting matches what WhisperKit actually prefills.
    nonisolated static func conditioningPromptTokens(
        biasTerms: [String],
        contextText: String,
        encode: (String) -> [Int],
        specialTokenBegin: Int,
        maxTotalTokens: Int = maxPromptTokenCount,
        maxBiasTokens: Int = maxBiasPromptTokenCount,
        maxContextTokens: Int = maxContextPromptTokenCount
    ) -> [Int]? {
        func plainTokens(_ text: String) -> [Int] {
            encode(text).filter { $0 < specialTokenBegin }
        }

        var biasTokens: [Int] = []
        let biasBudget = min(maxBiasTokens, maxTotalTokens)
        var included: [String] = []
        for term in biasTerms {
            let candidate = (included + [term]).joined(separator: ", ") + "."
            let candidateTokens = plainTokens(" " + candidate)
            guard candidateTokens.count <= biasBudget else { continue }
            included.append(term)
            biasTokens = candidateTokens
        }

        let trimmedContext = contextText.trimmingCharacters(in: .whitespacesAndNewlines)
        let contextBudget = min(maxContextTokens, maxTotalTokens - biasTokens.count)
        let contextTokens: [Int] = (trimmedContext.isEmpty || contextBudget <= 0)
            ? []
            : Array(plainTokens(" " + trimmedContext).suffix(contextBudget))

        let prompt = biasTokens + contextTokens
        return prompt.isEmpty ? nil : prompt
    }

    /// Prompt for the next live decode, or nil when conditioning must be
    /// dropped (previous decode tripped a fallback — hallucination-loop
    /// protection) or there is nothing to condition on.
    nonisolated static func livePromptTokens(
        biasTerms: [String],
        committedTexts: [String],
        lastDecodeTrippedFallback: Bool,
        encode: (String) -> [Int],
        specialTokenBegin: Int
    ) -> [Int]? {
        guard !lastDecodeTrippedFallback else { return nil }
        return conditioningPromptTokens(
            biasTerms: biasTerms,
            contextText: committedTexts.joined(separator: mergedTranscriptSeparator),
            encode: encode,
            specialTokenBegin: specialTokenBegin
        )
    }

    /// True when any segment shows the decoder fell back or produced output
    /// past the quality thresholds: a bumped sampling temperature, a
    /// compression ratio above the configured threshold, or an average
    /// logprob below it.
    nonisolated static func decodeTrippedFallback(
        segments: [TranscriptionSegment],
        baseTemperature: Float,
        compressionRatioThreshold: Float?,
        logProbThreshold: Float?
    ) -> Bool {
        for segment in segments {
            if segment.temperature > baseTemperature + 0.01 { return true }
            if let threshold = compressionRatioThreshold, segment.compressionRatio > threshold {
                return true
            }
            if let threshold = logProbThreshold, segment.avgLogprob < threshold {
                return true
            }
        }
        return false
    }

    /// Detects degenerate n-gram loops (the classic conditioned-decode
    /// failure): a 1-gram repeated 5+ times consecutively, a 2-gram 4+
    /// times, or a 3/4-gram 3+ times. Deliberate speech like "no no no" or
    /// "very very very" stays below the thresholds.
    nonisolated static func hasDegenerateRepetition(in text: String) -> Bool {
        let words = text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        guard words.count >= 4 else { return false }

        let limits = [1: 5, 2: 4, 3: 3, 4: 3]
        for (n, limit) in limits {
            guard words.count >= n * limit else { continue }
            var start = 0
            while start + n <= words.count {
                let gram = Array(words[start..<start + n])
                var count = 1
                var next = start + n
                while next + n <= words.count, Array(words[next..<next + n]) == gram {
                    count += 1
                    next += n
                }
                if count >= limit { return true }
                start += 1
            }
        }
        return false
    }

    /// Decodes a committed clip — one or more complete 15s clips, or a
    /// shorter pause-bounded clip — and folds it into the session's committed
    /// prefix. On failure the clip stays uncommitted so finalize re-decodes
    /// it; an empty (silent) clip commits as empty text.
    private func runLiveCommit(clipAudio: [Float], startSample: Int, sessionID: UUID) async {
        let promptTokens: [Int]? = {
            guard let session = liveSession, session.id == sessionID,
                  Self.containsSpeechEnergy(clipAudio[...]) else { return nil }
            return currentLivePromptTokens(session: session)
        }()

        var committed: String?
        var trippedFallback = true // conservative: an errored decode drops conditioning next time
        do {
            let outcome = try await performClipTranscription(
                audioSamples: clipAudio,
                promptTokens: promptTokens
            )
            committed = outcome.text ?? ""
            trippedFallback = outcome.trippedFallback
        } catch {
            if !Task.isCancelled {
                Logger.transcription.debug("Live clip commit skipped: \(error.localizedDescription)")
            }
        }

        guard var session = liveSession, session.id == sessionID else { return }
        session.commitTask = nil
        session.lastDecodeTrippedFallback = trippedFallback
        if let committed, session.committedSampleCount == startSample {
            if !committed.isEmpty {
                session.committedTexts.append(committed)
            }
            session.committedSampleCount = startSample + clipAudio.count
            // Tail results decoded against the previous base now overlap
            // committed audio and must not be reused.
            session.speculativeResult = nil
            // Even an empty commit is reported: it invalidates the displayed
            // speculative tail for the audio it covers.
            liveTranscriptEventHandler?(.committed(committed))
        }
        liveSession = session
    }

    private func runLiveTranscription(
        tailAudio: [Float],
        base: Int,
        sessionID: UUID
    ) async {
        let promptTokens: [Int]? = {
            guard let session = liveSession, session.id == sessionID,
                  Self.containsSpeechEnergy(tailAudio[...]) else { return nil }
            return currentLivePromptTokens(session: session)
        }()

        var result: SpeculativeTailResult?
        var trippedFallback: Bool?
        do {
            let outcome = try await performTranscriptionDetailed(
                audioSamples: tailAudio,
                allowCancellation: true,
                promptTokens: promptTokens
            )
            if !Task.isCancelled {
                result = SpeculativeTailResult(
                    base: base,
                    coveredSampleCount: base + tailAudio.count,
                    text: outcome.text
                )
                trippedFallback = outcome.trippedFallback
            }
        } catch {
            // An empty speculative tail (silence) is not evidence of decode
            // trouble; leave the conditioning flag untouched.
            if !Task.isCancelled {
                Logger.transcription.debug("Speculative transcription skipped: \(error.localizedDescription)")
            }
        }

        guard var session = liveSession, session.id == sessionID else { return }
        session.speculativeTask = nil
        if let trippedFallback {
            session.lastDecodeTrippedFallback = trippedFallback
        }
        if let result,
           result.base == session.committedSampleCount,
           result.coveredSampleCount >= session.speculativeResult?.coveredSampleCount ?? 0 {
            session.speculativeResult = result
            liveTranscriptEventHandler?(.speculative(result.text))
        }
        liveSession = session
    }

    private struct ClipDecodeOutcome {
        /// nil when the audio decoded successfully but contained no speech.
        let text: String?
        let trippedFallback: Bool
    }

    private struct DecodeOutcome {
        let text: String
        let trippedFallback: Bool
    }

    /// Live decodes deliberately run without prompt tokens. The checked-in ASR
    /// corpus shows that applying the vocabulary prompt independently to live
    /// clips increases live WER from 4.36% to 6.60%, doubles median latency,
    /// and can hallucinate dictionary terms into unrelated speech. Whole,
    /// short-utterance decoding keeps the measured-safe bias path below.
    private func currentLivePromptTokens(session: LiveTranscriptionSession) -> [Int]? {
        _ = session
        return nil
    }

    /// Longest audio a bias prompt may condition: one Whisper window. On
    /// multi-window decodes the prompt is re-applied to every window, where
    /// the per-item ASR eval measured it compounding into temperature-fallback
    /// cascades: net +159 errors and +6-13s latency concentrated entirely in
    /// the long-* corpus items (gauntlet/asr_eval, bias-only run). Short
    /// decodes — every live clip, tail, and typical dictation — keep the
    /// recall win at negligible cost.
    static let biasPromptMaxSampleCount = 28 * transcriptionSampleRate

    /// Bias-vocabulary-only prompt for whole-utterance decodes. Skipped when
    /// there are no terms, the audio carries no speech energy at all
    /// (conditioning silent audio invites prompt bleed-through), or the audio
    /// spans more than one Whisper window (see biasPromptMaxSampleCount).
    private func wholeDecodePromptTokens(audioSamples: [Float]) -> [Int]? {
        guard !vocabularyBiasTerms.isEmpty,
              let tokenizer = whisperKit?.tokenizer,
              audioSamples.count <= Self.biasPromptMaxSampleCount,
              Self.containsSpeechEnergy(audioSamples[...]) else {
            return nil
        }
        return Self.conditioningPromptTokens(
            biasTerms: vocabularyBiasTerms,
            contextText: "",
            encode: { tokenizer.encode(text: $0) },
            specialTokenBegin: tokenizer.specialTokens.specialTokenBegin
        )
    }

    /// Decode used for committing live clips: same fixed clip grid as the
    /// final decode, cancellable, no relaxed retry.
    private func performClipTranscription(
        audioSamples: [Float],
        promptTokens: [Int]?
    ) async throws -> ClipDecodeOutcome {
        guard let wk = whisperKit else {
            throw OrttaaiError.modelNotLoaded
        }

        try Task.checkCancellation()
        let callback: TranscriptionCallback = { _ in
            Task.isCancelled ? false : nil
        }
        var options = Self.finalTranscriptionOptions(
            from: makeDecodingOptions(),
            sampleCount: audioSamples.count
        )
        options.promptTokens = promptTokens

        let results = try await wk.transcribe(
            audioArray: audioSamples,
            decodeOptions: options,
            callback: callback
        )

        try Task.checkCancellation()
        var text = Self.mergedTranscriptionText(from: results)
        var tripped = Self.decodeTrippedFallback(
            segments: results.flatMap(\.segments),
            baseTemperature: options.temperature,
            compressionRatioThreshold: options.compressionRatioThreshold,
            logProbThreshold: options.logProbThreshold
        )

        if promptTokens != nil, let conditioned = text, Self.hasDegenerateRepetition(in: conditioned) {
            Logger.transcription.info("Conditioned clip decode degenerated; retrying without conditioning")
            options.promptTokens = nil
            let retried = try await wk.transcribe(
                audioArray: audioSamples,
                decodeOptions: options,
                callback: callback
            )
            try Task.checkCancellation()
            text = Self.mergedTranscriptionText(from: retried)
            tripped = true
        }

        return ClipDecodeOutcome(text: text, trippedFallback: tripped)
    }

    private func performTranscription(
        audioSamples: [Float],
        allowCancellation: Bool,
        promptTokens: [Int]? = nil
    ) async throws -> String {
        try await performTranscriptionDetailed(
            audioSamples: audioSamples,
            allowCancellation: allowCancellation,
            promptTokens: promptTokens
        ).text
    }

    private func performTranscriptionDetailed(
        audioSamples: [Float],
        allowCancellation: Bool,
        promptTokens: [Int]?
    ) async throws -> DecodeOutcome {
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
        primaryOptions.promptTokens = promptTokens

        let results = try await wk.transcribe(
            audioArray: audioSamples,
            decodeOptions: primaryOptions,
            callback: callback
        )

        try Task.checkCancellation()
        var mergedText = Self.mergedTranscriptionText(from: results)
        var tripped = Self.decodeTrippedFallback(
            segments: results.flatMap(\.segments),
            baseTemperature: primaryOptions.temperature,
            compressionRatioThreshold: primaryOptions.compressionRatioThreshold,
            logProbThreshold: primaryOptions.logProbThreshold
        )

        // A conditioned decode that degenerates into an n-gram loop is
        // rejected outright; the same clip is re-decoded without conditioning.
        if promptTokens != nil, let conditioned = mergedText, Self.hasDegenerateRepetition(in: conditioned) {
            Logger.transcription.info("Conditioned decode degenerated; retrying without conditioning")
            var unconditioned = primaryOptions
            unconditioned.promptTokens = nil
            let retried = try await wk.transcribe(
                audioArray: audioSamples,
                decodeOptions: unconditioned,
                callback: callback
            )
            try Task.checkCancellation()
            mergedText = Self.mergedTranscriptionText(from: retried)
            tripped = true
        }

        if let text = mergedText {
            return DecodeOutcome(text: text, trippedFallback: tripped)
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
        return DecodeOutcome(text: retriedText, trippedFallback: true)
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
        // The relaxed retry is a recovery path — never conditioned: with the
        // quality thresholds off, a prompt could be freely hallucinated into
        // the output.
        relaxed.promptTokens = nil
        relaxed.prefixTokens = nil
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

    /// Conservative integrity gate for a transcript assembled from background
    /// clips. It catches the two observed corruption modes without attempting
    /// to score normal wording: degenerate decoder loops and implausibly tiny
    /// output for a long recording. Rejection triggers an authoritative
    /// whole-recording decode; it never discards the recording.
    nonisolated static func backgroundTranscriptRejectionReason(
        for text: String,
        audioSampleCount: Int
    ) -> String? {
        let normalized = normalizedTranscriptionText(text)
        guard !normalized.isEmpty else {
            return "transcript was empty after normalization"
        }
        if hasDegenerateRepetition(in: normalized) {
            return "transcript contained degenerate repetition"
        }

        let audioSeconds = Double(max(0, audioSampleCount)) / Double(transcriptionSampleRate)
        if audioSeconds >= 8, normalized.count < max(8, Int(audioSeconds.rounded(.down))) {
            return "transcript was implausibly short for the recording"
        }
        return nil
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

    /// A speculative tail result can stand in for the final decode only when
    /// it covers the complete recording or everything recorded after it is
    /// effectively silent. Never accept a time-based coverage slack: at normal
    /// speech rates even the final 250–500ms can contain several words.
    nonisolated static func speculativeCoverageIsSufficient(
        coveredSampleCount: Int,
        audioSamples: [Float]
    ) -> Bool {
        guard coveredSampleCount >= 0 else { return false }
        guard coveredSampleCount < audioSamples.count else { return true }
        return !containsSpeechEnergy(
            audioSamples[coveredSampleCount...],
            threshold: faintEnergyFloor
        )
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
