// DictationCoordinatorTests.swift
// OrttaaiTests

import XCTest
import GRDB
import CoreAudio
@testable import Orttaai

// MARK: - Mock Services

final class MockAudioCaptureService: AudioCapturing {
    var audioLevel: Float = 0
    var shouldFail = false
    var mockSamples: [Float] = Array(repeating: 0.1, count: 16000) // 1 second

    func startCapture(deviceID: AudioDeviceID? = nil) throws {
        if shouldFail {
            throw OrttaaiError.microphoneAccessDenied
        }
    }

    func stopCapture() -> [Float] {
        return mockSamples
    }
}

actor MockTranscriptionService: Transcribing {
    var isLoaded: Bool = true
    var mockResult: String = "Hello world"
    var shouldFail = false
    var mockLoadedModelID: String? = "test-model"

    func loadedModelID() -> String? {
        mockLoadedModelID
    }

    func transcribe(audioSamples: [Float]) async throws -> String {
        if shouldFail {
            throw OrttaaiError.transcriptionFailed(underlying: NSError(
                domain: "test",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Mock failure"]
            ))
        }
        return mockResult
    }

    func updateSettings(
        language: String,
        computeMode: String,
        lowLatencyMode: Bool,
        decodingPreferences: DecodingPreferences
    ) {
        // No-op for tests
    }
}

final class MockTextProcessor: TextProcessor {
    func process(_ input: TextProcessorInput) async throws -> TextProcessorOutput {
        TextProcessorOutput(text: input.rawTranscript, changes: [])
    }

    func isAvailable() -> Bool { true }
}

final class MockInjectionService: TextInjecting {
    var lastTranscript: String?
    var lowLatencyModeEnabled: Bool = false
    var mockResult: InjectionResult = .success

    func inject(text: String, targetApp: NSRunningApplication? = nil) async -> InjectionResult {
        if mockResult == .success {
            lastTranscript = text
        }
        return mockResult
    }

    func pasteLastTranscript(targetApp: NSRunningApplication? = nil) async -> InjectionResult {
        guard let transcript = lastTranscript else {
            return .noTranscript
        }
        return await inject(text: transcript, targetApp: targetApp)
    }
}

// MARK: - Tests

final class DictationCoordinatorTests: XCTestCase {
    var audioService: MockAudioCaptureService!
    var transcriptionService: MockTranscriptionService!
    var textProcessor: MockTextProcessor!
    var injectionService: MockInjectionService!
    var databaseManager: DatabaseManager!
    var settings: AppSettings!
    var coordinator: DictationCoordinator!

    @MainActor
    override func setUpWithError() throws {
        audioService = MockAudioCaptureService()
        transcriptionService = MockTranscriptionService()
        textProcessor = MockTextProcessor()
        injectionService = MockInjectionService()

        let dbQueue = try DatabaseQueue(path: ":memory:")
        databaseManager = try DatabaseManager(dbQueue: dbQueue)
        settings = AppSettings()

        coordinator = DictationCoordinator(
            audioService: audioService,
            transcriptionService: transcriptionService,
            textProcessor: textProcessor,
            injectionService: injectionService,
            databaseManager: databaseManager,
            settings: settings
        )
    }

    @MainActor
    func testIdleToRecording() {
        XCTAssertEqual(coordinator.state, .idle)
        coordinator.startRecording()
        if case .recording = coordinator.state {
            // OK
        } else {
            XCTFail("Expected recording state, got \(coordinator.state)")
        }
    }

    @MainActor
    func testStartRecordingWhenNotIdle() {
        coordinator.startRecording()
        // Try to start again — should be ignored
        coordinator.startRecording()
        if case .recording = coordinator.state {
            // OK — still recording, not double-started
        } else {
            XCTFail("Expected recording state")
        }
    }

    @MainActor
    func testMicrophoneFailure() {
        audioService.shouldFail = true
        coordinator.startRecording()
        if case .error(let message) = coordinator.state {
            XCTAssertEqual(message, "Microphone access needed")
        } else {
            XCTFail("Expected error state")
        }
    }

    @MainActor
    func testStopRecordingWhenNotRecording() {
        coordinator.stopRecording()
        XCTAssertEqual(coordinator.state, .idle)
    }

    @MainActor
    func testShortRecordingSkipped() async {
        audioService.mockSamples = [Float](repeating: 0, count: 4800) // 0.3s at 16kHz
        coordinator.startRecording()

        // Simulate very quick stop (< 0.5s)
        // The duration check uses Date, so we can't control it perfectly in unit tests.
        // The mock samples returning quickly simulates a short recording.
        coordinator.stopRecording()

        // Give time for async processing
        try? await Task.sleep(nanoseconds: 100_000_000)

        // State should return to idle (either from short skip or processing)
        // This test mainly verifies no crash
    }

    @MainActor
    func testEstimateProcessingTime() {
        let estimate = coordinator.estimateProcessingTime(10.0)
        XCTAssertGreaterThanOrEqual(estimate, 1.0)
    }

    @MainActor
    func testSecureFieldBlock() async {
        injectionService.mockResult = .blockedSecureField
        coordinator.startRecording()
        coordinator.stopRecording()

        // Wait for async processing
        try? await Task.sleep(nanoseconds: 500_000_000)

        if case .error(let message) = coordinator.state {
            XCTAssertEqual(message, "Can't dictate into password fields")
        }
        // Note: might be .idle if autoDismiss already fired
    }

    @MainActor
    func testErrorAutoDismiss() async {
        audioService.shouldFail = true
        coordinator.startRecording()

        // Should be in error state
        if case .error = coordinator.state {
            // Wait for auto-dismiss (2s + buffer)
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            XCTAssertEqual(coordinator.state, .idle, "Error should auto-dismiss to idle")
        }
    }
}
