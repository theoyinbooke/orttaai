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
    /// Artificial transcription latency so tests can observe the coordinator
    /// while it is genuinely in the processing state.
    var transcribeDelayNs: UInt64 = 0
    var shouldFailModelLoad = false
    var mockLoadedModelID: String? = "test-model"
    var loadedModelNames: [String] = []
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
        injectionMethod: String
    ) throws {
        lock.lock()
        _saveAttempts += 1
        lock.unlock()
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
    // In-field streaming seams. The coordinator is always built with a mock
    // streaming factory so no unit test can ever reach live AX or post real
    // keystrokes. The default AX error makes every session stream BLIND
    // (typed increments into the mock key poster, count-based
    // reconciliation) unless a test configures a readable field explicitly.
    var streamingInspector: MockAccessibilityInspector!
    var streamingKeyPoster: MockKeyEventPoster!
    var streamingClipboard: MockClipboard!
    var streamingTargetFrontmost = true
    var streamingFactoryCallCount = 0
    /// Deterministic gesture clock. Recording durations still use real time;
    /// only tap/hold disambiguation reads this.
    var gestureNow = Date()

    @MainActor
    override func setUpWithError() throws {
        audioService = MockAudioCaptureService()
        transcriptionService = MockTranscriptionService()
        textProcessor = MockTextProcessor()
        injectionService = MockInjectionService()
        selectionCapture = MockSelectionCapture()
        editProcessor = MockEditProcessor()

        let dbQueue = try DatabaseQueue(path: ":memory:")
        databaseManager = try DatabaseManager(dbQueue: dbQueue)
        settings = AppSettings()

        streamingInspector = MockAccessibilityInspector()
        streamingKeyPoster = MockKeyEventPoster()
        streamingClipboard = MockClipboard()
        streamingTargetFrontmost = true
        streamingFactoryCallCount = 0

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
            streamingSessionFactory: { [weak self] _ in
                self?.streamingFactoryCallCount += 1
                return InFieldStreamingSession(
                    targetApp: nil,
                    inspector: self?.streamingInspector ?? MockAccessibilityInspector(),
                    keyPoster: self?.streamingKeyPoster ?? MockKeyEventPoster(),
                    clipboard: self?.streamingClipboard ?? MockClipboard(),
                    settleNanoseconds: 0,
                    isTargetFrontmost: { [weak self] in self?.streamingTargetFrontmost ?? false }
                )
            },
            now: { [weak self] in self?.gestureNow ?? Date() }
        )
    }

    /// Configures the streaming seams as a well-behaved editable text area so
    /// a session passes the start gates and typed keystrokes land in the
    /// simulated field.
    @MainActor
    private func configureStreamableField(value: String = "doc: ") {
        streamingInspector.detailsResult = .value(
            FocusedElementDetails(role: "AXTextArea", subrole: nil, roleDescription: "text entry area")
        )
        streamingInspector.simulatedFieldValue = value
        streamingKeyPoster.onTypedText = { [weak self] text in
            guard let inspector = self?.streamingInspector else { return }
            inspector.simulatedFieldValue = (inspector.simulatedFieldValue ?? "") + text
        }
        streamingKeyPoster.onBackspaces = { [weak self] count in
            guard let inspector = self?.streamingInspector else { return }
            inspector.simulatedFieldValue = String((inspector.simulatedFieldValue ?? "").dropLast(count))
        }
    }

    override func tearDownWithError() throws {
        // Hands-free settings write through @AppStorage to standard defaults;
        // remove them so tests never leak state into each other or the host.
        let defaults = UserDefaults.standard
        for key in [
            "handsFreeModeEnabled",
            "handsFreeSilenceStopEnabled",
            "handsFreeSilenceStopSeconds",
            "handsFreeMaxRecordingDuration",
            "editCommandsEnabled",
            "inFieldStreamingEnabled"
        ] {
            defaults.removeObject(forKey: key)
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
    func testStartRecordingBeginsLiveTranscriptionSession() async {
        coordinator.startRecording()

        try? await Task.sleep(nanoseconds: 200_000_000)

        let beginCallCount = await transcriptionService.beginLiveSessionCallCount
        XCTAssertEqual(beginCallCount, 1)

        coordinator.stopRecording()
    }

    @MainActor
    func testStartRecordingSnapshotsVocabularyBiasTermsBeforeSession() async {
        textProcessor.mockVocabularyBiasTerms = ["Olanrewaju", "WhisperKit"]
        settings.vocabularyBiasEnabled = true
        defer { UserDefaults.standard.removeObject(forKey: "vocabularyBiasEnabled") }

        coordinator.startRecording()
        try? await Task.sleep(nanoseconds: 200_000_000)

        let history = await transcriptionService.vocabularyBiasTermsHistory
        XCTAssertEqual(history, [["Olanrewaju", "WhisperKit"]])

        coordinator.stopRecording()
    }

    @MainActor
    func testStartRecordingSendsEmptyBiasSnapshotWhenToggleIsOff() async {
        textProcessor.mockVocabularyBiasTerms = ["Olanrewaju", "WhisperKit"]
        settings.vocabularyBiasEnabled = false
        defer { UserDefaults.standard.removeObject(forKey: "vocabularyBiasEnabled") }

        coordinator.startRecording()
        try? await Task.sleep(nanoseconds: 200_000_000)

        let history = await transcriptionService.vocabularyBiasTermsHistory
        XCTAssertEqual(history, [[]], "toggle off must clear the snapshot, not skip the call")

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
    // MARK: - In-field streaming

    @MainActor
    func testStreamingTypesCommitsIntoField() async throws {
        configureStreamableField()
        audioService.mockSamples = Array(repeating: 0.1, count: 40_000)

        coordinator.startRecording()
        try? await Task.sleep(nanoseconds: 400_000_000)

        await transcriptionService.emitLiveTranscriptEventForTest(.committed("Hello world"))
        try? await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertEqual(streamingKeyPoster.typedTexts, ["Hello world"], "Committed text streams into the field")
        XCTAssertTrue(coordinator.isStreamingToField)
        XCTAssertNotNil(coordinator.liveTranscript, "The live transcript model still accumulates (never displayed)")
        XCTAssertEqual(streamingClipboard.saveCount, 0, "Streaming increments never touch the clipboard")

        coordinator.stopRecording()
        let saved = try await waitForTranscription()

        XCTAssertEqual(saved.injectionMethod, "streamed")
        XCTAssertEqual(saved.text, "Hello world")
        XCTAssertEqual(injectionService.injectedTexts, [], "Streamed sessions reconcile in place, never re-paste")
        XCTAssertEqual(streamingKeyPoster.backspaceCounts, [], "Identical final text needs no reconciliation edit")
        XCTAssertEqual(textProcessor.inputs.last?.deferPolish, false, "Streaming is only a preview; the final text must still use the full cleanup pipeline")
    }

    @MainActor
    func testStreamingSpeculativeTailIsVisibleAndRevisedInPlace() async {
        configureStreamableField()
        coordinator.startRecording()
        try? await Task.sleep(nanoseconds: 400_000_000)

        await transcriptionService.emitLiveTranscriptEventForTest(.speculative("maybe wrong words"))
        await transcriptionService.emitLiveTranscriptEventForTest(.committed("stable words"))
        await transcriptionService.emitLiveTranscriptEventForTest(.speculative("still guessing"))
        try? await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertEqual(
            streamingKeyPoster.typedTexts,
            ["maybe wrong words", "stable words", " still guessing"],
            "The speculative tail appears immediately and is safely revised when a commit arrives"
        )
        XCTAssertEqual(
            streamingKeyPoster.backspaceCounts,
            ["maybe wrong words".count],
            "Only the provisional span is replaced"
        )

        coordinator.stopRecording()
    }

    @MainActor
    func testStreamingDisabledSettingUsesNormalInjectionOnly() async throws {
        settings.inFieldStreamingEnabled = false
        configureStreamableField()
        audioService.mockSamples = Array(repeating: 0.1, count: 40_000)

        coordinator.startRecording()
        try? await Task.sleep(nanoseconds: 400_000_000)
        await transcriptionService.emitLiveTranscriptEventForTest(.committed("Hello world"))
        try? await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertEqual(streamingFactoryCallCount, 0, "Setting off must not create a streaming session")
        XCTAssertFalse(coordinator.isStreamingToField)
        XCTAssertEqual(streamingKeyPoster.typedTexts, [])
        XCTAssertNotNil(coordinator.liveTranscript, "The live transcript model still accumulates (never displayed)")

        coordinator.stopRecording()
        let saved = try await waitForTranscription()
        XCTAssertEqual(saved.injectionMethod, "paste")
        XCTAssertEqual(injectionService.injectedTexts, ["Hello world"], "Finalize injects normally")
    }

    @MainActor
    func testEditSessionsNeverCreateStreamingSession() async {
        selectionCapture.result = CapturedSelection(text: "some text", method: .axRead)
        coordinator.startEditCommand()
        try? await Task.sleep(nanoseconds: 400_000_000)

        if case .recording = coordinator.state {
            XCTAssertEqual(streamingFactoryCallCount, 0, "Edit sessions replace the selection at the end; they never stream")
            XCTAssertFalse(coordinator.isStreamingToField)
        } else {
            XCTFail("Edit recording should have started, got \(coordinator.state)")
        }
        coordinator.stopRecording()
    }

    @MainActor
    func testUnreadableFieldStreamsBlindAndReconcilesInPlace() async throws {
        // Default streamingInspector reports .axError — the unreadable-field
        // gate switches the session to BLIND streaming instead of suppressing
        // it: increments are typed, nothing is ever read back, and finalize
        // reconciles by count.
        audioService.mockSamples = Array(repeating: 0.1, count: 40_000)
        coordinator.startRecording()
        try? await Task.sleep(nanoseconds: 400_000_000)
        await transcriptionService.emitLiveTranscriptEventForTest(.committed("Hello world"))
        try? await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertTrue(coordinator.isStreamingToField, "Unreadable fields stream blind, never fall back")
        XCTAssertEqual(streamingKeyPoster.typedTexts, ["Hello world"], "Committed text types into the blind target")
        XCTAssertNotNil(coordinator.liveTranscript, "The live transcript model still accumulates (never displayed)")

        coordinator.stopRecording()
        let saved = try await waitForTranscription()
        XCTAssertEqual(saved.injectionMethod, "streamed", "Blind sessions reconcile in place")
        XCTAssertEqual(injectionService.injectedTexts, [], "No end-of-session paste after blind streaming")
        XCTAssertEqual(streamingKeyPoster.backspaceCounts, [], "Identical final text needs no reconciliation edit")
    }

    @MainActor
    func testStreamingFocusLossStopsTypingSilently() async {
        configureStreamableField()
        coordinator.startRecording()
        try? await Task.sleep(nanoseconds: 400_000_000)

        await transcriptionService.emitLiveTranscriptEventForTest(.committed("first part"))
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertTrue(coordinator.isStreamingToField)

        streamingTargetFrontmost = false
        await transcriptionService.emitLiveTranscriptEventForTest(.committed("second part"))
        try? await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertFalse(coordinator.isStreamingToField, "Focus change stops streaming for the session")
        XCTAssertEqual(streamingKeyPoster.typedTexts, ["first part"], "No text may land in the wrong app")
        XCTAssertNotNil(coordinator.liveTranscript, "The live transcript model still accumulates (never displayed)")

        coordinator.stopRecording()
    }

    @MainActor
    func testStreamingUserTypedMidStreamProducesHonestErrorAndClipboardFallback() async throws {
        configureStreamableField()
        audioService.mockSamples = Array(repeating: 0.1, count: 40_000)

        coordinator.startRecording()
        try? await Task.sleep(nanoseconds: 400_000_000)
        await transcriptionService.emitLiveTranscriptEventForTest(.committed("Hello world"))
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(streamingKeyPoster.typedTexts, ["Hello world"])

        // The user types into the field mid-dictation: reconciliation must
        // not guess.
        streamingInspector.simulatedFieldValue! += "!"
        coordinator.stopRecording()

        var sawHonestError = false
        for _ in 0..<40 {
            if case .error(let message) = coordinator.state {
                XCTAssertEqual(message, "Couldn't insert text. Press Cmd+V to paste it.")
                sawHonestError = true
                break
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertTrue(sawHonestError, "Reconciliation mismatch must surface the honest clipboard error")
        XCTAssertEqual(streamingKeyPoster.backspaceCounts, [], "Never delete around user-typed text")
        XCTAssertEqual(streamingClipboard.setStrings.last, "Hello world", "Final transcript goes to the clipboard")

        let saved = try await waitForTranscription()
        XCTAssertEqual(saved.injectionMethod, "failed")
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
        let finalizeCount = await transcriptionService.finalizeLiveTranscriptionCallCount
        XCTAssertEqual(finalizeCount, 1)
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

        // Let processing complete so the finalize call has landed.
        let becameIdle = await waitUntil(timeoutSeconds: 4) { self.coordinator.state == .idle }
        XCTAssertTrue(becameIdle)
        let finalizeCount = await transcriptionService.finalizeLiveTranscriptionCallCount
        XCTAssertEqual(finalizeCount, 1, "Auto-stop must finalize, not skip, the recording")
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
}
