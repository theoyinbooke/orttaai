// AppDelegate.swift
// Orttaai

import Cocoa
import KeyboardShortcuts
import os
import Sparkle

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var statusBarController: StatusBarController?
    private var statusBarMenu: StatusBarMenu?
    private var windowManager: WindowManager?
    private var appState: AppState?
    private var floatingPanel: FloatingPanelController?
    private var updaterController: SPUStandardUpdaterController?

    // Core services
    private var audioService: AudioCaptureService?
    private var transcriptionService: TranscriptionService?
    private var injectionService: TextInjectionService?
    private var databaseManager: DatabaseManager?
    private var modelManager: ModelManager?
    private var coordinator: DictationCoordinator?

    private var waveformUpdateTask: Task<Void, Never>?
    private var lastWaveformLevelBucket: Int = -1
    private var lastRecordingCountdown: Int?
    private var lastRecordingElapsedSeconds: Int?
    private var lastRecordingTargetAppName: String?
    private var runtimeServicesStarted = false
    private var shortcutObserver: NSObjectProtocol?
    private let shortcutChangeNotification = Notification.Name("KeyboardShortcuts_shortcutByNameDidChange")
    private let hasCompletedSetupKey = "hasCompletedSetup"
    private var isPushToTalkPressed = false
    private let recordingStartCue = NSSound.Name("Glass")
    private let recordingStopCue = NSSound.Name("Pop")
    private let errorCue = NSSound.Name("Funk")
    private var activeCueSound: NSSound?
    private var isHomeWorkspaceAutoOpenEnabled: Bool {
        appState?.settings.homeWorkspaceAutoOpenEnabled ?? false
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppResetService.handleLaunchArguments()

        // Create status bar item
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        if let button = statusItem.button {
            let image = NSImage(systemSymbolName: "waveform.circle", accessibilityDescription: "Orttaai")
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
        floatingPanel?.onStartRecording = { [weak self] in
            self?.coordinator?.startRecording()
        }
        floatingPanel?.onStopRecording = { [weak self] in
            self?.coordinator?.stopRecording()
        }
        configureUpdater()

        windowManager?.onSetupCompleted = { [weak self] in
            guard let self = self else { return }
            UserDefaults.standard.set(true, forKey: self.hasCompletedSetupKey)
            self.appState?.settings.hasCompletedSetup = true
            self.activateRuntimeServicesIfNeeded()
        }
        windowManager?.onSetupReadyForTesting = { [weak self] in
            self?.activateRuntimeServicesIfNeeded()
        }
        windowManager?.onHomeRunSetup = { [weak self] in
            self?.startSetupFlow()
        }

        statusBarMenu?.onHomeAction = { [weak self] in
            self?.openHomeWorkspace(section: .overview)
        }
        statusBarMenu?.onHistoryAction = { [weak self] in
            self?.openHomeWorkspace(section: .analytics)
        }
        statusBarMenu?.onSetupAction = { [weak self] in
            self?.startSetupFlow()
        }
        statusBarMenu?.onSettingsAction = { [weak self] in
            self?.openHomeWorkspace(section: .settings)
        }
        statusBarMenu?.onCheckForUpdatesAction = { [weak self] in
            self?.checkForUpdates()
        }
        statusBarMenu?.onQuitAction = {
            NSApplication.shared.terminate(nil)
        }
        statusBarMenu?.setHomePreviewMode(!isHomeWorkspaceAutoOpenEnabled)

        statusItem.menu = statusBarMenu?.menu

        // Initialize core services
        setupCoreServices(settings: state.settings)
        observeSystemWake()
        ensureDefaultShortcuts()

        // Check if setup is needed
        let hasCompletedSetup = UserDefaults.standard.bool(forKey: hasCompletedSetupKey)
        presentInitialWindow(hasCompletedSetup: hasCompletedSetup)

        Logger.ui.info(
            "App launched, setup complete: \(hasCompletedSetup), home auto-open: \(self.isHomeWorkspaceAutoOpenEnabled)"
        )
        observeShortcutChanges()
    }

    func applicationWillTerminate(_ notification: Notification) {
        KeyboardShortcuts.removeHandler(for: .pushToTalk)
        stopWaveformUpdates()
        if let shortcutObserver {
            NotificationCenter.default.removeObserver(shortcutObserver)
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        let hasCompletedSetup = UserDefaults.standard.bool(forKey: hasCompletedSetupKey)
        guard !hasCompletedSetup else { return }
        guard windowManager?.isSetupWindowVisible() == false else { return }
        windowManager?.showSetupWindow()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows _: Bool) -> Bool {
        if !UserDefaults.standard.bool(forKey: hasCompletedSetupKey) {
            windowManager?.showSetupWindow()
            return true
        }

        // Dock icon click should always surface Home for quick access.
        openHomeWorkspace(section: .overview)
        return true
    }

    // MARK: - Setup

    private func startSetupFlow() {
        // "Run Setup" from menu/home is a maintenance path for an already-complete user.
        // Do not reset completion state unless we are in first-run onboarding.
        if !UserDefaults.standard.bool(forKey: hasCompletedSetupKey) {
            appState?.settings.hasCompletedSetup = false
        }
        windowManager?.showSetupWindow()
    }

    private func openHomeWorkspace(section: HomeSection) {
        windowManager?.showHomeWindow(section: section)
    }

    private func configureUpdater() {
        guard !Bundle.main.isHomebrewInstall else {
            updaterController = nil
            return
        }

        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }

    private func checkForUpdates() {
        updaterController?.checkForUpdates(nil)
    }

    private func setupCoreServices(settings: AppSettings) {
        let audio = AudioCaptureService()
        let transcription = TranscriptionService()
        let injection = TextInjectionService()

        do {
            let db = try DatabaseManager()
            let baseTextProcessor = RuleBasedTextProcessor(databaseManager: db, settings: settings)
            let textProcessor = LocalLLMTextProcessor(
                baseProcessor: baseTextProcessor,
                settings: settings
            )
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
            let mm = ModelManager(transcriptionService: transcription, settings: settings)
            modelManager = mm
            ModelManager.shared = mm

            observeCoordinatorState()

            Logger.ui.info("Core services initialized")
        } catch {
            Logger.ui.error("Failed to initialize database: \(error.localizedDescription)")
        }
    }

    private func presentInitialWindow(hasCompletedSetup: Bool) {
        // Wait one runloop so app activation is ready before opening a custom NSWindow.
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if !hasCompletedSetup {
                self.windowManager?.showSetupWindow()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                    guard let self = self else { return }
                    guard self.windowManager?.isSetupWindowVisible() == false else { return }
                    Logger.ui.warning("Setup window was not visible after launch, retrying presentation")
                    self.windowManager?.showSetupWindow()
                }
            } else {
                self.activateRuntimeServicesIfNeeded()
                // Launching from the Dock should surface Home immediately.
                self.openHomeWorkspace(section: .overview)
            }
        }
    }

    private func startHotkeyService() -> Bool {
        guard KeyboardShortcuts.getShortcut(for: .pushToTalk) != nil else {
            Logger.hotkey.error("No push-to-talk shortcut configured")
            return false
        }

        isPushToTalkPressed = false
        KeyboardShortcuts.removeHandler(for: .pushToTalk)

        KeyboardShortcuts.onKeyDown(for: .pushToTalk) { [weak self] in
            guard let self = self, !self.isPushToTalkPressed else { return }
            self.isPushToTalkPressed = true
            Logger.hotkey.info("Push-to-talk key down")
            self.coordinator?.startRecording()
        }

        KeyboardShortcuts.onKeyUp(for: .pushToTalk) { [weak self] in
            guard let self = self, self.isPushToTalkPressed else { return }
            self.isPushToTalkPressed = false
            Logger.hotkey.info("Push-to-talk key up")
            self.coordinator?.stopRecording()
        }

        Logger.hotkey.info("Hotkey handlers registered")
        return true
    }

    private func observeSystemWake() {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Logger.audio.info("System wake detected — marking audio subsystem for revalidation")
            self?.audioService?.markAudioSystemStale()
        }
    }

    private func ensureDefaultShortcuts() {
        let defaultShortcut = KeyboardShortcuts.Shortcut(.space, modifiers: [.control, .shift])
        let oldCtrlOnly = KeyboardShortcuts.Shortcut(.space, modifiers: [.control])

        if let current = KeyboardShortcuts.getShortcut(for: .pushToTalk), current == oldCtrlOnly {
            // Migrate away from Ctrl+Space (conflicts with macOS input source switching)
            KeyboardShortcuts.setShortcut(defaultShortcut, for: .pushToTalk)
        } else if KeyboardShortcuts.getShortcut(for: .pushToTalk) == nil {
            KeyboardShortcuts.setShortcut(defaultShortcut, for: .pushToTalk)
        }

        floatingPanel?.shortcutHintLabel = currentPushToTalkLabel()
    }

    private func warmUpModel() {
        guard let transcription = transcriptionService,
              let settings = appState?.settings else { return }

        statusBarController?.updateIcon(state: .processing)
        statusBarMenu?.updateStatusLine("Loading model...")

        Task {
            do {
                await settings.syncTranscriptionSettings(to: transcription)
                try await transcription.loadModel(named: settings.selectedModelId)
                await transcription.warmUp()
                let runtimeModelID = await transcription.loadedModelID() ?? settings.selectedModelId
                await MainActor.run {
                    settings.activeModelId = runtimeModelID
                    self.statusBarController?.updateIcon(state: .idle)
                    self.statusBarMenu?.updateStatusLine("Ready")
                    Logger.model.info("Model warm-up complete")
                }
            } catch {
                await MainActor.run {
                    settings.activeModelId = ""
                    self.statusBarController?.updateIcon(state: .error)
                    self.statusBarMenu?.updateStatusLine("Model not loaded")
                    Logger.model.error("Model warm-up failed: \(error.localizedDescription)")
                }
            }
        }
    }

    private func prewarmLocalLLMModelsIfNeeded() {
        guard let settings = appState?.settings else { return }

        let endpoint = settings.normalizedLocalLLMEndpoint
        var modelsToWarm: [String] = []
        if settings.localLLMPolishEnabled {
            modelsToWarm.append(settings.normalizedLocalLLMPolishModel)
        }
        if settings.localLLMInsightsEnabled {
            modelsToWarm.append(settings.normalizedLocalLLMInsightsModel)
        }

        let uniqueModels = Array(Set(modelsToWarm)).sorted()
        guard !uniqueModels.isEmpty else { return }
        let aiLogger = Logger(subsystem: "com.orttaai.app", category: "ai")

        Task.detached(priority: .utility) {
            let client = OllamaClient()
            for model in uniqueModels {
                do {
                    let elapsedMs = try await client.warmModel(
                        baseURLString: endpoint,
                        model: model,
                        timeoutMs: 40_000
                    )
                    aiLogger.info("Prewarmed local LLM model [model=\(model), elapsedMs=\(elapsedMs)]")
                } catch {
                    aiLogger.debug("Local LLM prewarm skipped for \(model): \(error.localizedDescription)")
                }
            }
        }
    }

    private func activateRuntimeServicesIfNeeded() {
        guard !runtimeServicesStarted else { return }
        let hotkeyStarted = startHotkeyService()
        guard hotkeyStarted else {
            statusBarController?.updateIcon(state: .error)
            statusBarMenu?.updateStatusLine("Permission needed")
            windowManager?.showSetupWindow()
            return
        }

        runtimeServicesStarted = true
        floatingPanel?.show()
        warmUpModel()
        prewarmLocalLLMModelsIfNeeded()
    }

    private func observeShortcutChanges() {
        shortcutObserver = NotificationCenter.default.addObserver(
            forName: shortcutChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard
                let self = self,
                self.runtimeServicesStarted,
                let changedName = notification.userInfo?["name"] as? KeyboardShortcuts.Name,
                changedName.rawValue == KeyboardShortcuts.Name.pushToTalk.rawValue
            else {
                return
            }

            Logger.hotkey.info("Push-to-talk shortcut changed, restarting hotkey listener")
            self.isPushToTalkPressed = false
            self.floatingPanel?.shortcutHintLabel = self.currentPushToTalkLabel()
            let started = self.startHotkeyService()
            if !started {
                self.statusBarController?.updateIcon(state: .error)
                self.statusBarMenu?.updateStatusLine("Permission needed")
                self.windowManager?.showSetupWindow()
            }
        }
    }

    // MARK: - State Observation

    private func observeCoordinatorState() {
        guard let coordinator = coordinator else { return }
        coordinator.onStateChange = { [weak self] state, previousState in
            self?.handleStateChange(state, previousState: previousState)
        }
        handleStateChange(coordinator.state, previousState: nil)
    }

    private func handleStateChange(_ state: DictationCoordinator.State, previousState: DictationCoordinator.State?) {
        playDictationCueIfNeeded(state, previousState: previousState)

        switch state {
        case .idle:
            stopWaveformUpdates()
            statusBarController?.updateIcon(state: .idle)
            statusBarMenu?.updateStatusLine("Ready")
            floatingPanel?.transitionToHandle()
            postDictationSignal(.idle, message: "Ready")

        case .recording:
            startWaveformUpdates()
            statusBarController?.updateIcon(state: .recording)
            statusBarMenu?.updateStatusLine("Recording...")
            floatingPanel?.transitionToRecording(
                content: WaveformView(
                    audioLevel: coordinator?.audioLevel ?? 0,
                    elapsedSeconds: coordinator?.recordingElapsedSeconds ?? 0,
                    countdownSeconds: coordinator?.countdownSeconds,
                    onStop: { [weak self] in
                        self?.coordinator?.stopRecording()
                    }
                )
            )
            let targetAppName = coordinator?.targetAppName
            let countdownSeconds = coordinator?.countdownSeconds
            let elapsedSeconds = coordinator?.recordingElapsedSeconds
            lastRecordingTargetAppName = targetAppName
            lastRecordingCountdown = countdownSeconds
            lastRecordingElapsedSeconds = elapsedSeconds
            postDictationSignal(
                .recording,
                message: "Listening... Speak now.",
                targetAppName: targetAppName,
                countdownSeconds: countdownSeconds,
                elapsedRecordingSeconds: elapsedSeconds
            )

        case .processing(let estimate):
            stopWaveformUpdates()
            statusBarController?.updateIcon(state: .processing)
            statusBarMenu?.updateStatusLine("Processing...")
            let estimateText = estimate.map { "~\(Int($0))s to process" }
            floatingPanel?.transitionToProcessing(
                content: ProcessingIndicatorView(estimateText: estimateText, errorMessage: nil)
            )
            postDictationSignal(.processing, message: "Transcribing...")

        case .injecting:
            stopWaveformUpdates()
            statusBarController?.updateIcon(state: .processing)
            statusBarMenu?.updateStatusLine("Processing...")
            floatingPanel?.transitionToHandle()
            postDictationSignal(.injecting, message: "Pasting text...")

        case .error(let message):
            stopWaveformUpdates()
            statusBarController?.updateIcon(state: .error)
            statusBarMenu?.updateStatusLine("Error")
            floatingPanel?.transitionToError(
                content: ProcessingIndicatorView(estimateText: nil, errorMessage: message)
            )
            postDictationSignal(.error, message: message)
        }
    }

    private func startWaveformUpdates() {
        stopWaveformUpdates()
        lastWaveformLevelBucket = -1
        lastRecordingCountdown = coordinator?.countdownSeconds
        lastRecordingElapsedSeconds = coordinator?.recordingElapsedSeconds
        lastRecordingTargetAppName = coordinator?.targetAppName
        waveformUpdateTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self = self, let coordinator = self.coordinator else { break }
                guard case .recording = coordinator.state else { break }

                let level = max(0, min(coordinator.audioLevel, 1))
                let elapsedSeconds = coordinator.recordingElapsedSeconds ?? 0
                let countdownSeconds = coordinator.countdownSeconds
                let targetAppName = coordinator.targetAppName
                let bucket = Int((level * 24).rounded())
                let didWaveformChange = bucket != self.lastWaveformLevelBucket
                let didElapsedChange = elapsedSeconds != self.lastRecordingElapsedSeconds
                let didCountdownChange = countdownSeconds != self.lastRecordingCountdown
                let didSignalChange = didCountdownChange ||
                    targetAppName != self.lastRecordingTargetAppName ||
                    didElapsedChange

                if didWaveformChange || didElapsedChange || didCountdownChange {
                    self.lastWaveformLevelBucket = bucket
                    self.floatingPanel?.updateContent(
                        WaveformView(
                            audioLevel: level,
                            elapsedSeconds: elapsedSeconds,
                            countdownSeconds: countdownSeconds,
                            onStop: { [weak self] in
                                self?.coordinator?.stopRecording()
                            }
                        )
                    )
                }

                if didSignalChange {
                    self.lastRecordingCountdown = countdownSeconds
                    self.lastRecordingTargetAppName = targetAppName
                    self.postDictationSignal(
                        .recording,
                        message: "Listening... Speak now.",
                        targetAppName: targetAppName,
                        countdownSeconds: countdownSeconds,
                        elapsedRecordingSeconds: elapsedSeconds,
                        audioLevel: level
                    )
                }

                self.lastRecordingElapsedSeconds = elapsedSeconds

                try? await Task.sleep(nanoseconds: 33_000_000) // ~30fps while recording only
            }
        }
    }

    private func stopWaveformUpdates() {
        waveformUpdateTask?.cancel()
        waveformUpdateTask = nil
        lastWaveformLevelBucket = -1
        lastRecordingCountdown = nil
        lastRecordingElapsedSeconds = nil
        lastRecordingTargetAppName = nil
    }

    private func postDictationSignal(
        _ state: DictationStateSignal,
        message: String,
        targetAppName: String? = nil,
        countdownSeconds: Int? = nil,
        elapsedRecordingSeconds: Int? = nil,
        audioLevel: Float? = nil
    ) {
        var userInfo: [String: Any] = [
            DictationNotificationKey.state: state.rawValue,
            DictationNotificationKey.message: message
        ]
        if let targetAppName, !targetAppName.isEmpty {
            userInfo[DictationNotificationKey.targetAppName] = targetAppName
        }
        if let countdownSeconds {
            userInfo[DictationNotificationKey.countdownSeconds] = countdownSeconds
        }
        if let elapsedRecordingSeconds {
            userInfo[DictationNotificationKey.elapsedRecordingSeconds] = elapsedRecordingSeconds
        }
        if let audioLevel {
            userInfo[DictationNotificationKey.audioLevel] = audioLevel
        }

        NotificationCenter.default.post(
            name: .dictationStateDidChange,
            object: nil,
            userInfo: userInfo
        )
    }

    private func playDictationCueIfNeeded(_ state: DictationCoordinator.State, previousState: DictationCoordinator.State?) {
        switch state {
        case .recording:
            playSoundCue(named: recordingStartCue, volume: 0.6)
        case .processing:
            if case .recording = previousState {
                playSoundCue(named: recordingStopCue, volume: 0.45)
            }
        case .error:
            playSoundCue(named: errorCue, volume: 0.5)
        default:
            break
        }
    }

    private func playSoundCue(named cue: NSSound.Name, volume: Float) {
        guard let sound = NSSound(named: cue) else { return }
        activeCueSound?.stop()
        activeCueSound = sound
        sound.volume = volume
        sound.play()
    }

    private func currentPushToTalkLabel() -> String {
        guard let shortcut = KeyboardShortcuts.getShortcut(for: .pushToTalk) else {
            return "Ctrl + Shift + Space"
        }
        return formatShortcut(shortcut)
    }

    private func formatShortcut(_ shortcut: KeyboardShortcuts.Shortcut) -> String {
        var parts: [String] = []
        if shortcut.modifiers.contains(.control) {
            parts.append("Ctrl")
        }
        if shortcut.modifiers.contains(.shift) {
            parts.append("Shift")
        }
        if shortcut.modifiers.contains(.option) {
            parts.append("Option")
        }
        if shortcut.modifiers.contains(.command) {
            parts.append("Cmd")
        }

        parts.append(displayName(for: shortcut.key))
        return parts.joined(separator: " + ")
    }

    private func displayName(for key: KeyboardShortcuts.Key?) -> String {
        guard let key else {
            return "Space"
        }

        let bareShortcut = KeyboardShortcuts.Shortcut(key, modifiers: [])
        if let keyEquivalent = bareShortcut.nsMenuItemKeyEquivalent {
            switch keyEquivalent {
            case " ":
                return "Space"
            case "\t":
                return "Tab"
            case "\r":
                return "Return"
            default:
                return keyEquivalent.uppercased()
            }
        }

        return "Key \(key.rawValue)"
    }
}
