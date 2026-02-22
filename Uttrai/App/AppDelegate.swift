// AppDelegate.swift
// Uttrai

import Cocoa
import Combine
import os

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var statusBarController: StatusBarController?
    private var statusBarMenu: StatusBarMenu?
    private var windowManager: WindowManager?
    private var appState: AppState?
    private var floatingPanel: FloatingPanelController?

    // Core services
    private var audioService: AudioCaptureService?
    private var transcriptionService: TranscriptionService?
    private var injectionService: TextInjectionService?
    private var hotkeyService: HotkeyService?
    private var databaseManager: DatabaseManager?
    private var modelManager: ModelManager?
    private var coordinator: DictationCoordinator?

    private var stateObservationTask: Task<Void, Never>?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Create status bar item
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        if let button = statusItem.button {
            let image = NSImage(systemSymbolName: "waveform.circle", accessibilityDescription: "Uttrai")
            image?.isTemplate = true
            button.image = image
        }

        // Initialize app state
        let state = AppState()
        appState = state

        // Set up UI
        statusBarController = StatusBarController(statusItem: statusItem)
        statusBarMenu = StatusBarMenu()
        windowManager = WindowManager()
        floatingPanel = FloatingPanelController()

        statusBarMenu?.onHistoryAction = { [weak self] in
            self?.windowManager?.showHistoryWindow()
        }
        statusBarMenu?.onSettingsAction = { [weak self] in
            self?.windowManager?.showSettingsWindow()
        }
        statusBarMenu?.onQuitAction = {
            NSApplication.shared.terminate(nil)
        }

        statusItem.menu = statusBarMenu?.menu

        // Initialize core services
        setupCoreServices(settings: state.settings)

        // Check if setup is needed
        if !state.settings.hasCompletedSetup {
            windowManager?.showSetupWindow()
        } else {
            startHotkeyService()
            warmUpModel()
        }

        Logger.ui.info("App launched, setup complete: \(state.settings.hasCompletedSetup)")
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotkeyService?.stop()
        stateObservationTask?.cancel()
    }

    // MARK: - Setup

    private func setupCoreServices(settings: AppSettings) {
        let audio = AudioCaptureService()
        let transcription = TranscriptionService()
        let textProcessor = PassthroughProcessor()
        let injection = TextInjectionService()

        do {
            let db = try DatabaseManager()
            databaseManager = db

            let coord = DictationCoordinator(
                audioService: audio,
                transcriptionService: transcription,
                textProcessor: textProcessor,
                injectionService: injection,
                databaseManager: db,
                settings: settings
            )

            audioService = audio
            transcriptionService = transcription
            injectionService = injection
            coordinator = coord
            modelManager = ModelManager(transcriptionService: transcription)

            observeCoordinatorState()

            Logger.ui.info("Core services initialized")
        } catch {
            Logger.ui.error("Failed to initialize database: \(error.localizedDescription)")
        }
    }

    private func startHotkeyService() {
        let hotkey = HotkeyService()
        hotkey.onKeyDown = { [weak self] in
            self?.coordinator?.startRecording()
        }
        hotkey.onKeyUp = { [weak self] in
            self?.coordinator?.stopRecording()
        }

        let success = hotkey.start()
        if success {
            hotkeyService = hotkey
            Logger.hotkey.info("Hotkey service started successfully")
        } else {
            Logger.hotkey.error("Hotkey service failed to start — Input Monitoring may not be granted")
        }
    }

    private func warmUpModel() {
        guard let transcription = transcriptionService,
              let settings = appState?.settings else { return }

        statusBarController?.updateIcon(state: .processing)
        statusBarMenu?.updateStatusLine("Loading model...")

        Task {
            do {
                try await transcription.loadModel(named: settings.selectedModelId)
                await transcription.warmUp()
                await MainActor.run {
                    self.statusBarController?.updateIcon(state: .idle)
                    self.statusBarMenu?.updateStatusLine("Ready")
                    Logger.model.info("Model warm-up complete")
                }
            } catch {
                await MainActor.run {
                    self.statusBarController?.updateIcon(state: .error)
                    self.statusBarMenu?.updateStatusLine("Model not loaded")
                    Logger.model.error("Model warm-up failed: \(error.localizedDescription)")
                }
            }
        }
    }

    // MARK: - State Observation

    private func observeCoordinatorState() {
        // Poll coordinator state to update UI
        stateObservationTask = Task { @MainActor [weak self] in
            var lastState: DictationCoordinator.State?

            while !Task.isCancelled {
                guard let self = self, let coordinator = self.coordinator else {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                    continue
                }

                let currentState = coordinator.state
                if currentState != lastState {
                    lastState = currentState
                    self.handleStateChange(currentState)
                }

                try? await Task.sleep(nanoseconds: 33_000_000) // ~30fps
            }
        }
    }

    private func handleStateChange(_ state: DictationCoordinator.State) {
        switch state {
        case .idle:
            statusBarController?.updateIcon(state: .idle)
            statusBarMenu?.updateStatusLine("Ready")
            floatingPanel?.dismiss()

        case .recording:
            statusBarController?.updateIcon(state: .recording)
            statusBarMenu?.updateStatusLine("Recording...")
            floatingPanel?.updateContent(
                WaveformView(audioLevel: coordinator?.audioLevel ?? 0)
            )
            floatingPanel?.show()

        case .processing(let estimate):
            statusBarController?.updateIcon(state: .processing)
            statusBarMenu?.updateStatusLine("Processing...")
            let estimateText = estimate.map { "~\(Int($0))s to process" }
            floatingPanel?.updateContent(
                ProcessingIndicatorView(estimateText: estimateText, errorMessage: nil)
            )

        case .injecting:
            statusBarController?.updateIcon(state: .processing)
            statusBarMenu?.updateStatusLine("Processing...")

        case .error(let message):
            statusBarController?.updateIcon(state: .error)
            statusBarMenu?.updateStatusLine("Error")
            floatingPanel?.updateContent(
                ProcessingIndicatorView(estimateText: nil, errorMessage: message)
            )
            floatingPanel?.show()
        }
    }
}
