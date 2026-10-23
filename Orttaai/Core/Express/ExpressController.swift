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

/// Turns Express on and off from Settings: installs Fluid Speech Mini on
/// first use, loads and warms it, and puts the Whisper model back whenever
/// Express is turned off or cannot load, so dictation always has a model.
@Observable
final class ExpressController {
    private(set) var status: ExpressStatus
    /// Set when a dictation could not load Express and used Whisper instead.
    private(set) var fallbackMessage: String?

    private let transcriptionService: TranscriptionService
    private let settings: AppSettings
    private let locator: ModelDirectoryLocator
    private var changeTask: Task<Void, Never>?
    private var fallbackObserver: NSObjectProtocol?

    init(transcriptionService: TranscriptionService, settings: AppSettings, locator: ModelDirectoryLocator) {
        self.transcriptionService = transcriptionService
        self.settings = settings
        self.locator = locator
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
        let installed = await isInstalled()
        let loaded = await transcriptionService.loadedModelID() == ExpressEngine.modelID
        status = loaded ? .active : (installed ? .installed : .notInstalled)
    }

    func setEnabled(_ enabled: Bool) {
        changeTask?.cancel()
        changeTask = Task { [weak self] in
            guard let self else { return }
            if enabled {
                await self.turnOn()
            } else {
                await self.turnOff()
            }
            self.changeTask = nil
        }
    }

    func dismissFallbackMessage() {
        fallbackMessage = nil
    }

    /// Deletes the model package (253 MB). Turns Express off first.
    func removeModel() {
        changeTask?.cancel()
        changeTask = Task { [weak self] in
            guard let self else { return }
            await self.turnOff()
            do {
                let access = try await locator.beginAccess(createIfNeeded: false, requiresWrite: true)
                try await ExpressModelStore.remove(from: access.url)
                status = .notInstalled
            } catch {
                status = .failed("Couldn't remove the Express model: \(error.localizedDescription)")
            }
            self.changeTask = nil
        }
    }

    private func turnOn() async {
        settings.expressEngineEnabled = true
        fallbackMessage = nil
        do {
            if await !isInstalled() {
                status = .downloading(progress: 0)
                let access = try await locator.beginAccess(createIfNeeded: true, requiresWrite: true)
                let throttle = ProgressThrottle()
                try await ExpressModelStore.install(into: access.url) { fraction in
                    guard throttle.shouldReport(fraction) else { return }
                    Task { @MainActor [weak self] in
                        guard let self, case .downloading = self.status else { return }
                        self.status = .downloading(progress: fraction)
                    }
                }
            }
            try Task.checkCancellation()
            guard settings.isExpressEngineActive else {
                // Installed and on, but dictation is not in English.
                status = .installed
                return
            }
            status = .loading
            await settings.syncTranscriptionSettings(to: transcriptionService)
            try await transcriptionService.loadModel(named: ExpressEngine.modelID)
            await transcriptionService.warmUp()
            status = .active
            Logger.model.info("Express is the dictation engine")
        } catch is CancellationError {
            return
        } catch {
            Logger.model.error("Turning Express on failed: \(error.localizedDescription, privacy: .public)")
            settings.expressEngineEnabled = false
            status = .failed(error.localizedDescription)
            await restoreWhisperIfExpressLoaded(force: true)
        }
    }

    private func turnOff() async {
        settings.expressEngineEnabled = false
        await restoreWhisperIfExpressLoaded(force: false)
        let installed = await isInstalled()
        status = installed ? .installed : .notInstalled
    }

    /// Loads the selected Whisper model when Express is resident (or after a
    /// failed switch), so the next dictation does not pay for the load.
    private func restoreWhisperIfExpressLoaded(force: Bool) async {
        let loaded = await transcriptionService.loadedModelID()
        guard force || loaded == ExpressEngine.modelID else { return }
        let whisperModelID = settings.applyLanguageOptimizedSmallModelSelection()
        guard loaded != whisperModelID else { return }
        do {
            try await transcriptionService.loadModel(named: whisperModelID)
            await transcriptionService.warmUp()
        } catch {
            Logger.model.error("Reloading \(whisperModelID) after Express failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func isInstalled() async -> Bool {
        guard let access = try? await locator.beginAccess(createIfNeeded: false, requiresWrite: false) else {
            return false
        }
        let storageBase = access.url
        return await locator.probe { ExpressModelStore.isInstalled(in: storageBase) } ?? false
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
