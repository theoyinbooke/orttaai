// ExpressController.swift
// Orttaai

import Foundation
import os

enum ExpressStatus: Equatable {
    /// This Mac runs macOS 14: Settings hides Express.
    case unsupported
    case checking
    case notInstalled
    case downloading(progress: Double)
    /// On disk but not the loaded engine (Express is off, or dictation is not
    /// in English).
    case installed
    case loading
    /// Loaded: dictation is using Express.
    case active
    case failed(String)
}

/// Turns Express on and off from Settings and switches between its models:
/// installs the chosen model (Fluid Speech Mini or Pro) on first use, loads
/// and warms it, and puts the Whisper model back whenever Express is turned
/// off or cannot load, so dictation always has a model.
///
/// Switching models with Express on keeps the current model selected and
/// loaded until the new one is installed, so dictation never waits on a
/// download, and a failed switch leaves the old model in place.
@Observable
final class ExpressController {
    /// Installs a model's packages into a storage base, reporting progress.
    typealias Installer = @Sendable (ExpressModel, URL, @escaping @Sendable (Double) -> Void) async throws -> Void

    private(set) var status: ExpressStatus
    /// Set when a dictation could not load Express and used Whisper instead.
    private(set) var fallbackMessage: String?
    /// Set when switching to another Express model failed and the previous
    /// model stayed in use.
    private(set) var switchError: String?
    /// The model being downloaded for a switch, before it becomes the
    /// selected model.
    private(set) var pendingModel: ExpressModel?
    /// Whether any Express speech model is on disk, selected or not.
    private(set) var hasDownloadedModels = false
    /// Dictionary words Word Boost is using, as of the last refresh.
    private(set) var boostedWordCount = 0
    /// The Personal Memory dictionary as Word Boost terms. Set by the app
    /// once the text processor exists; empty until then.
    var wordBoostVocabulary: () -> [WordBoostTerm] = { [] }

    private let transcriptionService: TranscriptionService
    private let settings: AppSettings
    private let locator: ModelDirectoryLocator
    private let installer: Installer
    private var changeTask: Task<Void, Never>?
    /// Increments with every change, so a superseded change can tell it no
    /// longer owns `changeTask` or the progress bar.
    private var changeGeneration = 0
    private var fallbackObserver: NSObjectProtocol?

    init(
        transcriptionService: TranscriptionService,
        settings: AppSettings,
        locator: ModelDirectoryLocator,
        installer: @escaping Installer = { model, storageBase, progress in
            try await ExpressModelStore.installMissing(for: model, into: storageBase, progress: progress)
        }
    ) {
        self.transcriptionService = transcriptionService
        self.settings = settings
        self.locator = locator
        self.installer = installer
        status = ExpressEngine.isSupported ? .checking : .unsupported
        fallbackObserver = NotificationCenter.default.addObserver(
            forName: .expressEngineDidFallBack,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let reason = notification.object as? String ?? "unknown error"
            MainActor.assumeIsolated {
                self?.fallbackMessage = "Express couldn't load (\(reason)), so dictation used Whisper."
            }
        }
    }

    var isEnabled: Bool {
        settings.expressEngineEnabled
    }

    /// The Express model dictation uses when Express is on.
    var model: ExpressModel {
        settings.expressModel
    }

    /// The model Settings shows as chosen: the one being switched to, if any.
    var displayedModel: ExpressModel {
        pendingModel ?? settings.expressModel
    }

    var isBusy: Bool {
        switch status {
        case .checking, .downloading, .loading: return true
        default: return false
        }
    }

    func refresh() async {
        guard ExpressEngine.isSupported else {
            status = .unsupported
            return
        }
        guard changeTask == nil else { return }
        await updateStatus()
    }

    /// Sends the current dictionary to Word Boost (or nothing when it is off)
    /// and records how many words it took. Dictation refreshes the same
    /// vocabulary at the start of every session.
    func applyWordBoostVocabulary() async {
        let terms = settings.isExpressWordBoostActive ? wordBoostVocabulary() : []
        await transcriptionService.setWordBoostVocabulary(terms)
        boostedWordCount = await transcriptionService.wordBoostTermCount
    }

    func setEnabled(_ enabled: Bool) {
        pendingModel = nil
        switchError = nil
        startChange { controller, generation in
            if enabled {
                await controller.turnOn(generation: generation)
            } else {
                await controller.turnOff()
            }
        }
    }

    /// Switches Express to `newModel`. With Express on, it downloads the new
    /// model while the current one keeps dictating, then loads it in its
    /// place; if the download or load fails, the current model stays. With
    /// Express off it only records the choice.
    func setModel(_ newModel: ExpressModel) {
        guard newModel != displayedModel else { return }
        switchError = nil
        guard settings.expressEngineEnabled, newModel != settings.expressModel else {
            // Express is off, or this cancels a switch still downloading.
            settings.expressModel = newModel
            pendingModel = nil
            startChange { controller, _ in await controller.updateStatus() }
            return
        }
        pendingModel = newModel
        startChange { controller, generation in
            await controller.switchModel(to: newModel, generation: generation)
        }
    }

    /// Loads the Express model the new dictation language calls for, or puts
    /// Whisper back when the language is one Express doesn't cover. A change
    /// already in progress checks the language itself when it finishes.
    func dictationLanguageDidChange() {
        guard ExpressEngine.isSupported, settings.expressEngineEnabled, changeTask == nil else { return }
        startChange { controller, generation in
            await controller.turnOn(generation: generation)
        }
    }

    func dismissFallbackMessage() {
        fallbackMessage = nil
    }

    func dismissSwitchError() {
        switchError = nil
    }

    func setWordBoostEnabled(_ enabled: Bool) {
        settings.expressWordBoostEnabled = enabled
        Task { await applyWordBoostVocabulary() }
    }

    /// Deletes every Express model (Mini and Pro) and Word Boost. Turns
    /// Express off first.
    func removeModel() {
        pendingModel = nil
        switchError = nil
        startChange { controller, _ in
            await controller.turnOff()
            do {
                let access = try await controller.locator.beginAccess(createIfNeeded: false, requiresWrite: true)
                try await ExpressModelStore.remove(from: access.url)
                controller.status = .notInstalled
                controller.hasDownloadedModels = false
            } catch {
                controller.status = .failed("Couldn't remove the Express models: \(error.localizedDescription)")
            }
        }
    }

    /// Runs one change at a time: a new change cancels the one before it,
    /// and only the latest change clears `changeTask` when it ends.
    private func startChange(_ work: @escaping @MainActor (ExpressController, Int) async -> Void) {
        changeTask?.cancel()
        changeGeneration += 1
        let generation = changeGeneration
        changeTask = Task { [weak self] in
            guard let self else { return }
            await work(self, generation)
            if self.changeGeneration == generation {
                self.changeTask = nil
            }
        }
    }

    private func switchModel(to newModel: ExpressModel, generation: Int) async {
        let previous = settings.expressModel
        do {
            try await installIfNeeded(newModel, generation: generation)
            try Task.checkCancellation()
        } catch is CancellationError {
            return
        } catch {
            Logger.model.error("Downloading \(newModel.displayName, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            pendingModel = nil
            switchError = "Couldn't download \(newModel.productName) (\(error.localizedDescription)). Express is still using \(previous.displayName)."
            await updateStatus()
            return
        }
        settings.expressModel = newModel
        pendingModel = nil
        await turnOn(fallback: previous, generation: generation)
    }

    /// Installs `model`'s packages when they are missing. Progress from a
    /// superseded change never reaches the progress bar.
    private func installIfNeeded(_ model: ExpressModel, generation: Int) async throws {
        guard await !isInstalled(model) else { return }
        status = .downloading(progress: 0)
        let access = try await locator.beginAccess(createIfNeeded: true, requiresWrite: true)
        let throttle = ProgressThrottle()
        try await installer(model, access.url) { fraction in
            guard throttle.shouldReport(fraction) else { return }
            Task { @MainActor [weak self] in
                guard let self, self.changeGeneration == generation, case .downloading = self.status else { return }
                self.status = .downloading(progress: fraction)
            }
        }
        hasDownloadedModels = true
    }

    /// Turns Express on with the selected model. When `fallback` is set (a
    /// switch) and the new model can't load, Express goes back to `fallback`
    /// instead of turning off.
    private func turnOn(fallback: ExpressModel? = nil, generation: Int) async {
        settings.expressEngineEnabled = true
        fallbackMessage = nil
        do {
            try await installIfNeeded(model, generation: generation)
            try Task.checkCancellation()
            guard settings.isExpressEngineActive else {
                // Installed and on, but dictation is in a language this model
                // doesn't know: don't leave an Express model resident.
                await restoreWhisperIfExpressLoaded(force: false)
                try Task.checkCancellation()
                status = .installed
                return
            }
            status = .loading
            await settings.syncTranscriptionSettings(to: transcriptionService)
            try await transcriptionService.loadModel(named: model.modelID)
            try Task.checkCancellation()
            await applyWordBoostVocabulary()
            await transcriptionService.warmUp()
            try Task.checkCancellation()
            status = .active
            Logger.model.info("\(self.model.productName, privacy: .public) is the dictation engine")
        } catch is CancellationError {
            return
        } catch {
            Logger.model.error("Turning \(self.model.productName, privacy: .public) on failed: \(error.localizedDescription, privacy: .public)")
            if let fallback, fallback != model {
                switchError = "\(model.productName) couldn't start (\(error.localizedDescription)). Express is back on \(fallback.displayName)."
                settings.expressModel = fallback
                await turnOn(generation: generation)
                return
            }
            settings.expressEngineEnabled = false
            status = .failed(error.localizedDescription)
            await restoreWhisperIfExpressLoaded(force: true)
        }
    }

    private func turnOff() async {
        settings.expressEngineEnabled = false
        await restoreWhisperIfExpressLoaded(force: false)
        await updateStatus()
    }

    /// The selected model's state, from what is on disk and loaded.
    private func updateStatus() async {
        let installed = await isInstalled(model)
        hasDownloadedModels = await isAnySpeechModelInstalled()
        let loaded = await transcriptionService.loadedModelID() == model.modelID
        status = loaded ? .active : (installed ? .installed : .notInstalled)
        if loaded {
            await applyWordBoostVocabulary()
        }
    }

    /// Loads the selected Whisper model when Express is resident (or after a
    /// failed switch), so the next dictation does not pay for the load.
    private func restoreWhisperIfExpressLoaded(force: Bool) async {
        let loaded = await transcriptionService.loadedModelID()
        guard force || loaded.map(ExpressEngine.isModelID) == true else { return }
        let whisperModelID = settings.applyLanguageOptimizedSmallModelSelection()
        guard loaded != whisperModelID else { return }
        do {
            try await transcriptionService.loadModel(named: whisperModelID)
            await transcriptionService.warmUp()
        } catch {
            Logger.model.error("Reloading \(whisperModelID) after Express failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func isInstalled(_ model: ExpressModel) async -> Bool {
        await probeInstalled([ExpressModelStore.packages(for: model)])
    }

    private func isAnySpeechModelInstalled() async -> Bool {
        await probeInstalled(ExpressModel.allCases.map { [ExpressModelStore.speech(for: $0)] })
    }

    /// True when every package of at least one of `packageSets` is on disk.
    private func probeInstalled(_ packageSets: [[ExpressModelPackage]]) async -> Bool {
        guard let access = try? await locator.beginAccess(createIfNeeded: false, requiresWrite: false) else {
            return false
        }
        let storageBase = access.url
        return await locator.probe {
            packageSets.contains { packages in
                packages.allSatisfy { ExpressModelStore.isInstalled($0, in: storageBase) }
            }
        } ?? false
    }
}

/// Download progress arrives many times a second from a background thread;
/// the UI only needs whole-percent steps.
nonisolated private final class ProgressThrottle: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock(initialState: -1)

    func shouldReport(_ fraction: Double) -> Bool {
        let percent = Int(fraction * 100)
        return lock.withLock { last in
            guard percent != last else { return false }
            last = percent
            return true
        }
    }
}
