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
    private(set) var requestedSnapshotLimits: [Int?] = []

    func startCapture(deviceID: AudioDeviceID? = nil) throws {
        lastStartCaptureDeviceID = deviceID
        if shouldFail {
            throw OrttaaiError.microphoneAccessDenied
        }
    }

    func stopCapture() -> [Float] {
        return mockSamples
    }

    func currentSamplesSnapshot(maxSamples: Int? = nil) -> [Float] {
        requestedSnapshotLimits.append(maxSamples)
        guard let maxSamples else { return mockSamples }
        return Array(mockSamples.suffix(max(0, maxSamples)))
    }
}

actor MockTranscriptionService: Transcribing {
    var isLoaded: Bool = true
    var mockResult: String = "Hello world"
    var shouldFail = false
    /// Artificial transcription latency so tests can observe the coordinator
    /// while it is genuinely in the processing state.
    var transcribeDelayNs: UInt64 = 0
    var shouldFailModelLoad = false
    var mockLoadedModelID: String? = "test-model"
    var loadedModelNames: [String] = []
    var transcribeCallCount = 0
    var beginLiveSessionCallCount = 0
    var processedLiveSampleCounts: [Int] = []
    var finalizeLiveTranscriptionCallCount = 0
    var cancelLiveSessionCallCount = 0
    var liveTranscriptEventHandler: (@Sendable (LiveTranscriptEvent) -> Void)?
    var vocabularyBiasTermsHistory: [[String]] = []

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
        transcribeCallCount += 1
        if transcribeDelayNs > 0 {
            try? await Task.sleep(nanoseconds: transcribeDelayNs)
        }
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

    func setVocabularyBias(terms: [String]) {
        vocabularyBiasTermsHistory.append(terms)
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

final class MockTextProcessor: TextProcessor, VocabularyBiasProviding {
    var mockVocabularyBiasTerms: [String] = []
    private(set) var inputs: [TextProcessorInput] = []

    func process(_ input: TextProcessorInput) async throws -> TextProcessorOutput {
        inputs.append(input)
        return TextProcessorOutput(text: input.rawTranscript, changes: [])
    }

    func isAvailable() -> Bool { true }

    func vocabularyBiasTerms() -> [String] {
        mockVocabularyBiasTerms
    }
}

final class MockInjectionService: TextInjecting {
    var lowLatencyModeEnabled: Bool = false
    var mockResult: InjectionResult = .success(method: .paste)
    var onInject: ((String) -> Void)?
    private(set) var injectedTexts: [String] = []

    func inject(text: String, targetApp: NSRunningApplication? = nil) async -> InjectionResult {
        onInject?(text)
        injectedTexts.append(text)
        return mockResult
    }
}

/// History store whose writes always fail, for exercising the bounded-retry
/// failure path end to end.
final class FailingHistoryStore: TranscriptionHistoryStoring {
    struct WriteError: Error {}

    private let lock = NSLock()
    private var _saveAttempts = 0

    var saveAttempts: Int {
        lock.lock()
        defer { lock.unlock() }
        return _saveAttempts
    }

    func saveTranscriptionEntry(
        text: String,
        appName: String?,
        bundleID: String?,
        recordingMs: Int,
        processingMs: Int,
        modelId: String,
        latency: DictationLatencyTelemetry,
        injectionMethod: String?
    ) throws -> Int64 {
        lock.lock()
        _saveAttempts += 1
        lock.unlock()
        throw WriteError()
    }

    func completeTranscriptionEntry(
        id: Int64,
        processingMs: Int,
        latency: DictationLatencyTelemetry,
        injectionMethod: String?
    ) throws {
        throw WriteError()
    }

    func saveEditCommandEntry(
        text: String,
        instruction: String,
        appName: String?,
        bundleID: String?,
        recordingMs: Int,
        processingMs: Int,
        modelId: String,
        latency: DictationLatencyTelemetry,
        injectionMethod: String
    ) throws {
        lock.lock()
        _saveAttempts += 1
        lock.unlock()
        throw WriteError()
    }

    func logSkippedRecording(duration: TimeInterval) {}
}

/// Scripted selection capture so edit-command orchestration is deterministic.
final class MockSelectionCapture: SelectionCapturing {
    var result: CapturedSelection?
    /// When set, wins over `result` — scripts non-captured outcomes
    /// (e.g. .blockedSecureField) without churning existing call sites.
    var scriptedResult: SelectionCaptureResult?
    /// Extra delay before returning, to exercise the capture-in-flight window.
    var delayNs: UInt64 = 0
    private(set) var captureCallCount = 0

    func captureSelection(processIdentifier: pid_t?) async -> SelectionCaptureResult {
        captureCallCount += 1
        if delayNs > 0 {
            try? await Task.sleep(nanoseconds: delayNs)
        }
        if let scriptedResult { return scriptedResult }
        return result.map { .captured($0) } ?? .noSelection
    }
}

/// Scripted edit processor so the coordinator's edit pipeline is exercised
/// without a live LLM.
final class MockEditProcessor: EditCommandProcessing {
    var outcome: EditCommandOutcome = .edited(text: "EDITED")
    private(set) var receivedSelections: [String] = []
    private(set) var receivedInstructions: [String] = []

    func performEdit(selection: String, instruction: String) async -> EditCommandOutcome {
        receivedSelections.append(selection)
        receivedInstructions.append(instruction)
        return outcome
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
    var selectionCapture: MockSelectionCapture!
    var editProcessor: MockEditProcessor!
    var coordinator: DictationCoordinator!
    private var savedDefaults: [String: Any] = [:]
    private let isolatedDefaultKeys = [
        "selectedAudioDeviceID",
        "selectedModelId",
        "activeModelId",
        "dictationLanguage",
        "handsFreeModeEnabled",
        "handsFreeSilenceStopEnabled",
        "handsFreeSilenceStopSeconds",
        "handsFreeMaxRecordingDuration",
        "editCommandsEnabled",
        "vocabularyBiasEnabled"
    ]
    /// Deterministic gesture clock. Recording durations still use real time;
    /// only tap/hold disambiguation reads this.
    var gestureNow = Date()

    @MainActor
    override func setUpWithError() throws {
        savedDefaults = isolatedDefaultKeys.reduce(into: [:]) { snapshot, key in
            if let value = UserDefaults.standard.object(forKey: key) {
                snapshot[key] = value
            }
        }
        // AppSettings uses the app's standard defaults domain. Clear every
        // preference this suite mutates before constructing it so tests are
        // deterministic and never depend on the developer's live choices.
        for key in isolatedDefaultKeys {
            UserDefaults.standard.removeObject(forKey: key)
        }
        audioService = MockAudioCaptureService()
        transcriptionService = MockTranscriptionService()
        textProcessor = MockTextProcessor()
        injectionService = MockInjectionService()
        selectionCapture = MockSelectionCapture()
        editProcessor = MockEditProcessor()

        let dbQueue = try DatabaseQueue(path: ":memory:")
        databaseManager = try DatabaseManager(dbQueue: dbQueue)
        settings = AppSettings()

        gestureNow = Date()
        coordinator = DictationCoordinator(
            audioService: audioService,
            transcriptionService: transcriptionService,
            textProcessor: textProcessor,
            injectionService: injectionService,
            databaseManager: databaseManager,
            settings: settings,
            selectionCapture: selectionCapture,
            editProcessor: editProcessor,
            now: { [weak self] in self?.gestureNow ?? Date() }
        )
    }

    override func tearDownWithError() throws {
        // These settings write through @AppStorage to the Debug app's real
        // defaults domain. Restore the pre-test values so a test microphone
        // ID or hands-free toggle can never alter the app launched afterward.
        let defaults = UserDefaults.standard
        for key in isolatedDefaultKeys {
            if let value = savedDefaults[key] {
                defaults.set(value, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }
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
    func testStartRecordingDecodesSilentlyWithoutPartialInsertion() async {
        coordinator.startRecording()
        try? await Task.sleep(nanoseconds: 350_000_000)

        let beginCallCount = await transcriptionService.beginLiveSessionCallCount
        let transcribeCount = await transcriptionService.transcribeCallCount
        let processedSampleCounts = await transcriptionService.processedLiveSampleCounts
        let hasEventHandler = await transcriptionService.hasLiveTranscriptEventHandler()
        XCTAssertEqual(beginCallCount, 1)
        XCTAssertEqual(transcribeCount, 0)
        XCTAssertFalse(processedSampleCounts.isEmpty)
        XCTAssertFalse(hasEventHandler)
        XCTAssertTrue(injectionService.injectedTexts.isEmpty)

        coordinator.stopRecording()
    }

    @MainActor
    func testFinalDecodeSnapshotsVocabularyBiasTerms() async {
        textProcessor.mockVocabularyBiasTerms = ["Olanrewaju", "WhisperKit"]
        settings.vocabularyBiasEnabled = true

        coordinator.startRecording()
        try? await Task.sleep(nanoseconds: 700_000_000)
        coordinator.stopRecording()
        _ = await waitUntil { self.coordinator.state == .idle }

        let history = await transcriptionService.vocabularyBiasTermsHistory
        XCTAssertFalse(history.isEmpty)
        XCTAssertTrue(history.allSatisfy { $0 == ["Olanrewaju", "WhisperKit"] })
    }

    @MainActor
    func testFinalDecodeSendsEmptyBiasSnapshotWhenToggleIsOff() async {
        textProcessor.mockVocabularyBiasTerms = ["Olanrewaju", "WhisperKit"]
        settings.vocabularyBiasEnabled = false

        coordinator.startRecording()
        try? await Task.sleep(nanoseconds: 700_000_000)
        coordinator.stopRecording()
        _ = await waitUntil { self.coordinator.state == .idle }

        let history = await transcriptionService.vocabularyBiasTermsHistory
        XCTAssertFalse(history.isEmpty)
        XCTAssertTrue(history.allSatisfy(\.isEmpty), "toggle off must clear every snapshot")
    }

    @MainActor
    func testStopRecordingFinalizesSilentBackgroundSessionOnce() async {
        audioService.mockSamples = Array(repeating: 0.1, count: 40_000)
        coordinator.startRecording()
        try? await Task.sleep(nanoseconds: 700_000_000)
        coordinator.stopRecording()

        _ = await waitUntil { self.coordinator.state == .idle }
        let transcribeCount = await transcriptionService.transcribeCallCount
        let finalizeCount = await transcriptionService.finalizeLiveTranscriptionCallCount
        let liveSampleCounts = await transcriptionService.processedLiveSampleCounts
        XCTAssertEqual(transcribeCount, 1)
        XCTAssertEqual(finalizeCount, 1)
        XCTAssertFalse(liveSampleCounts.isEmpty)
        XCTAssertEqual(injectionService.injectedTexts, ["Hello world"])
    }

    @MainActor
    func testStopRecordingLoadsModelOnDemandWhenWarmupDidNotFinish() async {
        let selectedModelId = settings.effectiveSelectedModelId
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
        let transcribeCallCount = await transcriptionService.transcribeCallCount
        let finalizeCount = await transcriptionService.finalizeLiveTranscriptionCallCount
        XCTAssertEqual(transcribeCallCount, 1)
        XCTAssertEqual(finalizeCount, 1)
        XCTAssertEqual(injectionService.injectedTexts, ["Hello world"])
        XCTAssertEqual(settings.activeModelId, selectedModelId)
    }

    @MainActor
    func testStopRecordingReloadsExactSelectedModelWhenAnotherModelIsLoaded() async {
        let selectedModelId = settings.effectiveSelectedModelId
        await transcriptionService.setLoadedModelForTest("openai_whisper-tiny")
        audioService.mockSamples = Array(repeating: 0.1, count: 40_000)

        coordinator.startRecording()
        try? await Task.sleep(nanoseconds: 700_000_000)
        coordinator.stopRecording()

        _ = await waitUntil { self.coordinator.state == .idle }
        let loadedModelNames = await transcriptionService.loadedModelNames
        let loadedModelID = await transcriptionService.loadedModelID()
        XCTAssertEqual(loadedModelNames, [selectedModelId])
        XCTAssertEqual(loadedModelID, selectedModelId)
    }

    @MainActor
    func testIncompleteCaptureIsRejectedBeforeTranscription() async {
        audioService.mockSamples = Array(repeating: 0.1, count: 1_600)

        coordinator.startRecording()
        try? await Task.sleep(nanoseconds: 700_000_000)
        coordinator.stopRecording()

        guard case .error(let message) = coordinator.state else {
            return XCTFail("Incomplete capture must surface an error")
        }
        let transcribeCallCount = await transcriptionService.transcribeCallCount
        let finalizeCount = await transcriptionService.finalizeLiveTranscriptionCallCount
        let cancelCount = await transcriptionService.cancelLiveSessionCallCount
        XCTAssertEqual(message, "Audio was dropped. Please dictate again.")
        XCTAssertEqual(transcribeCallCount, 0)
        XCTAssertEqual(finalizeCount, 0)
        XCTAssertGreaterThanOrEqual(cancelCount, 1)
        XCTAssertTrue(injectionService.injectedTexts.isEmpty)
    }

    func testCaptureCoverageUsesSixteenKilohertzClock() {
        XCTAssertEqual(
            DictationCoordinator.captureCoverage(sampleCount: 16_000, recordingDurationMs: 1_000),
            1,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            DictationCoordinator.captureCoverage(sampleCount: 4_800, recordingDurationMs: 1_000),
            0.3,
            accuracy: 0.0001
        )
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
    func testUnverifiedCodexPasteCompletesWithoutFailurePill() async throws {
        injectionService.mockResult = .success(method: .unverifiedPaste)
        audioService.mockSamples = Array(repeating: 0.1, count: 40_000)

        coordinator.startRecording()
        try? await Task.sleep(nanoseconds: 700_000_000)
        coordinator.stopRecording()

        let becameIdle = await waitUntil { self.coordinator.state == .idle }
        XCTAssertTrue(becameIdle, "An unreadable Codex editor is not an insertion failure")
        let saved = try await waitForTranscription()
        XCTAssertEqual(saved.injectionMethod, "unverified_paste")
    }

    @MainActor
    func testFinalTranscriptIsInHistoryBeforeDestinationInjection() async throws {
        var historyWasVisibleAtInjection = false
        injectionService.onInject = { [weak self] text in
            guard let self else { return }
            historyWasVisibleAtInjection = (try? self.databaseManager.fetchRecent(limit: 1).first?.text) == text
        }
        audioService.mockSamples = Array(repeating: 0.1, count: 40_000)

        coordinator.startRecording()
        try? await Task.sleep(nanoseconds: 700_000_000)
        coordinator.stopRecording()

        _ = try await waitForTranscription()
        XCTAssertTrue(
            historyWasVisibleAtInjection,
            "A completed transcript must survive even if the destination app fails during delivery"
        )
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

    // MARK: - Tap vs hold (hands-free toggle)

    @MainActor
    func testHotkeyDownStartsRecordingImmediately() {
        settings.handsFreeModeEnabled = true
        coordinator.handleHotkeyDown()

        guard case .recording = coordinator.state else {
            return XCTFail("Recording must start on key-down, never waiting for tap/hold disambiguation")
        }
        XCTAssertFalse(coordinator.isHandsFreeRecording, "A press always begins as push-to-talk")

        gestureNow.addTimeInterval(1.0)
        coordinator.handleHotkeyUp()
    }

    @MainActor
    func testTapPromotesToHandsFree() {
        settings.handsFreeModeEnabled = true
        coordinator.handleHotkeyDown()
        gestureNow.addTimeInterval(0.1)
        coordinator.handleHotkeyUp()

        guard case .recording = coordinator.state else {
            return XCTFail("A tap must keep the recording running")
        }
        XCTAssertTrue(coordinator.isHandsFreeRecording)

        coordinator.stopRecording()
    }

    @MainActor
    func testHoldReleaseStopsRecording() {
        settings.handsFreeModeEnabled = true
        coordinator.handleHotkeyDown()
        gestureNow.addTimeInterval(0.5)
        coordinator.handleHotkeyUp()

        if case .recording = coordinator.state {
            XCTFail("Releasing a hold must stop recording — push-to-talk semantics unchanged")
        }
        XCTAssertFalse(coordinator.isHandsFreeRecording)
    }

    @MainActor
    func testReleaseAtTapThresholdBoundaryIsHold() {
        settings.handsFreeModeEnabled = true
        coordinator.handleHotkeyDown()
        gestureNow.addTimeInterval(HotkeyGestureInterpreter.tapMaxDuration)
        coordinator.handleHotkeyUp()

        if case .recording = coordinator.state {
            XCTFail("A release exactly at the threshold classifies as a hold and must stop")
        }
    }

    @MainActor
    func testReleaseJustUnderTapThresholdPromotes() {
        settings.handsFreeModeEnabled = true
        coordinator.handleHotkeyDown()
        gestureNow.addTimeInterval(HotkeyGestureInterpreter.tapMaxDuration - 0.01)
        coordinator.handleHotkeyUp()

        XCTAssertTrue(
            coordinator.isHandsFreeRecording,
            "A hold shorter than the threshold is a tap by definition and goes hands-free"
        )
        coordinator.stopRecording()
    }

    @MainActor
    func testSecondTapStopsHandsFreeRecording() async {
        settings.handsFreeModeEnabled = true
        audioService.mockSamples = Array(repeating: 0.1, count: 40_000)

        coordinator.handleHotkeyDown()
        gestureNow.addTimeInterval(0.1)
        coordinator.handleHotkeyUp()
        XCTAssertTrue(coordinator.isHandsFreeRecording)

        // Real time must pass the 0.5s minimum so the stop finalizes.
        try? await Task.sleep(nanoseconds: 700_000_000)

        gestureNow.addTimeInterval(2.0)
        coordinator.handleHotkeyDown()
        if case .recording = coordinator.state {
            XCTFail("Second tap must stop the hands-free recording")
        }

        // The key-up that follows the stopping tap must not start anything.
        gestureNow.addTimeInterval(0.1)
        coordinator.handleHotkeyUp()
        if case .recording = coordinator.state {
            XCTFail("The release after a stopping tap must be inert")
        }

        let becameIdle = await waitUntil { self.coordinator.state == .idle }
        XCTAssertTrue(becameIdle, "The stopped hands-free recording must finalize back to idle")
        let transcribeCount = await transcriptionService.transcribeCallCount
        XCTAssertEqual(transcribeCount, 1)
    }

    @MainActor
    func testHotkeyEventsIgnoredWhileProcessing() async {
        settings.handsFreeModeEnabled = true
        await transcriptionService.setTranscribeDelayNsForTest(1_500_000_000)
        audioService.mockSamples = Array(repeating: 0.1, count: 40_000)

        coordinator.startRecording()
        try? await Task.sleep(nanoseconds: 700_000_000)
        coordinator.stopRecording()
        guard case .processing = coordinator.state else {
            return XCTFail("Expected processing state, got \(coordinator.state)")
        }

        // A tap while processing must neither start a recording nor disturb
        // the in-flight pipeline.
        coordinator.handleHotkeyDown()
        guard case .processing = coordinator.state else {
            return XCTFail("Key-down while processing must be ignored, got \(coordinator.state)")
        }
        gestureNow.addTimeInterval(0.1)
        coordinator.handleHotkeyUp()
        guard case .processing = coordinator.state else {
            return XCTFail("Key-up while processing must be ignored, got \(coordinator.state)")
        }

        let becameIdle = await waitUntil(timeoutSeconds: 5) { self.coordinator.state == .idle }
        XCTAssertTrue(becameIdle)
    }

    @MainActor
    func testHotkeyEventsInErrorStateAreHandled() {
        audioService.shouldFail = true
        coordinator.handleHotkeyDown()
        guard case .error = coordinator.state else {
            return XCTFail("Mic failure should land in error state")
        }

        gestureNow.addTimeInterval(0.1)
        coordinator.handleHotkeyUp()
        guard case .error = coordinator.state else {
            return XCTFail("Key-up in error state must be inert")
        }

        coordinator.handleHotkeyDown()
        guard case .error = coordinator.state else {
            return XCTFail("Key-down in error state must be inert")
        }
    }

    @MainActor
    func testTapStopsRecordingWhenHandsFreeDisabled() {
        settings.handsFreeModeEnabled = false
        coordinator.handleHotkeyDown()
        gestureNow.addTimeInterval(0.1)
        coordinator.handleHotkeyUp()

        if case .recording = coordinator.state {
            XCTFail("With hands-free disabled, every release stops — pure push-to-talk")
        }
        XCTAssertFalse(coordinator.isHandsFreeRecording)
    }

    @MainActor
    func testStartHandsFreeRecordingFromPanelButton() {
        settings.handsFreeModeEnabled = true
        coordinator.startHandsFreeRecording()
        XCTAssertTrue(coordinator.isHandsFreeRecording, "Mic-button sessions hold no key and are hands-free")
        coordinator.stopRecording()

        settings.handsFreeModeEnabled = false
        coordinator.startHandsFreeRecording()
        if case .recording = coordinator.state {
            XCTAssertFalse(coordinator.isHandsFreeRecording, "Disabled setting reverts to a plain recording")
        }
        coordinator.stopRecording()
    }

    // MARK: - Hands-free silence auto-stop

    @MainActor
    func testHandsFreeSilenceAutoStops() async {
        settings.handsFreeModeEnabled = true
        settings.handsFreeSilenceStopEnabled = true
        settings.handsFreeSilenceStopSeconds = 1.0
        // 1s of speech followed by 1.25s of dead silence.
        audioService.mockSamples =
            Array(repeating: 0.1, count: 16_000) + Array(repeating: 0, count: 20_000)

        coordinator.handleHotkeyDown()
        gestureNow.addTimeInterval(0.1)
        coordinator.handleHotkeyUp()
        XCTAssertTrue(coordinator.isHandsFreeRecording)

        let stopped = await waitUntil(timeoutSeconds: 4) {
            if case .recording = self.coordinator.state { return false }
            return true
        }
        XCTAssertTrue(stopped, "Sustained trailing silence must auto-stop a hands-free recording")

        // Let processing complete so the whole-recording decode has landed.
        let becameIdle = await waitUntil(timeoutSeconds: 4) { self.coordinator.state == .idle }
        XCTAssertTrue(becameIdle)
        let transcribeCount = await transcriptionService.transcribeCallCount
        XCTAssertEqual(transcribeCount, 1, "Auto-stop must decode, not skip, the recording")
    }

    @MainActor
    func testHandsFreeSilenceDoesNotStopWhenSpeechResumes() async {
        settings.handsFreeModeEnabled = true
        settings.handsFreeSilenceStopEnabled = true
        settings.handsFreeSilenceStopSeconds = 1.0
        // Speech, a 1.2s pause, then speech again at the tail: the trailing
        // silence window never fills.
        audioService.mockSamples =
            Array(repeating: 0.1, count: 16_000)
            + Array(repeating: 0, count: 19_200)
            + Array(repeating: 0.1, count: 3_200)

        coordinator.handleHotkeyDown()
        gestureNow.addTimeInterval(0.1)
        coordinator.handleHotkeyUp()
        XCTAssertTrue(coordinator.isHandsFreeRecording)

        try? await Task.sleep(nanoseconds: 1_500_000_000)
        guard case .recording = coordinator.state else {
            return XCTFail("Speech resuming before the silence threshold must keep recording")
        }
        coordinator.stopRecording()
    }

    @MainActor
    func testHandsFreeSilenceStopDisabledKeepsRecording() async {
        settings.handsFreeModeEnabled = true
        settings.handsFreeSilenceStopEnabled = false
        audioService.mockSamples =
            Array(repeating: 0.1, count: 16_000) + Array(repeating: 0, count: 32_000)

        coordinator.handleHotkeyDown()
        gestureNow.addTimeInterval(0.1)
        coordinator.handleHotkeyUp()
        XCTAssertTrue(coordinator.isHandsFreeRecording)

        try? await Task.sleep(nanoseconds: 1_500_000_000)
        guard case .recording = coordinator.state else {
            return XCTFail("With silence auto-stop off, only tap/stop/cap end a hands-free recording")
        }
        coordinator.stopRecording()
    }

    @MainActor
    func testPushToTalkIsNeverSilenceAutoStopped() async {
        settings.handsFreeModeEnabled = true
        settings.handsFreeSilenceStopEnabled = true
        settings.handsFreeSilenceStopSeconds = 1.0
        audioService.mockSamples =
            Array(repeating: 0.1, count: 16_000) + Array(repeating: 0, count: 32_000)

        coordinator.startRecording() // hold, never promoted
        try? await Task.sleep(nanoseconds: 1_500_000_000)

        guard case .recording = coordinator.state else {
            return XCTFail("Silence auto-stop must never apply to push-to-talk")
        }
        XCTAssertFalse(coordinator.isHandsFreeRecording)
        coordinator.stopRecording()
    }

    // MARK: - Hands-free duration cap

    @MainActor
    func testHandsFreeCapCountsDownAndStops() async {
        settings.handsFreeModeEnabled = true
        settings.handsFreeSilenceStopEnabled = false
        settings.handsFreeMaxRecordingDuration = 3
        settings.maxRecordingDuration = 90
        audioService.mockSamples = Array(repeating: 0.1, count: 40_000)

        coordinator.handleHotkeyDown()
        gestureNow.addTimeInterval(0.1)
        coordinator.handleHotkeyUp()
        XCTAssertTrue(coordinator.isHandsFreeRecording)

        let sawCountdown = await waitUntil(timeoutSeconds: 2) {
            self.coordinator.countdownSeconds != nil
        }
        XCTAssertTrue(sawCountdown, "The hands-free cap reuses the countdown warning UX")

        let stopped = await waitUntil(timeoutSeconds: 6) {
            if case .recording = self.coordinator.state { return false }
            return true
        }
        XCTAssertTrue(stopped, "The hands-free cap must stop the recording — not the push-to-talk cap")
    }

    // MARK: - History persistence failure

    @MainActor
    func testHistorySaveFailurePostsBreadcrumbNotification() async {
        let failingStore = FailingHistoryStore()
        coordinator = DictationCoordinator(
            audioService: audioService,
            transcriptionService: transcriptionService,
            textProcessor: textProcessor,
            injectionService: injectionService,
            databaseManager: failingStore,
            settings: settings,
            now: { [weak self] in self?.gestureNow ?? Date() }
        )
        audioService.mockSamples = Array(repeating: 0.1, count: 40_000)

        let notified = XCTNSNotificationExpectation(name: .transcriptionHistorySaveDidFail)

        coordinator.startRecording()
        try? await Task.sleep(nanoseconds: 700_000_000)
        coordinator.stopRecording()

        await fulfillment(of: [notified], timeout: 5)
        XCTAssertEqual(
            failingStore.saveAttempts,
            DictationCoordinator.historySaveAttempts,
            "The store must be retried the full bounded-retry budget before failing loudly"
        )
    }

    // MARK: - Voice edit commands

    @MainActor
    func testEditCommandWithNoSelectionShowsErrorAndNeverRecords() async {
        settings.editCommandsEnabled = true
        selectionCapture.result = nil

        coordinator.handleEditHotkeyDown()
        let errored = await waitUntil {
            if case .error = self.coordinator.state { return true }
            return false
        }

        XCTAssertTrue(errored, "No selection must surface a pill error")
        if case .error(let message) = coordinator.state {
            XCTAssertEqual(message, "Select text first")
        }
        XCTAssertEqual(selectionCapture.captureCallCount, 1)
        let beginCallCount = await transcriptionService.beginLiveSessionCallCount
        XCTAssertEqual(beginCallCount, 0, "No recording may start without a selection")
    }

    @MainActor
    func testEditCommandOnSecureFieldShowsHonestErrorAndNeverRecords() async {
        settings.editCommandsEnabled = true
        selectionCapture.scriptedResult = .blockedSecureField

        coordinator.handleEditHotkeyDown()
        let errored = await waitUntil {
            if case .error = self.coordinator.state { return true }
            return false
        }

        XCTAssertTrue(errored, "A secure focused field must surface a pill error")
        if case .error(let message) = coordinator.state {
            XCTAssertEqual(message, "Can't edit password fields")
        }
        let beginCallCount = await transcriptionService.beginLiveSessionCallCount
        XCTAssertEqual(beginCallCount, 0, "No recording may start on a secure field")
    }

    @MainActor
    func testEditCommandDisabledIgnoresTheShortcut() async {
        settings.editCommandsEnabled = false
        selectionCapture.result = CapturedSelection(text: "some text", method: .axRead)

        coordinator.handleEditHotkeyDown()
        try? await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertEqual(coordinator.state, .idle)
        XCTAssertEqual(selectionCapture.captureCallCount, 0)
    }

    @MainActor
    func testEditCommandRecordsInstructionAndReplacesSelection() async throws {
        settings.editCommandsEnabled = true
        settings.handsFreeModeEnabled = true
        selectionCapture.result = CapturedSelection(text: "teh original selektion", method: .axRead)
        editProcessor.outcome = .edited(text: "the original selection")
        await transcriptionService.setMockResultForTest("fix the spelling")
        audioService.mockSamples = Array(repeating: 0.1, count: 40_000)

        coordinator.handleEditHotkeyDown()
        let recording = await waitUntil {
            if case .recording = self.coordinator.state { return true }
            return false
        }
        XCTAssertTrue(recording, "Edit recording must start once the selection is captured")
        XCTAssertTrue(coordinator.isEditSession)

        // Tap release promotes to hands-free just like dictation.
        gestureNow.addTimeInterval(0.1)
        coordinator.handleEditHotkeyUp()
        XCTAssertTrue(coordinator.isHandsFreeRecording)

        try? await Task.sleep(nanoseconds: 700_000_000)
        coordinator.stopRecording()

        let becameIdle = await waitUntil(timeoutSeconds: 5) { self.coordinator.state == .idle }
        XCTAssertTrue(becameIdle)

        XCTAssertEqual(editProcessor.receivedSelections, ["teh original selektion"])
        XCTAssertEqual(editProcessor.receivedInstructions, ["fix the spelling"])
        XCTAssertEqual(injectionService.injectedTexts, ["the original selection"], "The edit result replaces the selection via verified injection")

        let saved = try await waitForTranscription()
        XCTAssertEqual(saved.entryKind, "edit")
        XCTAssertEqual(saved.editInstruction, "fix the spelling")
        XCTAssertEqual(saved.text, "the original selection")
        XCTAssertEqual(saved.injectionMethod, "paste")
        XCTAssertFalse(coordinator.isEditSession, "Session context resets after completion")
    }

    @MainActor
    func testEditFailureLeavesSelectionUntouchedWithHonestError() async {
        settings.editCommandsEnabled = true
        selectionCapture.result = CapturedSelection(text: "original words", method: .clipboardCopy)
        editProcessor.outcome = .failed(reason: "Couldn't apply the edit")
        audioService.mockSamples = Array(repeating: 0.1, count: 40_000)

        coordinator.handleEditHotkeyDown()
        _ = await waitUntil {
            if case .recording = self.coordinator.state { return true }
            return false
        }
        try? await Task.sleep(nanoseconds: 700_000_000)
        coordinator.stopRecording()

        let errored = await waitUntil(timeoutSeconds: 5) {
            if case .error(let message) = self.coordinator.state {
                return message == "Couldn't apply the edit"
            }
            return false
        }
        XCTAssertTrue(errored, "A failed edit must show an honest pill error")
        XCTAssertTrue(injectionService.injectedTexts.isEmpty, "Nothing may be injected when the edit fails")
    }

    // MARK: - Mode collision matrix

    @MainActor
    func testEditShortcutIgnoredWhileDictationIsRecording() async {
        settings.editCommandsEnabled = true
        selectionCapture.result = CapturedSelection(text: "some text", method: .axRead)

        coordinator.startRecording()
        guard case .recording = coordinator.state else { return XCTFail("Expected dictation recording") }
        XCTAssertFalse(coordinator.isEditSession)

        coordinator.handleEditHotkeyDown()
        try? await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertEqual(selectionCapture.captureCallCount, 0, "Edit capture must not start during a dictation")
        guard case .recording = coordinator.state else { return XCTFail("Dictation must keep recording") }
        XCTAssertFalse(coordinator.isEditSession)
        coordinator.stopRecording()
    }

    @MainActor
    func testEditShortcutIgnoredWhileProcessing() async {
        settings.editCommandsEnabled = true
        selectionCapture.result = CapturedSelection(text: "some text", method: .axRead)
        await transcriptionService.setTranscribeDelayNsForTest(1_500_000_000)
        audioService.mockSamples = Array(repeating: 0.1, count: 40_000)

        coordinator.startRecording()
        try? await Task.sleep(nanoseconds: 700_000_000)
        coordinator.stopRecording()
        guard case .processing = coordinator.state else {
            return XCTFail("Expected processing state, got \(coordinator.state)")
        }

        coordinator.handleEditHotkeyDown()
        XCTAssertEqual(selectionCapture.captureCallCount, 0)
        guard case .processing = coordinator.state else {
            return XCTFail("Edit key while processing must be inert")
        }

        let becameIdle = await waitUntil(timeoutSeconds: 5) { self.coordinator.state == .idle }
        XCTAssertTrue(becameIdle)
    }

    @MainActor
    func testDictationKeyDoesNotStopHandsFreeEditRecording() async {
        settings.editCommandsEnabled = true
        settings.handsFreeModeEnabled = true
        selectionCapture.result = CapturedSelection(text: "some text", method: .axRead)
        audioService.mockSamples = Array(repeating: 0.1, count: 40_000)

        coordinator.handleEditHotkeyDown()
        _ = await waitUntil {
            if case .recording = self.coordinator.state { return true }
            return false
        }
        gestureNow.addTimeInterval(0.1)
        coordinator.handleEditHotkeyUp()
        XCTAssertTrue(coordinator.isHandsFreeRecording)
        XCTAssertTrue(coordinator.isEditSession)

        // The push-to-talk key must not hijack or stop the edit session.
        gestureNow.addTimeInterval(1.0)
        coordinator.handleHotkeyDown()
        guard case .recording = coordinator.state else {
            return XCTFail("Dictation key-down must not stop an edit recording")
        }
        XCTAssertTrue(coordinator.isEditSession)
        gestureNow.addTimeInterval(0.1)
        coordinator.handleHotkeyUp()
        guard case .recording = coordinator.state else {
            return XCTFail("Dictation key-up must not stop an edit recording")
        }

        coordinator.stopRecording()
    }

    @MainActor
    func testSecondEditTapStopsHandsFreeEditRecording() async {
        settings.editCommandsEnabled = true
        settings.handsFreeModeEnabled = true
        selectionCapture.result = CapturedSelection(text: "some text", method: .axRead)
        editProcessor.outcome = .edited(text: "edited text")
        audioService.mockSamples = Array(repeating: 0.1, count: 40_000)

        coordinator.handleEditHotkeyDown()
        _ = await waitUntil {
            if case .recording = self.coordinator.state { return true }
            return false
        }
        gestureNow.addTimeInterval(0.1)
        coordinator.handleEditHotkeyUp()
        XCTAssertTrue(coordinator.isHandsFreeRecording)

        try? await Task.sleep(nanoseconds: 700_000_000)
        gestureNow.addTimeInterval(2.0)
        coordinator.handleEditHotkeyDown()
        if case .recording = coordinator.state {
            XCTFail("Second edit tap must stop the hands-free edit recording")
        }

        let becameIdle = await waitUntil(timeoutSeconds: 5) { self.coordinator.state == .idle }
        XCTAssertTrue(becameIdle)
    }

    @MainActor
    func testDictationCannotStartWhileEditCaptureIsInFlight() async {
        settings.editCommandsEnabled = true
        selectionCapture.result = CapturedSelection(text: "some text", method: .axRead)
        selectionCapture.delayNs = 400_000_000

        coordinator.handleEditHotkeyDown()
        XCTAssertTrue(coordinator.isCapturingEditSelection)

        coordinator.startRecording()
        XCTAssertEqual(coordinator.state, .idle, "Dictation must not start under an in-flight edit capture")

        let recording = await waitUntil {
            if case .recording = self.coordinator.state { return true }
            return false
        }
        XCTAssertTrue(recording, "The edit session still starts once capture completes")
        XCTAssertTrue(coordinator.isEditSession)
        coordinator.stopRecording()
    }

    @MainActor
    func testEditKeyReleasedDuringCaptureStillPromotesToHandsFree() async {
        settings.editCommandsEnabled = true
        settings.handsFreeModeEnabled = true
        selectionCapture.result = CapturedSelection(text: "some text", method: .axRead)
        selectionCapture.delayNs = 300_000_000

        coordinator.handleEditHotkeyDown()
        gestureNow.addTimeInterval(0.1)
        coordinator.handleEditHotkeyUp() // released before capture finished

        let recording = await waitUntil {
            if case .recording = self.coordinator.state { return true }
            return false
        }
        XCTAssertTrue(recording)
        XCTAssertTrue(coordinator.isHandsFreeRecording, "The deferred tap must promote the edit recording to hands-free")
        coordinator.stopRecording()
    }

    // MARK: - Helpers

    /// Polls `condition` on the main actor until it holds or the timeout passes.
    @MainActor
    private func waitUntil(
        timeoutSeconds: Double = 3,
        _ condition: @escaping () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return condition()
    }

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

    func setTranscribeDelayNsForTest(_ delayNs: UInt64) {
        transcribeDelayNs = delayNs
    }

    func setMockResultForTest(_ result: String) {
        mockResult = result
    }

    func setLoadedModelForTest(_ modelID: String) {
        isLoaded = true
        loadedModelNames = []
        mockLoadedModelID = modelID
    }
}
