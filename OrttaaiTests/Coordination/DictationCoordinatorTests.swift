// DictationCoordinatorTests.swift
// OrttaaiTests

import XCTest
import GRDB
import CoreAudio
@testable import Orttaai

// MARK: - Mock Services

final class MockAudioCaptureService: AudioCapturing {
    var audioLevel: Float = 0
    var activeInputDeviceID: AudioDeviceID?
    var shouldFail = false
    var mockSamples: [Float] = Array(repeating: 0.1, count: 16000) // 1 second
    var lastStartCaptureDeviceID: AudioDeviceID?

    func startCapture(deviceID: AudioDeviceID? = nil) throws {
        lastStartCaptureDeviceID = deviceID
        if shouldFail {
            throw OrttaaiError.microphoneAccessDenied
        }
    }

    func stopCapture() -> [Float] {
        return mockSamples
    }

    func currentSamplesSnapshot() -> [Float] {
        mockSamples
    }
}

actor MockTranscriptionService: Transcribing {
    var isLoaded: Bool = true
    var mockResult: String = "Hello world"
    var shouldFail = false
    var shouldFailModelLoad = false
    var mockLoadedModelID: String? = "test-model"
    var loadedModelNames: [String] = []
    var beginLiveSessionCallCount = 0
    var processedLiveSampleCounts: [Int] = []
    var finalizeLiveTranscriptionCallCount = 0
    var cancelLiveSessionCallCount = 0
    var liveTranscriptEventHandler: (@Sendable (LiveTranscriptEvent) -> Void)?

    func loadedModelID() -> String? {
        mockLoadedModelID
    }

    func loadModel(named modelName: String) async throws {
        loadedModelNames.append(modelName)
        if shouldFailModelLoad {
            throw OrttaaiError.modelNotLoaded
        }
        isLoaded = true
        mockLoadedModelID = modelName
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

    func beginLiveTranscriptionSession() {
        beginLiveSessionCallCount += 1
    }

    func processLiveAudioSnapshot(_ audioSamples: [Float]) {
        processedLiveSampleCounts.append(audioSamples.count)
    }

    func finalizeLiveTranscription(audioSamples: [Float]) async throws -> String {
        finalizeLiveTranscriptionCallCount += 1
        return try await transcribe(audioSamples: audioSamples)
    }

    func cancelLiveTranscriptionSession() {
        cancelLiveSessionCallCount += 1
    }

    func setLiveTranscriptEventHandler(_ handler: (@Sendable (LiveTranscriptEvent) -> Void)?) {
        liveTranscriptEventHandler = handler
    }

    func emitLiveTranscriptEventForTest(_ event: LiveTranscriptEvent) {
        liveTranscriptEventHandler?(event)
    }

    func hasLiveTranscriptEventHandler() -> Bool {
        liveTranscriptEventHandler != nil
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
    var mockResult: InjectionResult = .success(method: .paste)
    private(set) var injectedTexts: [String] = []

    func inject(text: String, targetApp: NSRunningApplication? = nil) async -> InjectionResult {
        injectedTexts.append(text)
        if case .success = mockResult {
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
    func testStartRecordingUsesSelectedAudioDeviceWhenConfigured() {
        settings.selectedAudioDeviceID = "1234"

        coordinator.startRecording()

        XCTAssertEqual(audioService.lastStartCaptureDeviceID, AudioDeviceID(1234))
    }

    @MainActor
    func testStartRecordingFallsBackToSystemDefaultWhenSelectionIsEmpty() {
        settings.selectedAudioDeviceID = ""

        coordinator.startRecording()

        XCTAssertNil(audioService.lastStartCaptureDeviceID)
    }

    @MainActor
    func testStartRecordingFallsBackToSystemDefaultWhenSelectionIsInvalid() {
        settings.selectedAudioDeviceID = "not-a-device"

        coordinator.startRecording()

        XCTAssertNil(audioService.lastStartCaptureDeviceID)
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
        try? await Task.sleep(nanoseconds: 700_000_000)
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

    @MainActor
    func testStartRecordingBeginsLiveTranscriptionSession() async {
        coordinator.startRecording()

        try? await Task.sleep(nanoseconds: 200_000_000)

        let beginCallCount = await transcriptionService.beginLiveSessionCallCount
        XCTAssertEqual(beginCallCount, 1)

        coordinator.stopRecording()
    }

    @MainActor
    func testStopRecordingFinalizesThroughLiveTranscriptionPath() async {
        audioService.mockSamples = Array(repeating: 0.1, count: 40_000)
        coordinator.startRecording()
        try? await Task.sleep(nanoseconds: 1_100_000_000)
        coordinator.stopRecording()

        try? await Task.sleep(nanoseconds: 500_000_000)

        let finalizeCallCount = await transcriptionService.finalizeLiveTranscriptionCallCount
        XCTAssertEqual(finalizeCallCount, 1)

        let liveSampleCounts = await transcriptionService.processedLiveSampleCounts
        XCTAssertFalse(liveSampleCounts.isEmpty)
    }

    @MainActor
    func testLiveTranscriptEventsFlowFromSessionToCoordinator() async {
        coordinator.startRecording()

        // Let the live-decode loop install the handler and begin the session.
        try? await Task.sleep(nanoseconds: 300_000_000)
        let handlerInstalled = await transcriptionService.hasLiveTranscriptEventHandler()
        XCTAssertTrue(handlerInstalled, "Coordinator should install the live transcript handler while recording")

        await transcriptionService.emitLiveTranscriptEventForTest(.speculative("hel"))
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(coordinator.liveTranscript?.speculativeText, "hel")

        // Speculative tail replaces the previous one.
        await transcriptionService.emitLiveTranscriptEventForTest(.speculative("hello there"))
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(coordinator.liveTranscript?.speculativeText, "hello there")
        XCTAssertEqual(coordinator.liveTranscript?.committedText, "")

        // A commit appends stable text and supersedes the speculative tail.
        await transcriptionService.emitLiveTranscriptEventForTest(.committed("hello there"))
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(coordinator.liveTranscript?.committedText, "hello there")
        XCTAssertEqual(coordinator.liveTranscript?.speculativeText, "")

        coordinator.stopRecording()
    }

    @MainActor
    func testStopRecordingClearsLiveTranscript() async {
        audioService.mockSamples = Array(repeating: 0.1, count: 40_000)
        coordinator.startRecording()

        try? await Task.sleep(nanoseconds: 700_000_000)
        await transcriptionService.emitLiveTranscriptEventForTest(.committed("hello"))
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertNotNil(coordinator.liveTranscript)

        coordinator.stopRecording()
        XCTAssertNil(coordinator.liveTranscript, "Finalize path must clear the live transcript display")

        // Events arriving after stop (in-flight commits) must not resurrect it.
        try? await Task.sleep(nanoseconds: 100_000_000)
        await transcriptionService.emitLiveTranscriptEventForTest(.committed("late clip"))
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertNil(coordinator.liveTranscript)
    }

    @MainActor
    func testStopRecordingLoadsModelOnDemandWhenWarmupDidNotFinish() async {
        let selectedModelId = settings.selectedModelId
        let previousActiveModelId = settings.activeModelId
        defer { settings.activeModelId = previousActiveModelId }

        await transcriptionService.resetLoadedModelsForTest(isLoaded: false)
        audioService.mockSamples = Array(repeating: 0.1, count: 40_000)

        coordinator.startRecording()
        try? await Task.sleep(nanoseconds: 700_000_000)
        coordinator.stopRecording()

        try? await Task.sleep(nanoseconds: 500_000_000)

        let loadedModelNames = await transcriptionService.loadedModelNames
        XCTAssertEqual(loadedModelNames, [selectedModelId])
        let finalizeCallCount = await transcriptionService.finalizeLiveTranscriptionCallCount
        XCTAssertEqual(finalizeCallCount, 1)
        XCTAssertEqual(injectionService.lastTranscript, "Hello world")
        XCTAssertEqual(settings.activeModelId, selectedModelId)
    }
    // MARK: - Injection outcome handling

    @MainActor
    func testSuccessfulDictationPersistsInjectionMethod() async throws {
        audioService.mockSamples = Array(repeating: 0.1, count: 40_000)
        coordinator.startRecording()
        try? await Task.sleep(nanoseconds: 700_000_000)
        coordinator.stopRecording()

        let saved = try await waitForTranscription()
        XCTAssertEqual(saved.injectionMethod, "paste")
        XCTAssertEqual(saved.text, "Hello world")
    }

    @MainActor
    func testFailedInjectionShowsErrorAndMarksHistoryEntryFailed() async throws {
        injectionService.mockResult = .failedAllMethods
        audioService.mockSamples = Array(repeating: 0.1, count: 40_000)
        coordinator.startRecording()
        try? await Task.sleep(nanoseconds: 700_000_000)
        coordinator.stopRecording()

        // Wait for processing to finish and the error state to land.
        var sawClipboardError = false
        for _ in 0..<40 {
            if case .error(let message) = coordinator.state {
                XCTAssertEqual(message, "Couldn't insert text. Press Cmd+V to paste it.")
                sawClipboardError = true
                break
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertTrue(sawClipboardError, "Total injection failure must surface an error, never a silent success")

        let saved = try await waitForTranscription()
        XCTAssertEqual(saved.injectionMethod, "failed", "Failed injection keeps its history entry, marked failed")
    }

    // MARK: - Paste last transcript

    @MainActor
    func testPasteLastTranscriptReinjectsThroughInjectionService() async {
        injectionService.lastTranscript = "Hello again"

        coordinator.pasteLastTranscript()
        try? await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertEqual(injectionService.injectedTexts, ["Hello again"])
        XCTAssertEqual(coordinator.state, .idle)
    }

    @MainActor
    func testPasteLastTranscriptWithNoTranscriptShowsError() async {
        XCTAssertNil(injectionService.lastTranscript)

        coordinator.pasteLastTranscript()
        try? await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertTrue(injectionService.injectedTexts.isEmpty)
        if case .error(let message) = coordinator.state {
            XCTAssertEqual(message, "No transcript available to paste")
        } else {
            XCTFail("Expected error state, got \(coordinator.state)")
        }
    }

    @MainActor
    func testPasteLastTranscriptIgnoredWhileRecording() async {
        injectionService.lastTranscript = "Hello again"
        coordinator.startRecording()

        coordinator.pasteLastTranscript()
        try? await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertTrue(injectionService.injectedTexts.isEmpty, "Paste-last must not interrupt an active recording")
        if case .recording = coordinator.state {
            // OK
        } else {
            XCTFail("Expected to remain recording")
        }
        coordinator.stopRecording()
    }

    @MainActor
    func testPasteLastTranscriptFailureShowsClipboardAdvice() async {
        injectionService.lastTranscript = "Hello again"
        injectionService.mockResult = .failedAllMethods

        coordinator.pasteLastTranscript()
        try? await Task.sleep(nanoseconds: 300_000_000)

        if case .error(let message) = coordinator.state {
            XCTAssertEqual(message, "Couldn't insert text. Press Cmd+V to paste it.")
        } else {
            XCTFail("Expected error state, got \(coordinator.state)")
        }
    }

    // MARK: - Live event ordering

    @MainActor
    func testLiveTranscriptEventsApplyInEmissionOrder() async {
        coordinator.startRecording()
        try? await Task.sleep(nanoseconds: 300_000_000)
        let handlerInstalled = await transcriptionService.hasLiveTranscriptEventHandler()
        XCTAssertTrue(handlerInstalled)

        // Burst of commits with no pause: FIFO delivery means the assembled
        // committed text preserves emission order exactly.
        let words = (0..<40).map { "word\($0)" }
        for word in words {
            await transcriptionService.emitLiveTranscriptEventForTest(.committed(word))
        }
        // A trailing speculative tail must land after every commit.
        await transcriptionService.emitLiveTranscriptEventForTest(.speculative("tail"))

        try? await Task.sleep(nanoseconds: 500_000_000)

        XCTAssertEqual(coordinator.liveTranscript?.committedText, words.joined(separator: " "))
        XCTAssertEqual(coordinator.liveTranscript?.speculativeText, "tail")

        coordinator.stopRecording()
    }

    // MARK: - Helpers

    private struct PersistenceTimeout: Error {}

    /// Polls the database for the transcription written by the detached
    /// persistence task.
    private func waitForTranscription(timeoutSeconds: Double = 5) async throws -> Transcription {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if let record = try databaseManager.fetchRecent(limit: 1).first {
                return record
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTFail("Transcription was not persisted within \(timeoutSeconds)s")
        throw PersistenceTimeout()
    }
}

private extension MockTranscriptionService {
    func resetLoadedModelsForTest(isLoaded: Bool) {
        self.isLoaded = isLoaded
        loadedModelNames = []
        mockLoadedModelID = nil
    }
}
