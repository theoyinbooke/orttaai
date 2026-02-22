// DictationCoordinator.swift
// Uttrai

import Foundation
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

    private(set) var state: State = .idle
    private(set) var countdownSeconds: Int?

    private let audioService: AudioCaptureService
    private let transcriptionService: TranscriptionService
    private let textProcessor: TextProcessor
    private let injectionService: TextInjectionService
    private let databaseManager: DatabaseManager
    private let settings: AppSettings

    private let maxDuration: TimeInterval = 45
    private let countdownStart: TimeInterval = 35
    private let minDuration: TimeInterval = 0.5

    private var capTimerTask: Task<Void, Never>?
    private var processingTask: Task<Void, Never>?

    init(
        audioService: AudioCaptureService,
        transcriptionService: TranscriptionService,
        textProcessor: TextProcessor,
        injectionService: TextInjectionService,
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
            await self.processRecording(
                samples: samples,
                recordingDurationMs: Int(duration * 1000),
                startTime: startTime
            )
        }
    }

    // MARK: - Private

    @MainActor
    private func processRecording(
        samples: [Float],
        recordingDurationMs: Int,
        startTime: Date
    ) async {
        let appName = NSWorkspace.shared.frontmostAppName
        let appBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let processingStart = CFAbsoluteTimeGetCurrent()

        do {
            // Transcribe
            let transcript = try await transcriptionService.transcribe(audioSamples: samples)

            // Process through text processor
            let input = TextProcessorInput(
                rawTranscript: transcript,
                targetApp: appName,
                mode: .raw
            )
            let output = try await textProcessor.process(input)

            // Inject
            state = .injecting
            let result = await injectionService.inject(text: output.text)

            let processingMs = Int((CFAbsoluteTimeGetCurrent() - processingStart) * 1000)

            switch result {
            case .success:
                // Save to database
                try? databaseManager.saveTranscription(
                    text: output.text,
                    appName: appName,
                    bundleID: appBundleID,
                    recordingMs: recordingDurationMs,
                    processingMs: processingMs,
                    modelId: settings.selectedModelId
                )
                state = .idle
                Logger.dictation.info("Dictation complete: \(output.text.prefix(50))... (\(processingMs)ms)")

            case .blockedSecureField:
                state = .error(message: "Can't dictate into password fields")
                autoDismissError()
            }

        } catch {
            Logger.dictation.error("Processing failed: \(error.localizedDescription)")
            state = .error(message: "Couldn't transcribe. Try again.")
            autoDismissError()
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
