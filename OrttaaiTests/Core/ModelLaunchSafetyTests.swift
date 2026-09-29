// ModelLaunchSafetyTests.swift
// OrttaaiTests
//
// The model layer must never be able to block application launch: nothing that
// runs while the app starts may touch the model folders, and a failed warm-up
// must not discard the user's model selection.

import XCTest
@testable import Orttaai

@MainActor
final class ModelLaunchSafetyTests: XCTestCase {
    private let savedKeys = ["selectedModelId", "activeModelId", "dictationLanguage"]
    private var savedDefaults: [String: Any] = [:]

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
        super.tearDown()
    }

    // MARK: - Launch never touches the model folders

    func testModelManagerInitPerformsNoFileSystemWork() async throws {
        let counters = ProbeCounters()
        let locator = ModelProbeTestSupport.locator(
            probes: ModelProbeTestSupport.probes(
                roots: [URL(fileURLWithPath: "/nonexistent-model-root")],
                counters: counters
            )
        )
        let transcription = TranscriptionService(modelLocator: locator)

        let manager = ModelManager(
            transcriptionService: transcription,
            settings: AppSettings(),
            locator: locator
        )
        // Work started asynchronously by init would show up within this window.
        try await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertEqual(counters.total, 0, "ModelManager.init must not scan, stat or open any model folder")
        XCTAssertFalse(manager.availableModels.isEmpty)
    }

    func testDeleteModelRunsThroughTheLocator() async throws {
        let root = try ModelProbeTestSupport.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try ModelProbeTestSupport.createFakeModel(at: root.appendingPathComponent("openai_whisper-small"))
        let locator = ModelProbeTestSupport.locator(probes: ModelProbeTestSupport.probes(roots: [root]))
        let manager = ModelManager(
            transcriptionService: TranscriptionService(modelLocator: locator),
            settings: AppSettings(),
            locator: locator
        )

        try await manager.deleteModel(named: "openai_whisper-small")

        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("openai_whisper-small").path))
        let inventory = await locator.inventory()
        XCTAssertTrue(inventory.directories.isEmpty)
    }

    func testStorageSnapshotPlaceholderTouchesNoFileSystem() {
        let suite = "ModelLaunchSafetyTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("/Volumes/NotMounted/huggingface", forKey: ModelStorageLocation.customPathKey)

        let snapshot = ModelStorageLocation.placeholderSnapshot(defaults: defaults)

        XCTAssertEqual(snapshot.url.path, "/Volumes/NotMounted/huggingface")
        XCTAssertTrue(snapshot.isCustom)
    }

    // MARK: - Warm-up failure keeps the model selection

    func testFailedWarmUpNeverClearsTheActiveModel() async {
        let settings = AppSettings()
        settings.dictationLanguage = "auto"
        settings.selectedModelId = "openai_whisper-large-v3-v20240930"
        settings.activeModelId = "openai_whisper-large-v3-v20240930"

        let failures: [(Error, String)] = [
            (ModelLoadError.storageUnavailable, "Model folder unavailable"),
            (ModelLoadError.modelFilesNotFound(modelID: "openai_whisper-large-v3-v20240930"), "Model not found. Open Settings > Models"),
            (ModelLoadError.tokenizerNotFound(modelID: "openai_whisper-large-v3-v20240930"), "Model incomplete. Open Settings > Models"),
            (ModelStorageLocationError.folderMissing("/Volumes/Missing"), "Model folder unavailable"),
            (NSError(domain: "test", code: 1), "Model not loaded"),
        ]
        for (error, expectedStatus) in failures {
            let transcription = FailingLoadTranscriptionService(error: error)

            let outcome = await ModelWarmUp.perform(
                settings: settings,
                transcription: transcription,
                warmUp: {}
            )

            XCTAssertEqual(outcome, .failed(statusLine: expectedStatus))
            XCTAssertEqual(
                settings.activeModelId,
                "openai_whisper-large-v3-v20240930",
                "\(error) must not wipe the selected model"
            )
            XCTAssertEqual(settings.selectedModelId, "openai_whisper-large-v3-v20240930")
        }
    }

    func testSuccessfulWarmUpRecordsTheLoadedModel() async {
        let settings = AppSettings()
        settings.dictationLanguage = "auto"
        settings.selectedModelId = "openai_whisper-small"
        settings.activeModelId = ""
        let transcription = FailingLoadTranscriptionService(error: nil)

        let outcome = await ModelWarmUp.perform(settings: settings, transcription: transcription, warmUp: {})

        XCTAssertEqual(outcome, .ready(modelID: "openai_whisper-small"))
        XCTAssertEqual(settings.activeModelId, "openai_whisper-small")
    }
}

/// Fails (or succeeds) at loading without any Core ML or file-system work.
private actor FailingLoadTranscriptionService: Transcribing {
    private let error: Error?
    private var loaded: String?

    init(error: Error?) {
        self.error = error
    }

    var isLoaded: Bool { loaded != nil }

    func loadedModelID() -> String? { loaded }

    func loadModel(named modelName: String) async throws {
        if let error { throw error }
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
