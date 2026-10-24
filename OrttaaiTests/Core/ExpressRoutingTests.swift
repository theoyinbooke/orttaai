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
        backend: any ExpressBackend,
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

    // MARK: - Live segments

    private func silence(seconds: Double) -> [Float] {
        [Float](repeating: 0, count: Int(seconds * 16_000))
    }

    private func segmentedService(_ backend: ScriptedExpressBackend) async throws -> TranscriptionService {
        let service = makeService(base: try makeInstalledBase(), backend: backend)
        try await service.loadModel(named: ExpressEngine.modelID)
        await service.setExpressLiveSegments(true)
        await service.beginLiveTranscriptionSession()
        return service
    }

    func testSegmentEndsAtAPauseOnceItHoldsEightSeconds() {
        let pending = speech(seconds: 9) + silence(seconds: 0.8)
        XCTAssertEqual(
            TranscriptionService.expressSegmentSampleCount(pendingAudio: pending[...]),
            16_000 * 9 + TranscriptionService.silencePadSampleCount
        )
    }

    func testNoSegmentBeforeEightSecondsOrWhileTheSpeakerIsTalking() {
        let early = speech(seconds: 5) + silence(seconds: 1) + speech(seconds: 3)
        XCTAssertNil(TranscriptionService.expressSegmentSampleCount(pendingAudio: early[...]))
        let short = speech(seconds: 6) + silence(seconds: 1)
        XCTAssertNil(TranscriptionService.expressSegmentSampleCount(pendingAudio: short[...]))
    }

    func testLongSpeechWithoutAPauseIsCutAtAGapBetweenWordsNeverMidWord() {
        let gapped = speech(seconds: 12) + silence(seconds: 0.3) + speech(seconds: 9)
        XCTAssertEqual(
            TranscriptionService.expressSegmentSampleCount(pendingAudio: gapped[...]),
            16_000 * 12 + 16_000 * 3 / 20
        )
        let tooSoon = speech(seconds: 12) + silence(seconds: 0.3) + speech(seconds: 5)
        XCTAssertNil(TranscriptionService.expressSegmentSampleCount(pendingAudio: tooSoon[...]), "under 20 s, only a pause cuts")
        let continuous = speech(seconds: 25)
        XCTAssertNil(TranscriptionService.expressSegmentSampleCount(pendingAudio: continuous[...]))
    }

    func testSegmentsDecodeWhileRecordingAndFinalizeDecodesOnlyTheTail() async throws {
        // Each decode covers its segment plus overlap; they are stitched
        // where their words agree.
        let backend = ScriptedExpressBackend(["Ship it on Friday. Then", "on Friday. Then tell Ada."])
        let service = try await segmentedService(backend)
        // A pause at 10 s, then 2 s more audio so the pause can be judged.
        let recorded = speech(seconds: 10) + silence(seconds: 1) + speech(seconds: 2)
        let audio = recorded + speech(seconds: 2)

        let early = await service.liveAudioSnapshotStart(capturedSampleCount: 16_000 * 10)
        XCTAssertNil(early, "a pause is only judged 2 s after it")
        let start = await service.liveAudioSnapshotStart(capturedSampleCount: recorded.count)
        XCTAssertEqual(start, 0)
        await service.processLiveAudio(recorded, startingAt: 0)
        let (text, trace) = try await service.finalizeLiveTranscriptionDetailed(audioSamples: audio)

        XCTAssertEqual(text, "Ship it on Friday. Then tell Ada.")
        XCTAssertEqual(trace.path, .expressSegments)
        XCTAssertEqual(trace.committedClipCount, 1)
        let segment = 16_000 * 10 + TranscriptionService.silencePadSampleCount
        let calls = await backend.sampleCounts
        // The segment with 2 s after it, then the tail with 3 s before it.
        XCTAssertEqual(calls, [segment + 16_000 * 2, audio.count - (segment - 16_000 * 3)])
    }

    func testNumbersAreFormattedOnceTheSegmentsAreJoined() async throws {
        let backend = ScriptedExpressBackend(["Meet me at three thirty", "at three thirty pm on Friday."])
        let service = try await segmentedService(backend)
        let recorded = speech(seconds: 10) + silence(seconds: 1) + speech(seconds: 2)

        await service.processLiveAudio(recorded, startingAt: 0)
        let (text, _) = try await service.finalizeLiveTranscriptionDetailed(audioSamples: recorded)

        XCTAssertEqual(text, ExpressNumberFormatter.format("Meet me at three thirty pm on Friday."))
    }

    func testSeamTakesEachDecodesWordsFromTheSideThatHeardThemInContext() {
        // The earlier decode heard "first" at its edge; the later one in the
        // middle of the sentence.
        XCTAssertEqual(
            TranscriptionService.stitchedExpressText(
                "We agreed to test everything on staging. First",
                "test everything on staging first. Then we ship."
            ),
            "We agreed to test everything on staging first. Then we ship."
        )
    }

    func testSeamNeedsTwoWordsTheDecodesAgreeOn() {
        XCTAssertNil(TranscriptionService.stitchedExpressText("Ship it on Friday.", "Then tell Ada."))
        XCTAssertNil(TranscriptionService.stitchedExpressText("Ship it on Friday.", "Friday. Then tell Ada."))
        XCTAssertEqual(TranscriptionService.stitchedExpressText(nil, "Then tell Ada."), "Then tell Ada.")
    }

    func testLiveLoopCopiesOnlyUncommittedAudioAndItsContext() async throws {
        let backend = ScriptedExpressBackend(["Ship it on Friday."])
        let service = try await segmentedService(backend)
        let short = await service.liveAudioSnapshotStart(capturedSampleCount: 16_000 * 10)
        XCTAssertNil(short, "nothing to segment before 8.7 s plus the 2 s lookahead")

        await service.processLiveAudio(speech(seconds: 10) + silence(seconds: 1) + speech(seconds: 2), startingAt: 0)
        for _ in 0..<100 where await backend.sampleCounts.isEmpty { await Task.yield() }
        for _ in 0..<50 {
            if await service.liveAudioSnapshotStart(capturedSampleCount: 16_000 * 30) != nil { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let next = await service.liveAudioSnapshotStart(capturedSampleCount: 16_000 * 30)
        XCTAssertEqual(next, 16_000 * 7 + TranscriptionService.silencePadSampleCount, "from 3 s before the commit point")
    }

    func testFailedSegmentFallsBackToOneWholeDecode() async throws {
        let backend = ScriptedExpressBackend(["", "Ship it on Friday. Then tell Ada."])
        let service = try await segmentedService(backend)
        let first = speech(seconds: 10) + silence(seconds: 1) + speech(seconds: 2)
        let audio = first + speech(seconds: 2)

        await service.processLiveAudio(first, startingAt: 0)
        let (text, trace) = try await service.finalizeLiveTranscriptionDetailed(audioSamples: audio)

        XCTAssertEqual(text, "Ship it on Friday. Then tell Ada.")
        XCTAssertEqual(trace.path, .expressSegmentFallback)
        let calls = await backend.sampleCounts
        XCTAssertEqual(calls.last, audio.count)
    }

    func testSegmentsStayOffWhileWordBoostHasDictionaryWords() async throws {
        let backend = ScriptedExpressBackend(["Ship it on Friday. Then tell Ada."])
        let service = makeService(base: try makeInstalledBase(), backend: backend)
        try await service.loadModel(named: ExpressEngine.modelID)
        await service.setExpressLiveSegments(true)
        await service.setWordBoostVocabulary([WordBoostTerm(text: "Olanrewaju", aliases: [])])
        await service.beginLiveTranscriptionSession()
        let recorded = speech(seconds: 10) + silence(seconds: 1) + speech(seconds: 2)

        await service.processLiveAudio(recorded, startingAt: 0)
        let (_, trace) = try await service.finalizeLiveTranscriptionDetailed(audioSamples: recorded)

        XCTAssertEqual(trace.path, .expressWholeDecode)
        let calls = await backend.sampleCounts
        XCTAssertEqual(calls, [recorded.count])
    }

    func testShortRecordingWithSegmentsOnStillDecodesWhole() async throws {
        let backend = ScriptedExpressBackend(["Ship it."])
        let service = try await segmentedService(backend)
        let audio = speech(seconds: 5)

        await service.processLiveAudio(audio, startingAt: 0)
        let (text, trace) = try await service.finalizeLiveTranscriptionDetailed(audioSamples: audio)

        XCTAssertEqual(text, "Ship it.")
        XCTAssertEqual(trace.path, .expressWholeDecode)
        let calls = await backend.sampleCounts
        XCTAssertEqual(calls, [audio.count])
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

        // No live session: nothing to copy.
        var start = await service.liveAudioSnapshotStart(capturedSampleCount: chunk)
        XCTAssertNil(start, "no live session yet")

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

    func testDashboardsShowTheModelDictationRunsOn() {
        let settings = AppSettings()
        settings.activeModelId = "openai_whisper-large-v3-v20240930"
        settings.dictationLanguage = "en"

        settings.expressEngineEnabled = true
        XCTAssertEqual(settings.dictationModelIDForDisplay, ExpressEngine.modelID)

        settings.expressEngineEnabled = false
        XCTAssertEqual(settings.dictationModelIDForDisplay, "openai_whisper-large-v3-v20240930")
        settings.activeModelId = " "
        XCTAssertNil(settings.dictationModelIDForDisplay)
    }

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

/// Returns its scripted transcripts in order, then repeats the last one.
private actor ScriptedExpressBackend: ExpressBackend {
    private var texts: [String]
    private(set) var sampleCounts: [Int] = []

    init(_ texts: [String]) {
        self.texts = texts
    }

    func transcribe(_ audioSamples: [Float]) async throws -> String {
        sampleCounts.append(audioSamples.count)
        return texts.count > 1 ? texts.removeFirst() : texts[0]
    }


    func setWordBoost(_ terms: [WordBoostTerm]) async -> Int { terms.count }
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
