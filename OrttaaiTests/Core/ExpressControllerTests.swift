// ExpressControllerTests.swift
// OrttaaiTests
//
// Switching between Express and Express Pro from Settings: the current model
// keeps dictating until the new one is installed, a failed switch leaves it in
// place, and a switch can be called off while it downloads. The installer is
// a stand-in that writes sparse files, so nothing is downloaded. Storage
// probes get a long timeout: under a busy full-suite run the default 0.3 s
// can expire and read as "not installed".

import XCTest
@testable import Orttaai

@MainActor
final class ExpressControllerTests: XCTestCase {
    private let savedKeys = [
        "selectedModelId", "activeModelId", "dictationLanguage", "expressEngineEnabled", "expressModel",
        "expressWordBoostEnabled",
    ]
    private var savedDefaults: [String: Any] = [:]
    private var directories: [URL] = []

    override func setUp() {
        super.setUp()
        savedDefaults = savedKeys.reduce(into: [:]) { snapshot, key in
            if let value = UserDefaults.standard.object(forKey: key) {
                snapshot[key] = value
            }
        }
        let settings = AppSettings()
        settings.dictationLanguage = "en"
        settings.selectedModelId = "openai_whisper-small.en"
        settings.expressModel = .mini
        settings.expressEngineEnabled = true
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

    // MARK: - Helpers

    private func makeBase(installing models: [ExpressModel]) throws -> URL {
        let base = try ModelProbeTestSupport.makeTemporaryDirectory()
        directories.append(base)
        for model in models {
            try Self.install(model, in: base)
        }
        return base
    }

    /// Every file of `model`'s packages at its recorded size. Sparse files:
    /// a 600 MB package costs no disk space.
    nonisolated private static func install(_ model: ExpressModel, in base: URL) throws {
        for package in ExpressModelStore.packages(for: model) {
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
    }

    private func makeService(base: URL) -> TranscriptionService {
        let probes = ModelProbeTestSupport.probes(roots: [], beginAccessBase: base)
        return TranscriptionService(
            modelLocator: ModelProbeTestSupport.locator(probes: probes, probeTimeout: 10),
            whisperKitFactory: { _ in throw NSError(domain: "test", code: 1) },
            expressBackendFactory: { _, _ in SilentExpressBackend() },
            legacyTokenizerBase: nil
        )
    }

    private func makeController(
        base: URL,
        service: TranscriptionService,
        installer: @escaping ExpressController.Installer
    ) -> ExpressController {
        let probes = ModelProbeTestSupport.probes(roots: [], beginAccessBase: base)
        return ExpressController(
            transcriptionService: service,
            settings: AppSettings(),
            locator: ModelProbeTestSupport.locator(probes: probes, probeTimeout: 10),
            installer: installer
        )
    }

    private func waitUntil(
        _ description: String,
        timeout: Duration = .seconds(15),
        _ condition: () async -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for \(description)")
    }

    // MARK: - Switching

    func testSwitchKeepsTheCurrentModelUntilTheNewOneIsInstalled() async throws {
        let base = try makeBase(installing: [.mini])
        let service = makeService(base: base)
        try await service.loadModel(named: ExpressModel.mini.modelID)
        let seenDuringInstall = Recorder<String?>()
        let controller = makeController(base: base, service: service) { model, storageBase, progress in
            seenDuringInstall.append(UserDefaults.standard.string(forKey: "expressModel"))
            progress(0.5)
            try Self.install(model, in: storageBase)
        }

        controller.setModel(.pro)
        XCTAssertEqual(controller.pendingModel, .pro)
        XCTAssertEqual(controller.displayedModel, .pro)
        XCTAssertEqual(AppSettings().expressModel, .mini, "Mini stays the dictation model while Pro downloads")

        try await waitUntil("Pro to load") {
            await service.loadedModelID() == ExpressModel.pro.modelID && controller.status == .active
        }
        XCTAssertEqual(seenDuringInstall.values, ["mini"])
        XCTAssertEqual(AppSettings().expressModel, .pro)
        XCTAssertNil(controller.pendingModel)
        XCTAssertNil(controller.switchError)
        XCTAssertTrue(AppSettings().expressEngineEnabled)
    }

    func testFailedDownloadKeepsTheCurrentModelAndExpressOn() async throws {
        let base = try makeBase(installing: [.mini])
        let service = makeService(base: base)
        try await service.loadModel(named: ExpressModel.mini.modelID)
        let controller = makeController(base: base, service: service) { _, _, _ in
            throw URLError(.notConnectedToInternet)
        }

        controller.setModel(.pro)

        try await waitUntil("the switch to fail") { controller.switchError != nil }
        try await waitUntil("the status to settle") { controller.status == .active }
        let settings = AppSettings()
        XCTAssertTrue(settings.expressEngineEnabled, "a failed switch must not turn Express off")
        XCTAssertEqual(settings.expressModel, .mini)
        XCTAssertNil(controller.pendingModel)
        let loadedID = await service.loadedModelID()
        XCTAssertEqual(loadedID, ExpressModel.mini.modelID)
    }

    func testPickingTheCurrentModelCancelsADownloadInProgress() async throws {
        let base = try makeBase(installing: [.mini])
        let service = makeService(base: base)
        try await service.loadModel(named: ExpressModel.mini.modelID)
        let cancelled = Recorder<Bool>()
        let controller = makeController(base: base, service: service) { _, _, _ in
            do {
                try await Task.sleep(for: .seconds(30))
            } catch {
                cancelled.append(true)
                throw error
            }
        }

        controller.setModel(.pro)
        try await waitUntil("the download to start") {
            if case .downloading = controller.status { return true }
            return false
        }
        controller.setModel(.mini)

        try await waitUntil("the download to stop") { cancelled.values == [true] }
        try await waitUntil("Mini to show as active") { controller.status == .active }
        XCTAssertNil(controller.pendingModel)
        XCTAssertEqual(AppSettings().expressModel, .mini)
        XCTAssertTrue(AppSettings().expressEngineEnabled)
    }

    func testSwitchWithExpressOffOnlyRecordsTheChoice() async throws {
        AppSettings().expressEngineEnabled = false
        let base = try makeBase(installing: [.mini])
        let calls = Recorder<ExpressModel>()
        let controller = makeController(base: base, service: makeService(base: base)) { model, _, _ in
            calls.append(model)
        }

        controller.setModel(.pro)

        XCTAssertEqual(AppSettings().expressModel, .pro)
        XCTAssertNil(controller.pendingModel)
        try await waitUntil("the status to show Pro isn't downloaded") { controller.status == .notInstalled }
        XCTAssertTrue(controller.hasDownloadedModels, "Mini is still on disk, so it can be removed")
        XCTAssertTrue(calls.values.isEmpty, "nothing downloads while Express is off")
    }

    // MARK: - Language

    func testChoosingAProLanguageLoadsPro() async throws {
        let settings = AppSettings()
        settings.expressModel = .pro
        settings.dictationLanguage = "fr"
        let base = try makeBase(installing: [.pro])
        let service = makeService(base: base)
        let controller = makeController(base: base, service: service) { _, _, _ in }

        controller.dictationLanguageDidChange()

        try await waitUntil("Pro to load for French") {
            await service.loadedModelID() == ExpressModel.pro.modelID && controller.status == .active
        }
        let loadedID = await service.loadedModelID()
        XCTAssertEqual(loadedID, ExpressModel.pro.modelID, "status: \(controller.status), language: \(AppSettings().dictationLanguage), model: \(AppSettings().expressModel), on: \(AppSettings().expressEngineEnabled)")
        XCTAssertEqual(controller.boostedWordCount, 0, "Word Boost is English only")
    }
}

private actor SilentExpressBackend: ExpressBackend {
    func transcribe(_ audioSamples: [Float]) async throws -> String { "" }
    func setWordBoost(_ terms: [WordBoostTerm]) async -> Int { terms.count }
}

private final class Recorder<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [Value] = []

    func append(_ value: Value) {
        lock.lock()
        stored.append(value)
        lock.unlock()
    }

    var values: [Value] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}
