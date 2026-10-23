// ExpressRoutingTests.swift
// OrttaaiTests
//
// Express is selected by model id: TranscriptionService hands that id to the
// Express backend, settings decide when dictation asks for it, and warm-up
// falls back to the Whisper model when it cannot load. No Core ML runs here.

import XCTest
@testable import Orttaai

@MainActor
final class ExpressRoutingTests: XCTestCase {
    private let savedKeys = ["selectedModelId", "activeModelId", "dictationLanguage", "expressEngineEnabled"]
    private var savedDefaults: [String: Any] = [:]
    private var directories: [URL] = []

    override func setUp() {
        super.setUp()
        savedDefaults = savedKeys.reduce(into: [:]) { snapshot, key in
            if let value = UserDefaults.standard.object(forKey: key) {
                snapshot[key] = value
            }
        }
    }

    override func tearDown() {
        for key in savedKeys {
            if let value = savedDefaults[key] {
                UserDefaults.standard.set(value, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        for directory in directories {
            try? FileManager.default.removeItem(at: directory)
        }
        super.tearDown()
    }

    // MARK: - TranscriptionService

    /// A storage base whose Express package has every file at its recorded
    /// size. Sparse files: a quarter-gigabyte package costs no disk space.
    private func makeInstalledBase(withWordBoost: Bool = false) throws -> URL {
        let base = try ModelProbeTestSupport.makeTemporaryDirectory()
        directories.append(base)
        let packages = withWordBoost ? ExpressModelStore.packages : [ExpressModelStore.speech]
        for package in packages {
            let folder = ExpressModelStore.folder(for: package, in: base)
            for file in package.files {
                let url = folder.appendingPathComponent(file.localPath)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                FileManager.default.createFile(atPath: url.path, contents: nil)
                let handle = try FileHandle(forWritingTo: url)
                try handle.truncate(atOffset: UInt64(file.size))
                try handle.close()
            }
        }
        return base
    }

    private func makeService(
        base: URL,
        backend: FakeExpressBackend,
        loadedFolders: FolderRecorder = FolderRecorder()
    ) -> TranscriptionService {
        let probes = ModelProbeTestSupport.probes(roots: [], beginAccessBase: base)
        return TranscriptionService(
            modelLocator: ModelProbeTestSupport.locator(probes: probes),
            whisperKitFactory: { _ in throw NSError(domain: "test", code: 1) },
            expressBackendFactory: { speech, wordBoost in
                loadedFolders.record(speech: speech, wordBoost: wordBoost)
                return backend
            },
            legacyTokenizerBase: nil
        )
    }

    private func speech(seconds: Double) -> [Float] {
        (0..<Int(seconds * 16_000)).map { 0.2 * sin(Float($0) * 0.05) }
    }

    func testExpressNeedsItsInstalledPackage() async throws {
        let empty = try ModelProbeTestSupport.makeTemporaryDirectory()
        directories.append(empty)
        let service = makeService(base: empty, backend: FakeExpressBackend(text: "hello"))

        do {
            try await service.loadModel(named: ExpressEngine.modelID)
            XCTFail("Express must not load without its files")
        } catch let error as ModelLoadError {
            XCTAssertEqual(error, .modelFilesNotFound(modelID: ExpressEngine.modelID))
        }
        let isLoaded = await service.isLoaded
        XCTAssertFalse(isLoaded)
    }

    func testExpressTranscribesThroughTheBackend() async throws {
        let backend = FakeExpressBackend(text: "  Send it to Olanrewaju.  ")
        let service = makeService(base: try makeInstalledBase(), backend: backend)

        try await service.loadModel(named: ExpressEngine.modelID)
        let text = try await service.transcribe(audioSamples: speech(seconds: 2))

        XCTAssertEqual(text, "Send it to Olanrewaju.")
        let isLoaded = await service.isLoaded
        let loadedID = await service.loadedModelID()
        XCTAssertTrue(isLoaded)
        XCTAssertEqual(loadedID, ExpressEngine.modelID)
    }

    func testFinalizeDecodesTheWholeRecordingOnce() async throws {
        let backend = FakeExpressBackend(text: "Ship it on Friday.")
        let service = makeService(base: try makeInstalledBase(), backend: backend)
        try await service.loadModel(named: ExpressEngine.modelID)
        let audio = speech(seconds: 20)

        await service.beginLiveTranscriptionSession()
        await service.processLiveAudioSnapshot(Array(audio.prefix(16_000 * 16)))
        let (text, trace) = try await service.finalizeLiveTranscriptionDetailed(audioSamples: audio)

        XCTAssertEqual(text, "Ship it on Friday.")
        XCTAssertEqual(trace.path, .expressWholeDecode)
        let calls = await backend.sampleCounts
        XCTAssertEqual(calls, [audio.count], "no live clips: one decode of the full recording")
    }

    func testRecordingHandsEachCompletedWordBoostChunkToTheBackendOnce() async throws {
        let backend = FakeExpressBackend(text: "Ship it on Friday.")
        let service = makeService(base: try makeInstalledBase(), backend: backend)
        try await service.loadModel(named: ExpressEngine.modelID)
        await service.setWordBoostVocabulary([WordBoostTerm(text: "Olanrewaju", aliases: [])])
        let audio = speech(seconds: 30)

        await service.beginLiveTranscriptionSession()
        // Under 15 s there is no complete chunk yet.
        await service.processLiveAudioSnapshot(Array(audio.prefix(16_000 * 10)))
        await service.processLiveAudioSnapshot(Array(audio.prefix(16_000 * 16)))
        // The first chunk is still with the backend: nothing new is sent.
        await service.processLiveAudioSnapshot(Array(audio.prefix(16_000 * 17)))
        _ = try await service.finalizeLiveTranscriptionDetailed(audioSamples: audio)

        let prepared = await backend.preparedSampleCounts
        XCTAssertEqual(prepared, [16_000 * 16])
        let decodes = await backend.sampleCounts
        XCTAssertEqual(decodes, [audio.count])
    }

    func testExpressAsksForAudioOnlyWhenAWordBoostChunkCompletes() async throws {
        let backend = FakeExpressBackend(text: "Ship it on Friday.")
        let service = makeService(base: try makeInstalledBase(), backend: backend)
        let chunk = WordBoostChunks.chunkSampleCount
        let stride = WordBoostChunks.strideSampleCount

        // Nothing loaded: the Whisper path takes the whole recording.
        var start = await service.liveAudioSnapshotStart(capturedSampleCount: chunk)
        XCTAssertEqual(start, 0)

        try await service.loadModel(named: ExpressEngine.modelID)
        await service.beginLiveTranscriptionSession()
        start = await service.liveAudioSnapshotStart(capturedSampleCount: chunk)
        XCTAssertNil(start, "without Word Boost terms Express needs no audio until key release")

        await service.setWordBoostVocabulary([WordBoostTerm(text: "Olanrewaju", aliases: [])])
        start = await service.liveAudioSnapshotStart(capturedSampleCount: chunk - 1)
        XCTAssertNil(start)
        start = await service.liveAudioSnapshotStart(capturedSampleCount: chunk)
        XCTAssertEqual(start, 0, "Word Boost chunks are scored on the whole recording")

        await service.processLiveAudioSnapshot(speech(seconds: 15))
        while await !(backend.preparedSampleCounts.count == 1) {
            await Task.yield()
        }
        for _ in 0..<50 {
            if await service.liveAudioSnapshotStart(capturedSampleCount: chunk + stride - 1) == nil { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        start = await service.liveAudioSnapshotStart(capturedSampleCount: chunk + stride - 1)
        XCTAssertNil(start, "the first chunk was already sent")
        start = await service.liveAudioSnapshotStart(capturedSampleCount: chunk + stride)
        XCTAssertEqual(start, 0, "the second chunk is complete")
    }

    func testRecordingSendsNothingToPrepareWithoutWordBoostTerms() async throws {
        let backend = FakeExpressBackend(text: "Ship it on Friday.")
        let service = makeService(base: try makeInstalledBase(), backend: backend)
        try await service.loadModel(named: ExpressEngine.modelID)

        await service.beginLiveTranscriptionSession()
        await service.processLiveAudioSnapshot(speech(seconds: 20))
        _ = try await service.finalizeLiveTranscriptionDetailed(audioSamples: speech(seconds: 20))

        let prepared = await backend.preparedSampleCounts
        XCTAssertEqual(prepared, [])
    }

    func testCancelledRecordingDiscardsPreparedWordBoostScores() async throws {
        let backend = FakeExpressBackend(text: "Ship it on Friday.")
        let service = makeService(base: try makeInstalledBase(), backend: backend)
        try await service.loadModel(named: ExpressEngine.modelID)
        await service.setWordBoostVocabulary([WordBoostTerm(text: "Olanrewaju", aliases: [])])

        await service.beginLiveTranscriptionSession()
        await service.processLiveAudioSnapshot(speech(seconds: 16))
        await service.cancelLiveTranscriptionSession()

        for _ in 0..<50 where await backend.discardCount == 0 {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let discards = await backend.discardCount
        XCTAssertEqual(discards, 1)
    }

    func testEmptyExpressResultIsNoTranscription() async throws {
        let service = makeService(base: try makeInstalledBase(), backend: FakeExpressBackend(text: ""))
        try await service.loadModel(named: ExpressEngine.modelID)

        do {
            _ = try await service.transcribe(audioSamples: [Float](repeating: 0, count: 32_000))
            XCTFail("silence must report no result, like a WhisperKit decode")
        } catch {}
    }

    func testUnloadReleasesExpress() async throws {
        let service = makeService(base: try makeInstalledBase(), backend: FakeExpressBackend(text: "hi"))
        try await service.loadModel(named: ExpressEngine.modelID)

        await service.unloadModel()

        let isLoaded = await service.isLoaded
        let loadedID = await service.loadedModelID()
        XCTAssertFalse(isLoaded)
        XCTAssertNil(loadedID)
    }

    func testWordBoostFolderIsPassedOnlyWhenInstalled() async throws {
        let withoutBoost = FolderRecorder()
        let plain = makeService(base: try makeInstalledBase(), backend: FakeExpressBackend(text: "hi"), loadedFolders: withoutBoost)
        try await plain.loadModel(named: ExpressEngine.modelID)
        XCTAssertNotNil(withoutBoost.speech)
        XCTAssertNil(withoutBoost.wordBoost)

        let withBoost = FolderRecorder()
        let base = try makeInstalledBase(withWordBoost: true)
        let boosted = makeService(base: base, backend: FakeExpressBackend(text: "hi"), loadedFolders: withBoost)
        try await boosted.loadModel(named: ExpressEngine.modelID)
        XCTAssertEqual(withBoost.wordBoost, ExpressModelStore.folder(for: ExpressModelStore.wordBoost, in: base))
    }

    func testWordBoostVocabularySetBeforeLoadIsAppliedOnLoad() async throws {
        let backend = FakeExpressBackend(text: "hi")
        let service = makeService(base: try makeInstalledBase(withWordBoost: true), backend: backend)
        let terms = [WordBoostTerm(text: "Olanrewaju", aliases: ["alan ruaju"]), WordBoostTerm(text: "GRDB", aliases: [])]

        await service.setWordBoostVocabulary(terms)
        let countBeforeLoad = await service.wordBoostTermCount
        try await service.loadModel(named: ExpressEngine.modelID)

        let applied = await backend.wordBoostTerms
        let count = await service.wordBoostTermCount
        XCTAssertEqual(countBeforeLoad, 0)
        XCTAssertEqual(applied, terms)
        XCTAssertEqual(count, 2)

        await service.setWordBoostVocabulary([])
        let countAfterClearing = await service.wordBoostTermCount
        XCTAssertEqual(countAfterClearing, 0)
    }

    // MARK: - Settings

    func testDictationUsesExpressOnlyWhenOnAndEnglish() {
        let settings = AppSettings()
        settings.selectedModelId = "openai_whisper-large-v3-v20240930"
        settings.dictationLanguage = "en"

        settings.expressEngineEnabled = false
        XCTAssertEqual(settings.dictationModelID(), "openai_whisper-large-v3-v20240930")

        settings.expressEngineEnabled = true
        XCTAssertEqual(settings.dictationModelID(), ExpressEngine.modelID)

        settings.dictationLanguage = "fr"
        XCTAssertEqual(settings.dictationModelID(), "openai_whisper-large-v3-v20240930")
    }

    func testExpressNeverReplacesTheWhisperSelection() {
        let settings = AppSettings()
        settings.activeModelId = "openai_whisper-small.en"

        settings.recordLoadedModel(ExpressEngine.modelID)
        XCTAssertEqual(settings.activeModelId, "openai_whisper-small.en")

        settings.recordLoadedModel("openai_whisper-large-v3-v20240930")
        XCTAssertEqual(settings.activeModelId, "openai_whisper-large-v3-v20240930")
    }

    // MARK: - Warm-up

    func testWarmUpLoadsExpressWithoutTouchingTheWhisperSelection() async {
        let settings = AppSettings()
        settings.dictationLanguage = "en"
        settings.selectedModelId = "openai_whisper-large-v3-v20240930"
        settings.activeModelId = "openai_whisper-large-v3-v20240930"
        settings.expressEngineEnabled = true
        let transcription = ScriptedLoadTranscriptionService(failing: [])

        let outcome = await ModelWarmUp.perform(settings: settings, transcription: transcription, warmUp: {})

        XCTAssertEqual(outcome, .ready(modelID: ExpressEngine.modelID))
        XCTAssertEqual(settings.activeModelId, "openai_whisper-large-v3-v20240930")
    }

    func testWarmUpFallsBackToWhisperWhenExpressCannotLoad() async {
        let settings = AppSettings()
        settings.dictationLanguage = "en"
        settings.selectedModelId = "openai_whisper-large-v3-v20240930"
        settings.activeModelId = ""
        settings.expressEngineEnabled = true
        let transcription = ScriptedLoadTranscriptionService(failing: [ExpressEngine.modelID])

        let outcome = await ModelWarmUp.perform(settings: settings, transcription: transcription, warmUp: {})

        XCTAssertEqual(
            outcome,
            .readyWithoutExpress(
                modelID: "openai_whisper-large-v3-v20240930",
                statusLine: ModelWarmUp.expressFallbackStatusLine
            )
        )
        XCTAssertEqual(settings.activeModelId, "openai_whisper-large-v3-v20240930")
        XCTAssertTrue(settings.expressEngineEnabled, "a failed load is not the user turning Express off")
    }
}

private actor FakeExpressBackend: ExpressBackend {
    private let text: String
    private(set) var sampleCounts: [Int] = []
    private(set) var wordBoostTerms: [WordBoostTerm] = []
    private(set) var preparedSampleCounts: [Int] = []
    private(set) var discardCount = 0

    init(text: String) {
        self.text = text
    }

    func transcribe(_ audioSamples: [Float]) async throws -> String {
        sampleCounts.append(audioSamples.count)
        return text
    }

    func setWordBoost(_ terms: [WordBoostTerm]) async -> Int {
        wordBoostTerms = terms
        return terms.count
    }

    func prepareWordBoost(_ audioPrefix: [Float]) async {
        preparedSampleCounts.append(audioPrefix.count)
    }

    func discardPreparedWordBoost() async {
        discardCount += 1
    }
}

private final class FolderRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var folders: (speech: URL?, wordBoost: URL?) = (nil, nil)

    func record(speech: URL, wordBoost: URL?) {
        lock.lock()
        folders = (speech, wordBoost)
        lock.unlock()
    }

    var speech: URL? {
        lock.lock()
        defer { lock.unlock() }
        return folders.speech
    }

    var wordBoost: URL? {
        lock.lock()
        defer { lock.unlock() }
        return folders.wordBoost
    }
}

/// Loads any model except the listed ids, without Core ML or the file system.
private actor ScriptedLoadTranscriptionService: Transcribing {
    private let failing: Set<String>
    private var loaded: String?

    init(failing: Set<String>) {
        self.failing = failing
    }

    var isLoaded: Bool { loaded != nil }

    func loadedModelID() -> String? { loaded }

    func loadModel(named modelName: String) async throws {
        if failing.contains(modelName) {
            throw ModelLoadError.modelFilesNotFound(modelID: modelName)
        }
        loaded = modelName
    }

    func transcribe(audioSamples: [Float]) async throws -> String { "" }
    func beginLiveTranscriptionSession() {}
    func processLiveAudioSnapshot(_ audioSamples: [Float]) {}
    func finalizeLiveTranscription(audioSamples: [Float]) async throws -> String { "" }
    func cancelLiveTranscriptionSession() {}
    func setLiveTranscriptEventHandler(_ handler: (@Sendable (LiveTranscriptEvent) -> Void)?) {}
    func setVocabularyBias(terms: [String]) {}
    func updateSettings(
        language: String,
        computeMode: String,
        lowLatencyMode: Bool,
        decodingPreferences: DecodingPreferences
    ) {}
}
