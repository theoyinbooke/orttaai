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
    /// The sample a recording that has reached `capturedSampleCount` samples
    /// should be copied from for `processLiveAudio`, or nil when this poll
    /// needs no audio. Copying the whole recording on every poll costs
    /// memory: each copy is a little larger than the last, so macOS cannot
    /// reuse the freed ones, and a 10-minute dictation would leave about 2 GB
    /// to reclaim.
    func liveAudioSnapshotStart(capturedSampleCount: Int) -> Int?
    /// Live audio from sample `start` of the recording to its current end.
    func processLiveAudio(_ audio: [Float], startingAt start: Int)
    /// `processLiveAudio` with the whole recording so far.
    func processLiveAudioSnapshot(_ audioSamples: [Float])
    func finalizeLiveTranscription(audioSamples: [Float]) async throws -> String
    func cancelLiveTranscriptionSession()
    func setLiveTranscriptEventHandler(_ handler: (@Sendable (LiveTranscriptEvent) -> Void)?)
    func setVocabularyBias(terms: [String])
    /// Express's Word Boost vocabulary; an empty list turns boosting off.
    func setWordBoostVocabulary(_ terms: [WordBoostTerm]) async
    /// Express live segments: decode at the speaker's pauses while recording.
    /// Read when a live session begins.
    func setExpressLiveSegments(_ enabled: Bool)
    func updateSettings(
        language: String,
        computeMode: String,
        lowLatencyMode: Bool,
        decodingPreferences: DecodingPreferences
    )
}

extension Transcribing {
    /// Engines without Word Boost ignore the vocabulary.
    func setWordBoostVocabulary(_ terms: [WordBoostTerm]) async {}

    /// Engines other than Express decode the way they always do.
    func setExpressLiveSegments(_ enabled: Bool) {}

    func liveAudioSnapshotStart(capturedSampleCount: Int) -> Int? { 0 }

    func processLiveAudio(_ audio: [Float], startingAt start: Int) {
        guard start == 0 else { return }
        processLiveAudioSnapshot(audio)
    }
}

enum SetupModelLoadStage: Sendable {
    case downloading
    case loading
}

actor TranscriptionService: Transcribing {
    /// Creates the WhisperKit pipeline for a configuration. A seam so tests can
    /// observe loads without Core ML models.
    typealias WhisperKitFactory = @Sendable (WhisperKitConfig) async throws -> WhisperKit
    /// Loads the Express model package from its installed folder, with the
    /// Word Boost folder when that package is installed. A seam for the same
    /// reason.
    typealias ExpressBackendFactory = @Sendable (URL, URL?) async throws -> any ExpressBackend

    private struct InFlightLoad {
        let id: UUID
        let modelName: String
        let allowDownload: Bool
        let task: Task<Void, Error>
    }

    private struct SpeculativeTailResult: Sendable {
        /// `committedSampleCount` at the time the tail decode started.
        let base: Int
        /// Absolute samples covered: base + tail length.
        let coveredSampleCount: Int
        let text: String
    }

    /// Live session state. Audio is committed as the recording progresses —
    /// in clips of up to 15s, preferring nearby pauses, and early at speech
    /// pauses — so finalize only has to
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
        /// Express decodes this session in live segments (see
        /// `expressSegmentSampleCount`); fixed when the session begins.
        var expressSegments = false
        /// A segment failed to decode: finalize decodes the whole recording.
        var expressSegmentFailed = false
        /// Express segments stitched into `committedTexts`' single entry.
        var expressSegmentCount = 0
        /// Express's whole decode started when the speaker went quiet, and
        /// how much of the recording it covers.
        var expressEarlyDecode: (coveredSampleCount: Int, task: Task<String?, Never>)?
    }

    private static let liveTranscriptionMinSampleCount = 16_000 * 2
    private static let liveTranscriptionIncrementSampleCount = 16_000
    private static let transcriptionSampleRate = 16_000
    private static let mergedTranscriptSeparator = " "
    private static let liveTranscriptionReuseMaxAudioSeconds = 15.0
    private static let finalDecodeClipSeconds: Float = 15.0
    /// Maximum regular live clip length; shared with final decoding.
    private static let liveCommitClipSampleCount = Int(finalDecodeClipSeconds) * transcriptionSampleRate
    /// Search the final 3s of a clip for a 200ms gap with resumed speech,
    /// using the same conservative, noise-aware threshold as pause commits.
    private static let clipBoundarySearchSampleCount = 3 * transcriptionSampleRate
    private static let clipBoundaryGapSampleCount = transcriptionSampleRate / 5
    /// Keep the pause threshold below quiet speech while allowing normal
    /// variation around a measured room-noise floor. The ceiling is below
    /// half the VAD threshold, which is too high for quiet word endings.
    private static let maxPauseEnergyThreshold: Float = 0.009
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
    /// Express live segments are at least this long: Fluid Speech Mini reads
    /// best with context, and a recording shorter than this decodes whole in
    /// well under 100 ms anyway.
    static let expressSegmentMinSampleCount = transcriptionSampleRate * 8
    /// Uncommitted audio with no 0.7 s pause may still be cut at a shorter
    /// gap between words once it reaches this length.
    static let expressSegmentGapSearchSampleCount = transcriptionSampleRate * 20
    /// The live loop copies uncommitted audio only once a segment is possible.
    static let expressSegmentSnapshotSampleCount = expressSegmentMinSampleCount + pauseCommitSilenceSampleCount
    /// Audio before a segment, and after it, decoded with it: neighbouring
    /// decodes overlap by both, and are stitched there.
    static let expressSegmentContextSampleCount = transcriptionSampleRate * 3
    static let expressSegmentLookaheadSampleCount = transcriptionSampleRate * 2
    /// Words searched for a seam at each end of an overlap: 5 s of audio
    /// holds about 15 spoken words.
    static let expressStitchSearchWordCount = 30
    /// Express decodes the whole recording once the speaker has been quiet
    /// this long after speaking, so the decode is done, or under way, when
    /// the key comes up. In October 2026 this Mac's dictations ended with a
    /// median 1.3 s of silence before the key was released, at least 0.5 s
    /// in 234 of 239.
    static let expressEarlyDecodeSilenceSampleCount = transcriptionSampleRate / 2
    /// The latest audio searched for that pause.
    static let expressPauseProbeSampleCount = transcriptionSampleRate * 3
    /// Pause commits below this length risk hallucinated decodes; skip them.
    static let pauseCommitMinClipSampleCount = liveTranscriptionMinSampleCount
    /// WhisperKit only starts a decode window while more than `windowClipTime`
    /// (1s by default) of the clip remains, so any clip at or under that
    /// length silently decodes to nothing. Audio is padded past it, and
    /// trailing clip pieces are never allowed to end up shorter than it.
    static let minDecodableSampleCount = transcriptionSampleRate * 3 / 2

    private let modelLocator: ModelDirectoryLocator
    private let whisperKitFactory: WhisperKitFactory
    private let expressBackendFactory: ExpressBackendFactory
    /// Where versions before this one cached tokenizers, whatever root the
    /// model itself lived in. Only consulted as a fallback.
    private let legacyTokenizerBase: URL?
    private var whisperKit: WhisperKit?
    /// Set instead of `whisperKit` while `ExpressEngine.modelID` is loaded.
    /// Only one engine is resident at a time.
    private var expressBackend: (any ExpressBackend)?
    /// The latest Word Boost vocabulary, re-applied whenever Express loads.
    private var wordBoostTerms: [WordBoostTerm] = []
    /// Terms the loaded Express backend is boosting (0 without Word Boost).
    private(set) var wordBoostTermCount = 0
    private var expressLiveSegmentsEnabled = false
    /// The recording so far, for Express's whole decode: fed only what is new
    /// at each poll, so a decode can start as soon as the speaker pauses.
    private var expressRecording: [Float] = []
    private var loadedModelIDValue: String?
    /// The model load in progress. Concurrent requests for the same model
    /// (warm-up and the first finalization) share it instead of loading twice.
    private var inFlightLoad: InFlightLoad?
    /// Retains security-scoped access while a model on a user-selected drive
    /// is resident. Releasing it on unload balances the access grant.
    private var modelStorageAccess: ModelStorageAccess?
    private var liveSession: LiveTranscriptionSession?
    /// Personal-dictionary targets and snippet triggers used to bias decoding.
    /// Snapshotted by the coordinator at session start — the database is never
    /// read on the audio hot path. Already normalized/deduped/capped on set.
    private var vocabularyBiasTerms: [String] = []
    /// Observer for in-progress transcript text (committed clips and
    /// speculative tails) so the UI can show a live transcript. Purely a
    /// side channel: it never influences finalization.
    private var liveTranscriptEventHandler: (@Sendable (LiveTranscriptEvent) -> Void)?
    /// Receives the trace of every completed `finalizeLiveTranscription`.
    /// Unset by default (tests, the eval runner); the app installs a
    /// file-backed sink. Diagnostic only — it never influences finalization.
    private var finalizeTraceSink: (@Sendable (FinalizeTrace) -> Void)?

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

    init(
        modelLocator: ModelDirectoryLocator = .shared,
        whisperKitFactory: @escaping WhisperKitFactory = { try await WhisperKit($0) },
        expressBackendFactory: @escaping ExpressBackendFactory = TranscriptionService.loadExpressTranscriber,
        legacyTokenizerBase: URL? = ModelStorageLocation.defaultDownloadBaseURL()
    ) {
        self.modelLocator = modelLocator
        self.whisperKitFactory = whisperKitFactory
        self.expressBackendFactory = expressBackendFactory
        self.legacyTokenizerBase = legacyTokenizerBase
    }

    var isLoaded: Bool {
        whisperKit != nil || expressBackend != nil
    }

    func loadedModelID() -> String? {
        loadedModelIDValue
    }

    /// Loads a model that is already on this Mac. Never downloads.
    func loadModel(named modelName: String) async throws {
        try await loadModel(named: modelName, allowDownload: false)
    }

    /// `allowDownload` is for the flows where the user explicitly asked for
    /// the model to be fetched (download, setup). Warm-up and dictation leave
    /// it false so a missing model is reported instead of silently starting a
    /// multi-gigabyte download.
    func loadModel(named modelName: String, allowDownload: Bool) async throws {
        while let inFlight = inFlightLoad {
            guard inFlight.modelName == modelName else {
                _ = try? await inFlight.task.value
                continue
            }
            do {
                try await inFlight.task.value
                return
            } catch where allowDownload && !inFlight.allowDownload {
                // The load joined could not download; this caller may.
                continue
            }
        }

        let id = UUID()
        let task = Task {
            defer {
                if inFlightLoad?.id == id {
                    inFlightLoad = nil
                }
            }
            try await performLoad(named: modelName, allowDownload: allowDownload)
        }
        inFlightLoad = InFlightLoad(id: id, modelName: modelName, allowDownload: allowDownload, task: task)
        try await task.value
    }

    private func performLoad(named modelName: String, allowDownload: Bool) async throws {
        Logger.transcription.info("Loading model: \(modelName)")

        if modelName == ExpressEngine.modelID {
            try await performExpressLoad()
            return
        }

        let config: WhisperKitConfig
        let retainedAccess: ModelStorageAccess?
        var didDownload = false

        switch await modelLocator.lookup(variantID: modelName) {
        case .found(let existingFolder):
            let tokenizerFolder = try await tokenizerFolder(forModel: modelName, at: existingFolder)
            config = WhisperKitConfig(
                modelFolder: existingFolder.path,
                tokenizerFolder: tokenizerFolder,
                computeOptions: computeOptions(),
                voiceActivityDetector: EnergyVAD(),
                load: true,
                download: false
            )
            let readAccess = try? await modelLocator.beginAccess(createIfNeeded: false, requiresWrite: false)
            retainedAccess = readAccess.flatMap {
                ModelStorageLocation.contains(existingFolder, in: $0.url) ? $0 : nil
            }
            Logger.transcription.info("Loading existing model folder: \(existingFolder.path)")
        case .unavailable:
            throw ModelLoadError.storageUnavailable
        case .notFound:
            guard allowDownload else {
                throw ModelLoadError.modelFilesNotFound(modelID: modelName)
            }
            let writeAccess = try await modelLocator.beginAccess(createIfNeeded: true, requiresWrite: true)
            config = WhisperKitConfig(
                model: modelName,
                downloadBase: writeAccess.url,
                computeOptions: computeOptions(),
                voiceActivityDetector: EnergyVAD(),
                load: true
            )
            retainedAccess = writeAccess
            didDownload = true
            Logger.transcription.info("Downloading model into: \(writeAccess.url.path)")
        }

        let wk = try await whisperKitFactory(config)
        whisperKit = wk
        expressBackend = nil
        loadedModelIDValue = modelName
        modelStorageAccess = retainedAccess
        if didDownload {
            await modelLocator.invalidate()
        }

        Logger.transcription.info("Model loaded: \(modelName)")
    }

    /// Loads Fluid Speech Mini from the selected storage folder. Never
    /// downloads: ExpressModelStore installs it when the user turns Express on.
    private func performExpressLoad() async throws {
        guard ExpressEngine.isSupported else {
            throw ModelLoadError.modelFilesNotFound(modelID: ExpressEngine.modelID)
        }
        let access = try await modelLocator.beginAccess(createIfNeeded: false, requiresWrite: false)
        let storageBase = access.url
        guard let installed = await modelLocator.probe({ ExpressModelStore.isInstalled(in: storageBase) }) else {
            throw ModelLoadError.storageUnavailable
        }
        guard installed else {
            throw ModelLoadError.modelFilesNotFound(modelID: ExpressEngine.modelID)
        }
        let wordBoostInstalled = await modelLocator.probe({
            ExpressModelStore.isInstalled(ExpressModelStore.wordBoost, in: storageBase)
        }) ?? false

        let backend = try await expressBackendFactory(
            ExpressModelStore.folder(for: ExpressModelStore.speech, in: storageBase),
            wordBoostInstalled ? ExpressModelStore.folder(for: ExpressModelStore.wordBoost, in: storageBase) : nil
        )
        expressBackend = backend
        whisperKit = nil
        loadedModelIDValue = ExpressEngine.modelID
        modelStorageAccess = access
        wordBoostTermCount = await backend.setWordBoost(wordBoostTerms)
        Logger.transcription.info("Model loaded: \(ExpressEngine.modelID)")
    }

    @Sendable
    static func loadExpressTranscriber(from folder: URL, wordBoostFolder: URL?) async throws -> any ExpressBackend {
        guard #available(macOS 15, *) else {
            throw ModelLoadError.modelFilesNotFound(modelID: ExpressEngine.modelID)
        }
        return try await ExpressTranscriber.load(from: folder, wordBoostFolder: wordBoostFolder)
    }

    func setWordBoostVocabulary(_ terms: [WordBoostTerm]) async {
        wordBoostTerms = terms
        if let expressBackend {
            wordBoostTermCount = await expressBackend.setWordBoost(terms)
        }
    }

    /// The root WhisperKit should resolve the tokenizer from; see
    /// `ModelTokenizerLocation.resolveTokenizerBase`. Probed off the caller's
    /// thread with the same timeout as every other model-folder access.
    private func tokenizerFolder(forModel modelName: String, at modelFolder: URL) async throws -> URL {
        let legacyBase = legacyTokenizerBase
        let resolved = await modelLocator.probe {
            ModelTokenizerLocation.resolveTokenizerBase(
                modelID: modelName,
                modelFolder: modelFolder,
                legacyBase: legacyBase
            )
        }
        guard let resolved else {
            throw ModelLoadError.storageUnavailable
        }
        return resolved
    }

    func prepareModelForSetup(
        named modelName: String,
        onProgress: (@Sendable (Double) -> Void)? = nil,
        onStageChange: (@Sendable (SetupModelLoadStage) -> Void)? = nil
    ) async throws {
        Logger.transcription.info("Preparing model for setup with progress: \(modelName)")
        onStageChange?(.downloading)
        onProgress?(0)

        let storageAccess = try await modelLocator.beginAccess(createIfNeeded: true, requiresWrite: true)
        let modelFolder = try await WhisperKit.download(
            variant: modelName,
            downloadBase: storageAccess.url,
            progressCallback: { progress in
                let clamped = max(0, min(progress.fractionCompleted, 1))
                onProgress?(clamped)
            }
        )

        await modelLocator.invalidate()
        onProgress?(1)
        onStageChange?(.loading)

        let config = WhisperKitConfig(
            modelFolder: modelFolder.path,
            tokenizerFolder: storageAccess.url,
            computeOptions: computeOptions(),
            voiceActivityDetector: EnergyVAD(),
            load: true,
            download: false
        )

        let wk = try await whisperKitFactory(config)
        whisperKit = wk
        loadedModelIDValue = modelName
        modelStorageAccess = storageAccess
        Logger.transcription.info("Setup model prepared: \(modelName)")
    }

    func transcribe(audioSamples: [Float]) async throws -> String {
        Logger.transcription.info("Transcribing \(audioSamples.count) samples")
        if let expressBackend {
            return try await expressTranscript(audioSamples: audioSamples, backend: expressBackend)
        }
        let text = try await performTranscription(
            audioSamples: audioSamples,
            allowCancellation: false,
            promptTokens: wholeDecodePromptTokens(audioSamples: audioSamples)
        )
        try Self.rejectNonSpeechArtifact(text, audioSamples: audioSamples)
        Logger.transcription.info("Transcription complete: \(text.prefix(50))...")
        return text
    }

    func beginLiveTranscriptionSession() {
        cancelLiveTranscriptionSession()
        liveSession = LiveTranscriptionSession()
        expressRecording = []
        // Word Boost checks a whole recording more reliably than one segment
        // at a time (a dictionary word near a cut can be missed), so a
        // recording with dictionary words keeps the whole decode.
        liveSession?.expressSegments = expressBackend != nil && expressLiveSegmentsEnabled && wordBoostTermCount == 0
        liveTranscriptEventHandler?(.sessionBegan)
        Logger.transcription.debug("Live transcription session started")
    }

    func setLiveTranscriptEventHandler(_ handler: (@Sendable (LiveTranscriptEvent) -> Void)?) {
        liveTranscriptEventHandler = handler
    }

    func setFinalizeTraceSink(_ sink: (@Sendable (FinalizeTrace) -> Void)?) {
        finalizeTraceSink = sink
    }

    /// Whisper's live clips only read audio after the committed clips, so a
    /// poll copies at most one uncommitted clip, and nothing while a commit
    /// is in flight. Express's whole decode keeps its own copy of the
    /// recording, so each poll copies only what was recorded since the last.
    func liveAudioSnapshotStart(capturedSampleCount: Int) -> Int? {
        guard let session = liveSession else { return nil }
        if expressBackend != nil, !session.expressSegments {
            return capturedSampleCount > expressRecording.count ? expressRecording.count : nil
        }
        guard session.commitTask == nil else { return nil }
        if expressBackend != nil {
            guard !session.expressSegmentFailed,
                  capturedSampleCount - session.committedSampleCount
                    >= Self.expressSegmentSnapshotSampleCount + Self.expressSegmentLookaheadSampleCount
            else { return nil }
            return max(0, session.committedSampleCount - Self.expressSegmentContextSampleCount)
        }
        guard whisperKit != nil, capturedSampleCount > session.committedSampleCount else { return nil }
        return session.committedSampleCount
    }

    func processLiveAudioSnapshot(_ audioSamples: [Float]) {
        processLiveAudio(audioSamples, startingAt: 0)
    }

    func processLiveAudio(_ audio: [Float], startingAt start: Int) {
        if let expressBackend {
            if liveSession?.expressSegments == true {
                commitExpressSegment(audio, startingAt: start, backend: expressBackend)
                return
            }
            receiveExpressAudio(audio, startingAt: start, backend: expressBackend)
            return
        }
        guard whisperKit != nil else { return }
        guard var session = liveSession else { return }
        // One commit in flight at a time; the ANE serializes work anyway.
        guard session.commitTask == nil else { return }
        // A commit can land between choosing `start` and this call; the
        // audio before the committed point is never read.
        let recordedSampleCount = start + audio.count
        guard start <= session.committedSampleCount,
              recordedSampleCount >= session.committedSampleCount else { return }
        let pendingAudio = audio[(session.committedSampleCount - start)...]

        // Commit a finished clip as soon as it exists, choosing a nearby
        // pause when available so a word isn't cut at the 15s boundary. A
        // due commit preempts tail speculation: the commit invalidates the
        // speculative base anyway, and waiting a poll cycle only grows the
        // tail left for finalize.
        let pendingSamples = pendingAudio.count
        if pendingSamples >= Self.liveCommitClipSampleCount {
            session.speculativeTask?.cancel()
            let clipStart = session.committedSampleCount
            let clipAudio = Array(pendingAudio.prefix(Self.decodeClipSampleCount(pendingAudio: pendingAudio)))
            let sessionID = session.id
            session.commitTask = Task { [weak self] in
                await self?.runLiveCommit(clipAudio: clipAudio, startSample: clipStart, sessionID: sessionID)
            }
            liveSession = session
            return
        }

        // Commit early at speech pauses so short dictations also finalize with
        // a near-empty tail instead of re-decoding everything at stop.
        if let pauseClipSampleCount = Self.pauseCommitSampleCount(pendingAudio: pendingAudio) {
            session.speculativeTask?.cancel()
            let clipStart = session.committedSampleCount
            let clipAudio = Array(pendingAudio.prefix(pauseClipSampleCount))
            let sessionID = session.id
            session.commitTask = Task { [weak self] in
                await self?.runLiveCommit(clipAudio: clipAudio, startSample: clipStart, sessionID: sessionID)
            }
            liveSession = session
            return
        }

        // Otherwise speculatively decode the uncommitted tail, one decode in
        // flight at a time.
        guard session.speculativeTask == nil else { return }
        guard pendingSamples >= Self.liveTranscriptionMinSampleCount else { return }
        guard recordedSampleCount - session.lastQueuedSampleCount >= Self.liveTranscriptionIncrementSampleCount else { return }

        let sessionID = session.id
        let base = session.committedSampleCount
        let tailAudio = Array(pendingAudio)
        session.lastQueuedSampleCount = recordedSampleCount
        session.speculativeTask = Task { [weak self] in
            await self?.runLiveTranscription(tailAudio: tailAudio, base: base, sessionID: sessionID)
        }
        liveSession = session
    }

    func finalizeLiveTranscription(audioSamples: [Float]) async throws -> String {
        let (text, trace) = try await finalizeLiveTranscriptionDetailed(audioSamples: audioSamples)
        finalizeTraceSink?(trace)
        return text
    }

    /// `finalizeLiveTranscription` plus the trace of how it got there. The
    /// trace is observation only: it never influences the control flow.
    func finalizeLiveTranscriptionDetailed(
        audioSamples: [Float]
    ) async throws -> (text: String, trace: FinalizeTrace) {
        if let expressBackend {
            return try await finalizeExpress(audioSamples: audioSamples, backend: expressBackend)
        }
        let result = try await assembleLiveTranscript(audioSamples: audioSamples)
        try Self.rejectNonSpeechArtifact(result.text, audioSamples: audioSamples)
        return result
    }

    /// Adds what was recorded since the last poll to Express's copy of the
    /// recording, then scores any Word Boost chunk it completes and starts
    /// the whole decode if the speaker has paused.
    private func receiveExpressAudio(_ audio: [Float], startingAt start: Int, backend: any ExpressBackend) {
        let received = expressRecording.count
        guard liveSession != nil, start <= received, start + audio.count > received else { return }
        expressRecording.append(contentsOf: audio[(received - start)...])
        prepareExpressWordBoost(expressRecording, backend: backend)
        startExpressEarlyDecodeAtPause(backend: backend)
    }

    /// Starts the whole decode once the speaker has been quiet for half a
    /// second after new speech, while they're still holding the key. It
    /// stands in for the decode at key release when only silence follows it
    /// (`finalizeExpress`); if they speak again, the next pause starts
    /// another. Pauses are found as for Whisper's pause commits.
    private func startExpressEarlyDecodeAtPause(backend: any ExpressBackend) {
        guard var session = liveSession else { return }
        let recorded = expressRecording.count
        let probeStart = max(0, recorded - Self.expressPauseProbeSampleCount)
        let probe = expressRecording[probeStart...]
        guard Self.containsSpeechEnergy(probe),
              let speechEnd = Self.lastSpeechSampleIndex(in: probe, threshold: Self.pauseEnergyThreshold(in: probe)),
              recorded - (probeStart + speechEnd) >= Self.expressEarlyDecodeSilenceSampleCount,
              probeStart + speechEnd > session.expressEarlyDecode?.coveredSampleCount ?? 0
        else { return }
        let audio = expressRecording
        session.expressEarlyDecode = (recorded, Task {
            try? await backend.transcribe(audio, keepingPreparedScores: true)
        })
        liveSession = session
    }

    /// Word Boost scores each 15 s chunk as soon as the recording completes
    /// it, so a long recording leaves only its last chunk to score after key
    /// release. The session's committed sample count marks how far chunks
    /// were requested.
    private func prepareExpressWordBoost(_ audioSamples: [Float], backend: any ExpressBackend) {
        guard wordBoostTermCount > 0, var session = liveSession, session.commitTask == nil else { return }
        guard let completeEnd = WordBoostChunks.completeChunks(inPrefixOf: audioSamples.count).last?.upperBound,
              completeEnd > session.committedSampleCount else { return }
        session.committedSampleCount = completeEnd
        let sessionID = session.id
        session.commitTask = Task { [weak self] in
            await backend.prepareWordBoost(audioSamples)
            await self?.finishExpressPreparation(sessionID: sessionID)
        }
        liveSession = session
    }

    private func finishExpressPreparation(sessionID: UUID) {
        guard liveSession?.id == sessionID else { return }
        liveSession?.commitTask = nil
    }

    /// Decodes the uncommitted audio up to the speaker's pause in the
    /// background, one segment at a time. The pause is judged on audio at
    /// least 2 s old, and the segment is decoded together with the 3 s
    /// before it and the 2 s after it. Neighbouring decodes overlap there and
    /// are stitched where their words agree (`stitchedExpressText`), so the
    /// words around a cut come from a decode that heard them in context.
    /// Word Boost, when on, runs inside each decode.
    private func commitExpressSegment(_ audio: [Float], startingAt start: Int, backend: any ExpressBackend) {
        guard var session = liveSession, session.commitTask == nil, !session.expressSegmentFailed else { return }
        let committed = session.committedSampleCount
        let recordedSampleCount = start + audio.count
        guard start <= committed,
              recordedSampleCount - committed > Self.expressSegmentLookaheadSampleCount else { return }
        let decidedAudio = audio[(committed - start)..<(audio.count - Self.expressSegmentLookaheadSampleCount)]
        guard let segmentSampleCount = Self.expressSegmentSampleCount(pendingAudio: decidedAudio) else { return }

        let windowStart = max(start, committed - Self.expressSegmentContextSampleCount)
        let windowEnd = min(recordedSampleCount, committed + segmentSampleCount + Self.expressSegmentLookaheadSampleCount)
        let window = Array(audio[(windowStart - start)..<(windowEnd - start)])
        session.committedSampleCount += segmentSampleCount
        let sessionID = session.id
        session.commitTask = Task { [weak self] in
            let text = try? await backend.transcribe(window)
            await self?.finishExpressSegment(text, audio: window, sessionID: sessionID)
        }
        liveSession = session
    }

    private func finishExpressSegment(_ decoded: String?, audio: [Float], sessionID: UUID) {
        guard liveSession?.id == sessionID else { return }
        liveSession?.commitTask = nil
        // A segment is only cut after speech, so an empty or rejected decode,
        // or one that doesn't agree with the previous decode where they
        // overlap, means the segments can't be trusted for this recording.
        guard let decoded, case let text = Self.normalizedTranscriptionText(decoded), !text.isEmpty,
              (try? Self.rejectNonSpeechArtifact(text, audioSamples: audio)) != nil,
              let stitched = Self.stitchedExpressText(liveSession?.committedTexts.first, text) else {
            liveSession?.expressSegmentFailed = true
            return
        }
        liveSession?.committedTexts = [stitched]
        liveSession?.expressSegmentCount += 1
    }

    /// Joins the text so far to the decode of the next, overlapping window.
    /// The longest run of words both decoded in the overlap (at least two,
    /// ignoring case and punctuation) is the seam, split in its middle: the
    /// earlier decode supplies the words before it and the later one the
    /// words after, so each side's words near its own window edge, where
    /// context is thinnest, are dropped. Nil when the two don't agree
    /// anywhere in the overlap.
    nonisolated static func stitchedExpressText(_ earlier: String?, _ later: String) -> String? {
        guard let earlier, !earlier.isEmpty else { return later }
        let left = earlier.split(whereSeparator: \.isWhitespace).map(String.init)
        let right = later.split(whereSeparator: \.isWhitespace).map(String.init)
        func key(_ word: String) -> String { String(word.lowercased().filter { $0.isLetter || $0.isNumber }) }
        let leftOffset = max(0, left.count - expressStitchSearchWordCount)
        let leftKeys = left[leftOffset...].map(key)
        let rightKeys = right.prefix(expressStitchSearchWordCount).map(key)

        // Longest common run of words, by the usual one-row dynamic program;
        // on a tie, the run ending later in the earlier text.
        var best: (leftEnd: Int, rightEnd: Int, length: Int)?
        var runs = [Int](repeating: 0, count: rightKeys.count + 1)
        for i in 0..<leftKeys.count {
            var diagonal = 0
            for j in 0..<rightKeys.count {
                let above = runs[j + 1]
                runs[j + 1] = !leftKeys[i].isEmpty && leftKeys[i] == rightKeys[j] ? diagonal + 1 : 0
                diagonal = above
                if runs[j + 1] >= max(2, best?.length ?? 0) {
                    best = (leftOffset + i + 1, j + 1, runs[j + 1])
                }
            }
        }
        guard let best else { return nil }
        let half = best.length / 2
        let leftCut = best.leftEnd - best.length + half
        let rightCut = best.rightEnd - best.length + half
        return (left[..<leftCut] + right[rightCut...]).joined(separator: " ")
    }

    /// Express has no live clips: the whole recording is decoded once, which
    /// costs less than WhisperKit's tail decode alone. When the speaker went
    /// quiet before letting go, that decode already started then.
    private func finalizeExpress(
        audioSamples: [Float],
        backend: any ExpressBackend
    ) async throws -> (text: String, trace: FinalizeTrace) {
        defer {
            liveSession = nil
            expressRecording = []
        }
        let clock = ContinuousClock()
        let started = clock.now
        // Chunks still being scored, or a segment still decoding, are part
        // of this decode's work.
        await liveSession?.commitTask?.value
        var trace = FinalizeTrace(
            totalAudioSeconds: Double(audioSamples.count) / Double(Self.transcriptionSampleRate)
        )
        trace.msAwaitingCommit = Self.milliseconds(since: started, on: clock)
        trace.path = .expressWholeDecode
        if let session = liveSession, session.expressSegments {
            if let text = try await expressSegmentsTranscript(
                session: session, audioSamples: audioSamples, backend: backend, trace: &trace, clock: clock
            ) {
                trace.path = .expressSegments
                trace.msTotal = Self.milliseconds(since: started, on: clock)
                return (text, trace)
            }
            trace.path = session.committedTexts.isEmpty && !session.expressSegmentFailed
                ? .expressWholeDecode
                : .expressSegmentFallback
        }
        // The decode started at the speaker's last pause is this one, when
        // nothing but silence followed it.
        if let early = liveSession?.expressEarlyDecode,
           Self.speculativeCoverageIsSufficient(coveredSampleCount: early.coveredSampleCount, audioSamples: audioSamples) {
            let awaitStarted = clock.now
            let decoded = await early.task.value
            trace.msAwaitingSpeculative = Self.milliseconds(since: awaitStarted, on: clock)
            if let decoded,
               case let text = Self.normalizedTranscriptionText(ExpressNumberFormatter.format(decoded)), !text.isEmpty,
               (try? Self.rejectNonSpeechArtifact(text, audioSamples: audioSamples)) != nil {
                await backend.discardPreparedWordBoost()
                trace.path = .expressEarlyDecode
                trace.msTotal = Self.milliseconds(since: started, on: clock)
                return (text, trace)
            }
        }
        let decodeStarted = clock.now
        let text = try await expressTranscript(audioSamples: audioSamples, backend: backend)
        trace.msFallbackDecode = Self.milliseconds(since: decodeStarted, on: clock)
        trace.msTotal = Self.milliseconds(since: started, on: clock)
        return (text, trace)
    }

    /// The committed segments plus the audio after the last one, or nil when
    /// the whole recording should be decoded instead: nothing was committed,
    /// a segment failed, or the tail holds speech that didn't decode.
    private func expressSegmentsTranscript(
        session: LiveTranscriptionSession,
        audioSamples: [Float],
        backend: any ExpressBackend,
        trace: inout FinalizeTrace,
        clock: ContinuousClock
    ) async throws -> String? {
        guard !session.expressSegmentFailed, var text = session.committedTexts.first,
              session.committedSampleCount <= audioSamples.count else { return nil }
        let committed = session.committedSampleCount
        let tail = audioSamples[committed...]
        trace.committedClipCount = session.expressSegmentCount
        trace.tailSampleCount = tail.count
        if Self.containsSpeechEnergy(tail, threshold: Self.faintEnergyFloor) {
            let tailStarted = clock.now
            let windowStart = max(0, committed - Self.expressSegmentContextSampleCount)
            let decoded = (try? await backend.transcribe(Array(audioSamples[windowStart...])))
                .map(Self.normalizedTranscriptionText) ?? ""
            trace.msTailDecode = Self.milliseconds(since: tailStarted, on: clock)
            if decoded.isEmpty {
                // A faint tail (breath, room noise) may rightly decode to
                // nothing; real speech that didn't decode may not.
                guard !Self.containsSpeechEnergy(tail) else { return nil }
            } else {
                guard let stitched = Self.stitchedExpressText(text, decoded) else { return nil }
                text = stitched
            }
        }
        text = Self.normalizedTranscriptionText(ExpressNumberFormatter.format(text))
        guard (try? Self.rejectNonSpeechArtifact(text, audioSamples: audioSamples)) != nil else { return nil }
        return text
    }

    /// Same contract as a WhisperKit decode: nothing decoded throws the
    /// standard no-result error, and non-speech artifacts are rejected.
    private func expressTranscript(audioSamples: [Float], backend: any ExpressBackend) async throws -> String {
        let text = Self.normalizedTranscriptionText(ExpressNumberFormatter.format(try await backend.transcribe(audioSamples)))
        guard !text.isEmpty else {
            throw Self.noTranscriptionResultError()
        }
        try Self.rejectNonSpeechArtifact(text, audioSamples: audioSamples)
        return text
    }

    private func assembleLiveTranscript(
        audioSamples: [Float]
    ) async throws -> (text: String, trace: FinalizeTrace) {
        defer { liveSession = nil }

        let clock = ContinuousClock()
        let started = clock.now
        var trace = FinalizeTrace(
            totalAudioSeconds: Double(audioSamples.count) / Double(Self.transcriptionSampleRate)
        )

        guard liveSession != nil else {
            trace.path = .noLiveSession
            let decodeStarted = clock.now
            let text = try await performTranscription(
                audioSamples: audioSamples,
                allowCancellation: false,
                promptTokens: wholeDecodePromptTokens(audioSamples: audioSamples)
            )
            trace.msFallbackDecode = Self.milliseconds(since: decodeStarted, on: clock)
            trace.msTotal = Self.milliseconds(since: started, on: clock)
            return (text, trace)
        }

        // An in-flight clip commit always advances the committed prefix, so
        // waiting for it is never wasted work.
        if let commitTask = liveSession?.commitTask {
            let awaitStarted = clock.now
            await commitTask.value
            trace.msAwaitingCommit = Self.milliseconds(since: awaitStarted, on: clock)
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
                let awaitStarted = clock.now
                await speculativeTask.value
                trace.msAwaitingSpeculative = Self.milliseconds(since: awaitStarted, on: clock)
            } else {
                speculativeTask.cancel()
                trace.speculativeCancelled = true
            }
        }

        guard let session = liveSession else {
            // Session was cancelled while awaiting.
            trace.path = .noLiveSession
            let decodeStarted = clock.now
            let text = try await performTranscription(
                audioSamples: audioSamples,
                allowCancellation: false,
                promptTokens: wholeDecodePromptTokens(audioSamples: audioSamples)
            )
            trace.msFallbackDecode = Self.milliseconds(since: decodeStarted, on: clock)
            trace.msTotal = Self.milliseconds(since: started, on: clock)
            return (text, trace)
        }

        let base = min(session.committedSampleCount, audioSamples.count)
        let tailAudio = Self.trimmedTailAudio(from: Array(audioSamples[base...]))
        let tailStatistics = Self.frameRMSStatistics(of: tailAudio)
        trace.tailSampleCount = tailAudio.count
        trace.tailPeakFrameRMS = tailStatistics.peak
        trace.tailMedianFrameRMS = tailStatistics.median
        trace.committedClipCount = session.committedTexts.count

        // A tail with no speech-level energy behind a committed prefix has
        // nothing worth a second, threshold-free decode: at best it recovers
        // nothing, at worst it hallucinates a stock phrase or spends seconds
        // re-decoding noise.
        let tailIsDroppable = Self.tailCanBeDropped(
            tailPeakFrameRMS: tailStatistics.peak,
            hasCommittedText: !session.committedTexts.isEmpty
        )

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
                trace.path = .reusedSpeculative
                if tailIsDroppable, Self.isStockHallucination(speculative.text) {
                    Logger.transcription.info("Dropping stock-phrase hallucination from a non-speech tail")
                    tailText = ""
                    trace.path = .tailEmptyAccepted
                }
            }
        }

        if tailText == nil, !tailAudio.isEmpty {
            let decodeStarted = clock.now
            let relaxedRetryProbe = RelaxedRetryProbe()
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
                    promptTokens: tailPromptTokens,
                    allowRelaxedRetry: !tailIsDroppable,
                    relaxedRetryProbe: relaxedRetryProbe
                )
                trace.path = .tailDecoded
                if tailIsDroppable, Self.isStockHallucination(tailText ?? "") {
                    Logger.transcription.info("Dropping stock-phrase hallucination from a non-speech tail")
                    tailText = ""
                    trace.path = .tailEmptyAccepted
                }
            } catch {
                // Do not fail the whole session here. The completeness check
                // below decides whether a committed prefix is safe to return
                // or whether the complete recording must be decoded again.
                Logger.transcription.debug("Tail decode produced no text: \(error.localizedDescription)")
            }
            trace.msTailDecode = Self.milliseconds(since: decodeStarted, on: clock)
            trace.relaxedRetryRan = relaxedRetryProbe.didRun
        }

        // A non-empty tail came from audio above the conservative faint-energy
        // floor. Returning only the committed prefix after that tail failed
        // would silently lose the end of the user's dictation.
        if !tailAudio.isEmpty, tailText == nil, tailIsDroppable {
            Logger.transcription.info("Tail carried no speech energy and decoded to nothing; keeping the committed prefix")
            tailText = ""
            trace.path = .tailEmptyAccepted
        }

        if !tailAudio.isEmpty, tailText == nil {
            Logger.transcription.info(
                "Background tail decode was unavailable; falling back to the complete recording"
            )
            trace.path = .wholeFallback(.tailNoResult)
            let decodeStarted = clock.now
            let text = try await performWholeRecordingFallback(audioSamples)
            trace.msFallbackDecode = Self.milliseconds(since: decodeStarted, on: clock)
            trace.msTotal = Self.milliseconds(since: started, on: clock)
            return (text, trace)
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
                trace.path = .wholeFallback(.integrityRejected(rejectionReason))
                let decodeStarted = clock.now
                let text = try await performWholeRecordingFallback(audioSamples)
                trace.msFallbackDecode = Self.milliseconds(since: decodeStarted, on: clock)
                trace.msTotal = Self.milliseconds(since: started, on: clock)
                return (text, trace)
            }
            Logger.transcription.debug(
                "Finalized with \(session.committedTexts.count) committed clip(s) and \(tailAudio.count) tail samples"
            )
            if tailText == nil {
                trace.path = .tailEmptyNoAudio
            }
            trace.msTotal = Self.milliseconds(since: started, on: clock)
            return (combined, trace)
        }

        // Nothing anywhere — fall back to a full decode (with its relaxed
        // retry) to preserve the previous behavior for quiet recordings.
        // Unconditioned: this path means the audio is likely near-silent, the
        // worst case for prompt bleed-through.
        trace.path = .wholeFallback(.nothingCommitted)
        let decodeStarted = clock.now
        let text = try await performTranscription(audioSamples: audioSamples, allowCancellation: false)
        trace.msFallbackDecode = Self.milliseconds(since: decodeStarted, on: clock)
        trace.msTotal = Self.milliseconds(since: started, on: clock)
        return (text, trace)
    }

    nonisolated private static func milliseconds(
        since start: ContinuousClock.Instant,
        on clock: ContinuousClock
    ) -> Int {
        let elapsed = start.duration(to: clock.now)
        return Int(elapsed.components.seconds) * 1000
            + Int(elapsed.components.attoseconds / 1_000_000_000_000_000)
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
        liveSession?.expressEarlyDecode?.task.cancel()
        if liveSession != nil, let expressBackend {
            Task { await expressBackend.discardPreparedWordBoost() }
        }
        liveSession = nil
        expressRecording = []
    }

    func unloadModel() {
        whisperKit = nil
        expressBackend = nil
        wordBoostTermCount = 0
        loadedModelIDValue = nil
        modelStorageAccess = nil
        Logger.transcription.info("Model unloaded")
    }

    func warmUp() async {
        guard whisperKit != nil || expressBackend != nil else { return }

        // Two seconds, not one: WhisperKit skips any clip at or under its 1s
        // window padding, so a 1s buffer never reached the encoder or decoder
        // and the first real dictation paid the Core ML cold-start cost.
        Logger.transcription.info("Warming up model with 2s silence")
        let silentSamples = [Float](repeating: 0, count: 2 * Self.transcriptionSampleRate)

        do {
            _ = try await transcribe(audioSamples: silentSamples)
        } catch {
            // Warm-up transcription of silence may produce empty results — that's fine
            Logger.transcription.info("Warm-up complete (result may be empty, that's expected)")
        }
    }

    func setExpressLiveSegments(_ enabled: Bool) {
        expressLiveSegmentsEnabled = enabled
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

    /// Decodes a committed clip — a pause-aligned clip of up to 15s, or a
    /// shorter pause-bounded clip — and folds it into the session's committed
    /// prefix. On failure the clip stays uncommitted so finalize re-decodes
    /// it; only an empty, effectively silent clip commits as empty text.
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
            committed = Self.liveCommitText(decodedText: outcome.text, audioSamples: clipAudio)
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

    /// An empty decode is not proof of silence. Advancing over undecoded
    /// speech would permanently lose words from the committed prefix.
    nonisolated static func liveCommitText(decodedText: String?, audioSamples: [Float]) -> String? {
        if let decodedText {
            let normalized = normalizedTranscriptionText(decodedText)
            if !normalized.isEmpty { return normalized }
        }
        return containsSpeechEnergy(audioSamples[...], threshold: faintEnergyFloor) ? nil : ""
    }

    private struct DecodeOutcome {
        let text: String
        let trippedFallback: Bool
    }

    /// Reports whether a decode reached its relaxed-threshold retry. A probe
    /// rather than a `DecodeOutcome` field because the retry that matters for
    /// diagnosis is the one that still comes back empty, which throws.
    private final class RelaxedRetryProbe {
        var didRun = false
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

    /// Decode used for committing live clips: same pause-aligned clipping as the
    /// final decode, cancellable, no relaxed retry.
    private func performClipTranscription(
        audioSamples: [Float],
        promptTokens: [Int]?
    ) async throws -> ClipDecodeOutcome {
        guard let wk = whisperKit else {
            throw OrttaaiError.modelNotLoaded
        }

        let audioSamples = Self.paddedForDecode(audioSamples)
        try Task.checkCancellation()
        let callback: TranscriptionCallback = { _ in
            Task.isCancelled ? false : nil
        }
        var options = Self.finalTranscriptionOptions(
            from: makeDecodingOptions(),
            audioSamples: audioSamples
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
        promptTokens: [Int]? = nil,
        allowRelaxedRetry: Bool = true,
        relaxedRetryProbe: RelaxedRetryProbe? = nil
    ) async throws -> String {
        try await performTranscriptionDetailed(
            audioSamples: audioSamples,
            allowCancellation: allowCancellation,
            promptTokens: promptTokens,
            allowRelaxedRetry: allowRelaxedRetry,
            relaxedRetryProbe: relaxedRetryProbe
        ).text
    }

    private func performTranscriptionDetailed(
        audioSamples: [Float],
        allowCancellation: Bool,
        promptTokens: [Int]?,
        allowRelaxedRetry: Bool = true,
        relaxedRetryProbe: RelaxedRetryProbe? = nil
    ) async throws -> DecodeOutcome {
        guard let wk = whisperKit else {
            throw OrttaaiError.modelNotLoaded
        }

        let audioSamples = Self.paddedForDecode(audioSamples)
        try Task.checkCancellation()
        let callback: TranscriptionCallback = allowCancellation ? { _ in
            Task.isCancelled ? false : nil
        } : nil
        var primaryOptions = makeDecodingOptions()
        if !allowCancellation {
            primaryOptions = Self.finalTranscriptionOptions(
                from: primaryOptions,
                audioSamples: audioSamples
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

        guard !allowCancellation, allowRelaxedRetry else {
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
        relaxedRetryProbe?.didRun = true

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

    func makeDecodingOptions() -> DecodingOptions {
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
        audioSamples: [Float]
    ) -> DecodingOptions {
        var finalOptions = options
        finalOptions.chunkingStrategy = ChunkingStrategy.none
        finalOptions.clipTimestamps = decodeClipTimestamps(audioSamples: audioSamples)
        return finalOptions
    }

    /// Prefer the latest 200ms quiet gap near the nominal clip end. Split in
    /// its middle, leaving acoustic padding on both sides. Continuous speech
    /// retains the existing bounded 15s behavior; no overlapping audio or text
    /// deduplication is needed.
    nonisolated static func decodeClipSampleCount(pendingAudio: ArraySlice<Float>) -> Int {
        let limit = min(pendingAudio.count, liveCommitClipSampleCount)
        guard pendingAudio.count >= liveCommitClipSampleCount else {
            return limit
        }
        let searchStart = pendingAudio.startIndex + limit - clipBoundarySearchSampleCount
        let searchEnd = pendingAudio.startIndex + limit
        let pauseThreshold = pauseEnergyThreshold(in: pendingAudio.prefix(limit))
        var quietSamples = 0
        var boundary = limit
        var frameStart = searchStart
        while frameStart + energyFrameSampleCount <= searchEnd {
            let frameEnd = frameStart + energyFrameSampleCount
            if frameRMS(pendingAudio[frameStart..<frameEnd]) < pauseThreshold {
                quietSamples += energyFrameSampleCount
            } else {
                // Require speech to resume after the gap. A trailing quiet
                // run might be a soft word still being spoken at the clip
                // edge, so it cannot establish a safer cut than the grid.
                if quietSamples >= clipBoundaryGapSampleCount {
                    boundary = frameStart - pendingAudio.startIndex - clipBoundaryGapSampleCount / 2
                }
                quietSamples = 0
            }
            frameStart = frameEnd
        }
        return boundary
    }

    nonisolated static func decodeClipTimestamps(audioSamples: [Float]) -> [Float] {
        guard audioSamples.count > liveCommitClipSampleCount else { return [] }

        // A trailing piece shorter than WhisperKit's window padding would be
        // skipped outright and its words lost; fold it into the previous clip.
        var timestamps: [Float] = []
        var start = 0
        while start < audioSamples.count {
            var end = start + decodeClipSampleCount(pendingAudio: audioSamples[start...])
            if audioSamples.count - end < minDecodableSampleCount {
                end = audioSamples.count
            }
            timestamps.append(Float(start) / Float(transcriptionSampleRate))
            timestamps.append(Float(end) / Float(transcriptionSampleRate))
            start = end
        }
        return timestamps
    }

    /// Appends dead silence so audio is long enough for WhisperKit to decode
    /// at all (see `minDecodableSampleCount`). Longer audio is returned as is.
    nonisolated static func paddedForDecode(_ samples: [Float]) -> [Float] {
        guard !samples.isEmpty, samples.count < minDecodableSampleCount else { return samples }
        return samples + [Float](repeating: 0, count: minDecodableSampleCount - samples.count)
    }

    /// Stock phrases Whisper emits on non-speech audio. Closed and tiny on
    /// purpose: it is only ever consulted for audio with no speech-level
    /// energy, where a genuinely spoken "thank you" is not expected.
    private static let stockHallucinationPhrases: Set<String> = [
        "you", "thank you", "thanks", "bye", "bye bye",
        "thanks for watching", "thank you for watching",
    ]

    nonisolated static func isStockHallucination(_ text: String) -> Bool {
        let words = text.lowercased()
            .components(separatedBy: CharacterSet.letters.inverted)
            .filter { !$0.isEmpty }
        return stockHallucinationPhrases.contains(words.joined(separator: " "))
    }

    /// True when a whole transcript is not speech: only punctuation/symbols,
    /// a lone bracketed annotation ("*crying*", "[MUSIC]"), or a stock phrase
    /// on a recording that never reached speech-level energy.
    nonisolated static func isNonSpeechArtifact(_ text: String, audioSamples: [Float]) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if trimmed.rangeOfCharacter(from: .alphanumerics) == nil { return true }
        let wrappers: [(Character, Character)] = [("*", "*"), ("[", "]"), ("(", ")")]
        for (open, close) in wrappers where trimmed.first == open && trimmed.last == close {
            let inner = trimmed.dropFirst().dropLast()
            if !inner.contains(open), !inner.contains(close) { return true }
        }
        return isStockHallucination(trimmed) && !containsSpeechEnergy(audioSamples[...])
    }

    /// Throws the standard "no transcription" error instead of letting junk
    /// from a silent or accidental key press be injected into the target app.
    nonisolated static func rejectNonSpeechArtifact(_ text: String, audioSamples: [Float]) throws {
        guard isNonSpeechArtifact(text, audioSamples: audioSamples) else { return }
        Logger.transcription.info("Rejecting transcript that is not speech")
        throw noTranscriptionResultError()
    }

    /// A tail that decoded to nothing (or only a stock hallucination) can be
    /// dropped instead of re-decoding the whole recording when a committed
    /// prefix exists and the tail never reached speech-level energy.
    nonisolated static func tailCanBeDropped(
        tailPeakFrameRMS: Float,
        hasCommittedText: Bool
    ) -> Bool {
        hasCommittedText && tailPeakFrameRMS < speechEnergyThreshold
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

    /// Peak and median RMS over the sample's 100ms energy frames (a trailing
    /// partial frame is ignored once at least one full frame exists). Both
    /// are 0 for empty input.
    nonisolated static func frameRMSStatistics(of samples: [Float]) -> (peak: Float, median: Float) {
        guard !samples.isEmpty else { return (0, 0) }
        var energies: [Float] = []
        var frameStart = 0
        while frameStart < samples.count {
            let frameEnd = min(samples.count, frameStart + energyFrameSampleCount)
            if frameEnd - frameStart == energyFrameSampleCount || energies.isEmpty {
                energies.append(frameRMS(samples[frameStart..<frameEnd]))
            }
            frameStart = frameEnd
        }
        energies.sort()
        let middle = energies.count / 2
        let median = energies.count.isMultiple(of: 2)
            ? (energies[middle - 1] + energies[middle]) / 2
            : energies[middle]
        return (energies[energies.count - 1], median)
    }

    nonisolated static func containsSpeechEnergy(
        _ samples: ArraySlice<Float>,
        threshold: Float = speechEnergyThreshold
    ) -> Bool {
        lastSpeechSampleIndex(in: samples, threshold: threshold) != nil
    }

    nonisolated static func frameRMS(_ samples: ArraySlice<Float>) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Float = 0
        for sample in samples {
            sum += sample * sample
        }
        return (sum / Float(samples.count)).squareRoot()
    }

    /// Estimate the background from the quietest tenth of full 100ms frames.
    /// The small, capped margin tolerates room noise without using the much
    /// higher speech-onset threshold to decide whether a word has ended.
    /// Below-floor recordings retain the existing conservative floor.
    nonisolated static func pauseEnergyThreshold(in samples: ArraySlice<Float>) -> Float {
        var energies: [Float] = []
        var start = samples.startIndex
        while start + energyFrameSampleCount <= samples.endIndex {
            let end = start + energyFrameSampleCount
            energies.append(frameRMS(samples[start..<end]))
            start = end
        }
        guard !energies.isEmpty else { return faintEnergyFloor }
        energies.sort()
        let background = energies[(energies.count - 1) / 10]
        return min(maxPauseEnergyThreshold, max(faintEnergyFloor, background * 1.8))
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
    /// paused: require audible speech, then locate its end above background
    /// noise. The higher VAD threshold alone mistakes soft final words for
    /// silence, cutting them between the committed clip and its tail.
    nonisolated static func pauseCommitSampleCount(pendingAudio: ArraySlice<Float>) -> Int? {
        guard pendingAudio.count >= pauseCommitMinClipSampleCount + pauseCommitSilenceSampleCount else {
            return nil
        }
        guard containsSpeechEnergy(pendingAudio),
              let lastSpeechEnd = lastSpeechSampleIndex(
                in: pendingAudio, threshold: pauseEnergyThreshold(in: pendingAudio)
              ) else {
            return nil
        }
        guard pendingAudio.count - lastSpeechEnd >= pauseCommitSilenceSampleCount else { return nil }
        let clipSampleCount = min(pendingAudio.count, lastSpeechEnd + silencePadSampleCount)
        guard clipSampleCount >= pauseCommitMinClipSampleCount else { return nil }
        return clipSampleCount
    }

    /// Where to end an Express live segment in the uncommitted audio, or nil
    /// to wait. A segment ends at a pause the speaker is making now (0.7 s,
    /// as for Whisper's pause commits) once it holds 8 s; past 20 s without
    /// one, at the latest 200 ms gap between words after the first 8 s. It is
    /// never cut mid-word: continuous speech simply waits for the next gap,
    /// and whatever is left decodes at the end.
    nonisolated static func expressSegmentSampleCount(pendingAudio: ArraySlice<Float>) -> Int? {
        guard pendingAudio.count >= expressSegmentSnapshotSampleCount else { return nil }
        if let pause = pauseCommitSampleCount(pendingAudio: pendingAudio), pause >= expressSegmentMinSampleCount {
            return pause
        }
        guard pendingAudio.count >= expressSegmentGapSearchSampleCount else { return nil }
        let threshold = pauseEnergyThreshold(in: pendingAudio)
        let searchStart = pendingAudio.startIndex + expressSegmentMinSampleCount
        var quietSamples = 0
        var boundary: Int?
        var frameStart = searchStart
        while frameStart + energyFrameSampleCount <= pendingAudio.endIndex {
            let frameEnd = frameStart + energyFrameSampleCount
            if frameRMS(pendingAudio[frameStart..<frameEnd]) < threshold {
                quietSamples += energyFrameSampleCount
            } else {
                if quietSamples >= clipBoundaryGapSampleCount {
                    boundary = frameStart - pendingAudio.startIndex - quietSamples / 2
                }
                quietSamples = 0
            }
            frameStart = frameEnd
        }
        return boundary
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
            // Start greedily, then sample only when the quality gate requests
            // a fallback. Starting at 0.2 randomized even clean dictation;
            // topK is a sampling limit, not a beam-search accuracy setting.
            temperature = 0.0
            topK = 5
            fallbackCount = 5
            compressionRatioThreshold = 2.4
            logProbThreshold = -1.0
            noSpeechThreshold = 0.6
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
