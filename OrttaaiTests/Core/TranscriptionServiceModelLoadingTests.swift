// TranscriptionServiceModelLoadingTests.swift
// OrttaaiTests

import XCTest
import WhisperKit
@testable import Orttaai

/// Records the configuration of every pipeline the service asks to create, and
/// can hold a load open so tests can overlap two of them.
private actor WhisperKitFactoryRecorder {
    private(set) var configs: [WhisperKitConfig] = []
    private var isHolding: Bool
    private var held: [CheckedContinuation<Void, Never>] = []

    init(holdsLoads: Bool = false) {
        isHolding = holdsLoads
    }

    var callCount: Int { configs.count }

    func create(for config: WhisperKitConfig) async throws -> WhisperKit {
        configs.append(config)
        if isHolding {
            await withCheckedContinuation { held.append($0) }
        }
        // No model files and no download: an inert pipeline is enough to
        // observe what the service configured.
        return try await WhisperKit(WhisperKitConfig(load: false, download: false))
    }

    func release() {
        isHolding = false
        held.forEach { $0.resume() }
        held = []
    }
}

final class TranscriptionServiceModelLoadingTests: XCTestCase {
    private let modelID = "openai_whisper-small"
    private var temporaryDirectories: [URL] = []

    override func tearDown() {
        for directory in temporaryDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        temporaryDirectories = []
        super.tearDown()
    }

    /// A storage base laid out the way WhisperKit lays it out, with the small
    /// model (and optionally its tokenizer) inside.
    private func makeBase(withModel: Bool, withTokenizer: Bool) throws -> URL {
        let base = try ModelProbeTestSupport.makeTemporaryDirectory()
        temporaryDirectories.append(base)
        if withModel {
            try ModelProbeTestSupport.createFakeModel(
                at: ModelProbeTestSupport.repositoryRoot(under: base).appendingPathComponent(modelID, isDirectory: true)
            )
        }
        if withTokenizer {
            try ModelProbeTestSupport.createFakeTokenizer(named: "openai/whisper-small", under: base)
        }
        return base
    }

    private func makeService(
        base: URL,
        recorder: WhisperKitFactoryRecorder,
        probes: ModelStorageProbes? = nil,
        probeTimeout: TimeInterval = 0.5,
        legacyTokenizerBase: URL? = nil
    ) -> TranscriptionService {
        let probes = probes ?? ModelProbeTestSupport.probes(
            roots: [ModelProbeTestSupport.repositoryRoot(under: base)],
            beginAccessBase: base
        )
        let locator = ModelProbeTestSupport.locator(probes: probes, probeTimeout: probeTimeout)
        return TranscriptionService(
            modelLocator: locator,
            whisperKitFactory: { config in try await recorder.create(for: config) },
            // Tests never look at the real ~/Documents/huggingface.
            legacyTokenizerBase: legacyTokenizerBase
        )
    }

    // MARK: - Loading an existing model

    func testLoadsExistingModelWithTokenizerResolvedFromTheModelsOwnRoot() async throws {
        let base = try makeBase(withModel: true, withTokenizer: true)
        let recorder = WhisperKitFactoryRecorder()
        let service = makeService(base: base, recorder: recorder)

        try await service.loadModel(named: modelID)

        let configs = await recorder.configs
        XCTAssertEqual(configs.count, 1)
        let config = try XCTUnwrap(configs.first)
        XCTAssertEqual(
            config.modelFolder.map { ModelProbeTestSupport.standardizedPath(URL(fileURLWithPath: $0)) },
            ModelProbeTestSupport.standardizedPath(
                ModelProbeTestSupport.repositoryRoot(under: base).appendingPathComponent(modelID)
            )
        )
        XCTAssertEqual(
            config.tokenizerFolder.map(ModelProbeTestSupport.standardizedPath),
            ModelProbeTestSupport.standardizedPath(base),
            "The tokenizer is resolved from the root holding the model, never a default like Documents"
        )
        XCTAssertEqual(config.download, false)
        let loadedModelID = await service.loadedModelID()
        XCTAssertEqual(loadedModelID, modelID)
    }

    func testMissingTokenizerLoadsFromTheModelsOwnRootAndNeverThrows() async throws {
        let base = try makeBase(withModel: true, withTokenizer: false)
        let recorder = WhisperKitFactoryRecorder()
        let service = makeService(base: base, recorder: recorder, legacyTokenizerBase: nil)

        try await service.loadModel(named: modelID)

        let configs = await recorder.configs
        let config = try XCTUnwrap(configs.first)
        XCTAssertEqual(
            config.tokenizerFolder.map(ModelProbeTestSupport.standardizedPath),
            ModelProbeTestSupport.standardizedPath(base),
            "WhisperKit stores the small tokenizer it fetches under the model's own root, never Documents"
        )
        XCTAssertEqual(config.download, false, "Only the tokenizer may be fetched; the model is never downloaded")
    }

    func testTokenizerCachedByAnEarlierVersionInTheLegacyRootIsStillUsed() async throws {
        // Versions before this one cached tokenizers under ~/Documents/huggingface
        // whatever root the model lived in; a model on another drive must keep
        // loading without a fetch.
        let base = try makeBase(withModel: true, withTokenizer: false)
        let legacy = try ModelProbeTestSupport.makeTemporaryDirectory()
        temporaryDirectories.append(legacy)
        try ModelProbeTestSupport.createFakeTokenizer(named: "openai/whisper-small", under: legacy)
        let recorder = WhisperKitFactoryRecorder()
        let service = makeService(base: base, recorder: recorder, legacyTokenizerBase: legacy)

        try await service.loadModel(named: modelID)

        let configs = await recorder.configs
        let config = try XCTUnwrap(configs.first)
        XCTAssertEqual(
            config.tokenizerFolder.map(ModelProbeTestSupport.standardizedPath),
            ModelProbeTestSupport.standardizedPath(legacy)
        )
    }

    func testExplicitDownloadFlowMayFetchAMissingTokenizer() async throws {
        let base = try makeBase(withModel: true, withTokenizer: false)
        let recorder = WhisperKitFactoryRecorder()
        let service = makeService(base: base, recorder: recorder)

        try await service.loadModel(named: modelID, allowDownload: true)

        let configs = await recorder.configs
        let config = try XCTUnwrap(configs.first)
        XCTAssertEqual(
            config.tokenizerFolder.map(ModelProbeTestSupport.standardizedPath),
            ModelProbeTestSupport.standardizedPath(base)
        )
    }

    // MARK: - No implicit download

    func testMissingModelIsATypedErrorAndNeverStartsADownload() async throws {
        let base = try makeBase(withModel: false, withTokenizer: false)
        let recorder = WhisperKitFactoryRecorder()
        let service = makeService(base: base, recorder: recorder)

        do {
            try await service.loadModel(named: modelID)
            XCTFail("Expected modelFilesNotFound")
        } catch {
            XCTAssertEqual(error as? ModelLoadError, .modelFilesNotFound(modelID: modelID))
        }

        let callCount = await recorder.callCount
        let isLoaded = await service.isLoaded
        XCTAssertEqual(callCount, 0, "Warm-up and dictation must never download")
        XCTAssertFalse(isLoaded)
    }

    func testExplicitDownloadFlowDownloadsIntoTheSelectedStorage() async throws {
        let base = try makeBase(withModel: false, withTokenizer: false)
        let recorder = WhisperKitFactoryRecorder()
        let service = makeService(base: base, recorder: recorder)

        try await service.loadModel(named: modelID, allowDownload: true)

        let configs = await recorder.configs
        let config = try XCTUnwrap(configs.first)
        XCTAssertEqual(config.model, modelID)
        XCTAssertNil(config.modelFolder)
        XCTAssertEqual(
            config.downloadBase.map(ModelProbeTestSupport.standardizedPath),
            ModelProbeTestSupport.standardizedPath(base)
        )
    }

    func testUnreachableStorageIsUnavailableNotMissingAndNeverDownloads() async throws {
        let base = try makeBase(withModel: false, withTokenizer: false)
        let gate = BlockingGate()
        defer { gate.openPermanently() }
        let recorder = WhisperKitFactoryRecorder()
        let probes = ModelProbeTestSupport.probes(
            roots: [ModelProbeTestSupport.repositoryRoot(under: base)],
            scanRoot: { _ in
                gate.wait()
                return [:]
            },
            beginAccessBase: base
        )
        let service = makeService(base: base, recorder: recorder, probes: probes, probeTimeout: 0.1)

        for allowDownload in [false, true] {
            do {
                try await service.loadModel(named: modelID, allowDownload: allowDownload)
                XCTFail("Expected storageUnavailable")
            } catch {
                XCTAssertEqual(error as? ModelLoadError, .storageUnavailable)
            }
        }
        let callCount = await recorder.callCount
        XCTAssertEqual(callCount, 0)
    }

    // MARK: - Coalescing

    func testConcurrentLoadsOfTheSameModelShareOneLoad() async throws {
        let base = try makeBase(withModel: true, withTokenizer: true)
        let recorder = WhisperKitFactoryRecorder(holdsLoads: true)
        let service = makeService(base: base, recorder: recorder)

        async let warmUp: Void = service.loadModel(named: modelID)
        async let finalization: Void = service.loadModel(named: modelID)

        try await waitUntil { await recorder.callCount == 1 }
        // Give the second caller time to arrive; it must join, not start a load.
        try await Task.sleep(nanoseconds: 200_000_000)
        let callCountWhileLoading = await recorder.callCount
        XCTAssertEqual(callCountWhileLoading, 1)

        await recorder.release()
        _ = try await (warmUp, finalization)

        let callCount = await recorder.callCount
        let loadedModelID = await service.loadedModelID()
        XCTAssertEqual(callCount, 1, "Warm-up and the first finalization load the model once")
        XCTAssertEqual(loadedModelID, modelID)
    }

    func testDownloadCapableCallerRetriesWhenTheJoinedLoadCouldNotDownload() async throws {
        let base = try makeBase(withModel: false, withTokenizer: false)
        let recorder = WhisperKitFactoryRecorder()
        let gate = BlockingGate()
        defer { gate.openPermanently() }
        let probes = ModelProbeTestSupport.probes(
            roots: [ModelProbeTestSupport.repositoryRoot(under: base)],
            scanRoot: { root in
                gate.wait()
                return ModelManager.detectDownloadedVariantDirectories(in: [root])
            },
            beginAccessBase: base
        )
        let service = makeService(base: base, recorder: recorder, probes: probes, probeTimeout: 5)

        let warmUp = Task { try await service.loadModel(named: modelID) }
        try await Task.sleep(nanoseconds: 100_000_000)
        let explicitDownload = Task { try await service.loadModel(named: modelID, allowDownload: true) }
        try await Task.sleep(nanoseconds: 100_000_000)
        gate.openPermanently()

        do {
            try await warmUp.value
            XCTFail("The warm-up load must report the missing model")
        } catch {
            XCTAssertEqual(error as? ModelLoadError, .modelFilesNotFound(modelID: modelID))
        }
        try await explicitDownload.value

        let configs = await recorder.configs
        let config = try XCTUnwrap(configs.first)
        XCTAssertEqual(config.model, modelID)
        let callCount = await recorder.callCount
        XCTAssertEqual(callCount, 1)
    }

    private func waitUntil(_ condition: @escaping () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !(await condition()) {
            guard Date() < deadline else {
                XCTFail("Timed out waiting for condition")
                return
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}
