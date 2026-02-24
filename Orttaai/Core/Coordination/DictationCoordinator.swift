// DictationCoordinator.swift
// Orttaai

import Foundation
import AppKit
import os

@Observable
final class DictationCoordinator {
    enum State: Equatable {
        case idle
        case recording(startTime: Date)
        case processing(estimatedDuration: TimeInterval?)
        case injecting
        case error(message: String)

        static func == (lhs: State, rhs: State) -> Bool {
            switch (lhs, rhs) {
            case (.idle, .idle), (.injecting, .injecting):
                return true
            case (.recording(let a), .recording(let b)):
                return a == b
            case (.processing(let a), .processing(let b)):
                return a == b
            case (.error(let a), .error(let b)):
                return a == b
            default:
                return false
            }
        }
    }

    var onStateChange: ((State, State?) -> Void)?

    private(set) var state: State = .idle {
        didSet {
            guard state != oldValue else { return }
            onStateChange?(state, oldValue)
        }
    }
    private(set) var countdownSeconds: Int?

    private let audioService: any AudioCapturing
    private let transcriptionService: any Transcribing
    private let textProcessor: TextProcessor
    private let injectionService: any TextInjecting
    private let databaseManager: DatabaseManager
    private let settings: AppSettings

    private var maxDuration: TimeInterval {
        TimeInterval(settings.maxRecordingDuration)
    }
    private var countdownStart: TimeInterval {
        max(0, maxDuration - 10)
    }
    private let minDuration: TimeInterval = 0.5

    private var capTimerTask: Task<Void, Never>?
    private var processingTask: Task<Void, Never>?
    private var targetApp: NSRunningApplication?

    init(
        audioService: any AudioCapturing,
        transcriptionService: any Transcribing,
        textProcessor: TextProcessor,
        injectionService: any TextInjecting,
        databaseManager: DatabaseManager,
        settings: AppSettings
    ) {
        self.audioService = audioService
        self.transcriptionService = transcriptionService
        self.textProcessor = textProcessor
        self.injectionService = injectionService
        self.databaseManager = databaseManager
        self.settings = settings
    }

    var audioLevel: Float {
        audioService.audioLevel
    }

    // MARK: - Public API

    func startRecording() {
        guard case .idle = state else {
            Logger.dictation.info("Ignoring startRecording — not idle (state: \(String(describing: self.state)))")
            return
        }

        do {
            // Capture the target app NOW, before the floating panel appears
            targetApp = NSWorkspace.shared.frontmostApplication
            try audioService.startCapture()
            state = .recording(startTime: Date())
            startCapTimer()
            Logger.dictation.info("Recording started")
        } catch {
            state = .error(message: "Microphone access needed")
            autoDismissError()
            Logger.dictation.error("Failed to start recording: \(error.localizedDescription)")
        }
    }

    func stopRecording() {
        guard case .recording(let startTime) = state else {
            Logger.dictation.info("Ignoring stopRecording — not recording")
            return
        }

        // Cancel cap timer
        capTimerTask?.cancel()
        capTimerTask = nil
        countdownSeconds = nil

        // Stop capture
        let samples = audioService.stopCapture()
        let duration = Date().timeIntervalSince(startTime)

        // Check minimum duration
        guard duration >= minDuration else {
            state = .idle
            databaseManager.logSkippedRecording(duration: duration)
            Logger.dictation.info("Recording too short (\(duration, format: .fixed(precision: 2))s), skipping")
            return
        }

        let estimatedProcessing = estimateProcessingTime(duration)
        state = .processing(estimatedDuration: settings.showProcessingEstimate ? estimatedProcessing : nil)

        Logger.dictation.info("Recording stopped, duration: \(duration, format: .fixed(precision: 2))s, processing...")

        processingTask = Task { @MainActor [weak self] in
            guard let self = self else { return }
            await self.processRecording(samples: samples, recordingDurationMs: Int(duration * 1000))
        }
    }

    // MARK: - Private

    @MainActor
    private func processRecording(
        samples: [Float],
        recordingDurationMs: Int
    ) async {
        let appName = NSWorkspace.shared.frontmostAppName
        let appBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let processingStart = CFAbsoluteTimeGetCurrent()
        var settingsSyncMs: Int?
        var transcriptionMs: Int?
        var textProcessingMs: Int?
        var injectionMs: Int?
        var injectionTelemetry: InjectionTelemetry?

        do {
            // Sync transcription settings before transcribing
            let settingsSyncStart = CFAbsoluteTimeGetCurrent()
            let requestedLanguage = settings.dictationLanguage
            let effectiveLanguage = (settings.lowLatencyModeEnabled && requestedLanguage == "auto")
                ? "en"
                : requestedLanguage
            await transcriptionService.updateSettings(
                language: effectiveLanguage,
                computeMode: settings.computeMode,
                lowLatencyMode: settings.lowLatencyModeEnabled,
                decodingPreferences: settings.decodingPreferences
            )
            settingsSyncMs = Int((CFAbsoluteTimeGetCurrent() - settingsSyncStart) * 1000)

            // Transcribe
            let transcriptionStart = CFAbsoluteTimeGetCurrent()
            let transcript = try await transcriptionService.transcribe(audioSamples: samples)
            transcriptionMs = Int((CFAbsoluteTimeGetCurrent() - transcriptionStart) * 1000)

            // Process through text processor
            let textProcessStart = CFAbsoluteTimeGetCurrent()
            let input = TextProcessorInput(
                rawTranscript: transcript,
                targetApp: appName,
                mode: .raw
            )
            let output = try await textProcessor.process(input)
            textProcessingMs = Int((CFAbsoluteTimeGetCurrent() - textProcessStart) * 1000)

            // Inject into the app that was focused when the user started recording
            state = .injecting
            injectionService.lowLatencyModeEnabled = settings.lowLatencyModeEnabled
            let injectionStart = CFAbsoluteTimeGetCurrent()
            let result = await injectionService.inject(text: output.text, targetApp: self.targetApp)
            injectionMs = Int((CFAbsoluteTimeGetCurrent() - injectionStart) * 1000)
            injectionTelemetry = injectionService.lastInjectionTelemetry

            let processingMs = Int((CFAbsoluteTimeGetCurrent() - processingStart) * 1000)

            switch result {
            case .success:
                let runtimeModelID = await transcriptionService.loadedModelID()
                let resolvedModelID: String = {
                    if let runtimeModelID, !runtimeModelID.isEmpty {
                        return runtimeModelID
                    }
                    let activeModelID = settings.activeModelId.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !activeModelID.isEmpty {
                        return activeModelID
                    }
                    return settings.selectedModelId
                }()
                settings.activeModelId = resolvedModelID

                let textToSave = output.text
                let databaseManager = self.databaseManager
                let latency = DictationLatencyTelemetry(
                    settingsSyncMs: settingsSyncMs,
                    transcriptionMs: transcriptionMs,
                    textProcessingMs: textProcessingMs,
                    injectionMs: injectionMs,
                    appActivationMs: injectionTelemetry?.appActivationMs,
                    clipboardRestoreDelayMs: injectionTelemetry?.clipboardRestoreDelayMs
                )
                DispatchQueue.global(qos: .utility).async {
                    try? databaseManager.saveTranscription(
                        text: textToSave,
                        appName: appName,
                        bundleID: appBundleID,
                        recordingMs: recordingDurationMs,
                        processingMs: processingMs,
                        modelId: resolvedModelID,
                        latency: latency
                    )
                }
                maybeStartFastFirstPrefetch(afterSuccessfulDictationWith: resolvedModelID)
                state = .idle
                Logger.dictation.info(
                    "Latency telemetry (ms): settings=\(settingsSyncMs ?? -1), transcribe=\(transcriptionMs ?? -1), process=\(textProcessingMs ?? -1), inject=\(injectionMs ?? -1), activate=\(injectionTelemetry?.appActivationMs ?? -1), restoreDelay=\(injectionTelemetry?.clipboardRestoreDelayMs ?? -1), pipeline=\(processingMs)"
                )
                Logger.dictation.info("Dictation complete: \(output.text.prefix(50))... (\(processingMs)ms)")

            case .blockedSecureField:
                state = .error(message: "Can't dictate into password fields")
                autoDismissError()

            case .noTranscript:
                state = .error(message: "No transcript available to paste")
                autoDismissError()
            }

        } catch {
            Logger.dictation.error("Processing failed: \(error.localizedDescription)")
            state = .error(message: "Couldn't transcribe. Try again.")
            autoDismissError()
        }
    }

    private func maybeStartFastFirstPrefetch(afterSuccessfulDictationWith activeModelId: String) {
        guard settings.fastFirstOnboardingEnabled else { return }
        guard !settings.fastFirstPrefetchStarted else { return }

        let recommendedModelId = ModelManager.normalizedModelID(
            settings.fastFirstRecommendedModelId.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        guard !recommendedModelId.isEmpty else { return }
        guard recommendedModelId != ModelManager.normalizedModelID(activeModelId) else { return }

        settings.fastFirstPrefetchStarted = true
        settings.fastFirstPrefetchReady = false
        settings.fastFirstPrefetchErrorMessage = ""
        NotificationCenter.default.post(name: .fastFirstUpgradeAvailabilityDidChange, object: nil)

        Task.detached(priority: .utility) {
            let outcome = await ModelManager.prefetchModelIfNeeded(recommendedModelId)
            await MainActor.run {
                let appSettings = AppSettings()
                switch outcome {
                case .alreadyAvailable, .downloaded:
                    appSettings.fastFirstPrefetchReady = true
                    appSettings.fastFirstPrefetchErrorMessage = ""
                case .failed(let message):
                    appSettings.fastFirstPrefetchStarted = false
                    appSettings.fastFirstPrefetchErrorMessage = message
                }
                NotificationCenter.default.post(name: .fastFirstUpgradeAvailabilityDidChange, object: nil)
            }
        }
    }

    private func startCapTimer() {
        capTimerTask = Task { @MainActor [weak self] in
            guard let self = self else { return }

            // Wait until countdown start (35s)
            try? await Task.sleep(nanoseconds: UInt64(self.countdownStart * 1_000_000_000))

            guard !Task.isCancelled else { return }

            // Start countdown from 10s remaining
            let remainingSeconds = Int(self.maxDuration - self.countdownStart)
            for i in stride(from: remainingSeconds, through: 1, by: -1) {
                guard !Task.isCancelled else { return }
                self.countdownSeconds = i
                try? await Task.sleep(nanoseconds: 1_000_000_000) // 1 second
            }

            guard !Task.isCancelled else { return }

            // Time's up — stop recording
            Logger.dictation.info("Cap timer fired at \(self.maxDuration)s — stopping recording")
            self.stopRecording()
        }
    }

    func estimateProcessingTime(_ recordingDuration: TimeInterval) -> TimeInterval {
        // Rough estimate: ~0.3x recording duration on M4, ~0.5x on M1
        let factor = 0.3
        return max(1.0, recordingDuration * factor)
    }

    private func autoDismissError() {
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000) // 2 seconds
            guard let self = self, case .error = self.state else { return }
            self.state = .idle
        }
    }
}
