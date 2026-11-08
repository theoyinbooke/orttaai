// LocalLLMTextProcessorTests.swift
// OrttaaiTests
//
// Covers the opt-in gating of local LLM polish and the one-time reliability
// recovery. An unreachable or
// misconfigured provider degrades to rule-based output without repeated
// connection attempts. Also covers the output sanitizer rails through the
// full process() path.

import XCTest
@testable import Orttaai

final class LocalLLMTextProcessorTests: XCTestCase {
    private static let managedKeys = [
        "localLLMPolishEnabled",
        "localLLMPolishModel",
        "localLLMPolishTimeoutMs",
        "localLLMPolishMaxChars",
        "spokenFormattingEnabled",
        "polishModeEnabled",
        "dictationReliabilityRecoveryVersion",
        "polishEngine",
    ]

    private var previousValues: [String: Any?] = [:]
    private var settings: AppSettings!

    override func setUp() {
        super.setUp()
        let defaults = UserDefaults.standard
        for key in Self.managedKeys {
            previousValues[key] = defaults.object(forKey: key)
        }
        settings = AppSettings()
        settings.localLLMPolishEnabled = true
        // These tests cover the local LLM server engine; S1-mini is the default.
        settings.polishEngine = "localLLM"
        settings.localLLMPolishModel = "test-model"
        settings.localLLMPolishTimeoutMs = 1_000
        settings.localLLMPolishMaxChars = 400
        settings.spokenFormattingEnabled = false
    }

    override func tearDown() {
        let defaults = UserDefaults.standard
        for key in Self.managedKeys {
            if let value = previousValues[key] ?? nil {
                defaults.set(value, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }
        previousValues = [:]
        settings = nil
        super.tearDown()
    }

    private func makeProcessor(client: MockLocalLLMClient) -> LocalLLMTextProcessor {
        LocalLLMTextProcessor(
            baseProcessor: PassthroughProcessor(),
            settings: settings,
            ollamaClient: client
        )
    }

    private func makeInput(_ text: String) -> TextProcessorInput {
        TextProcessorInput(rawTranscript: text, targetApp: nil, mode: .clean)
    }

    // MARK: - Opt-in gating

    func testPolishDefaultsOffForUsersWhoNeverTouchedTheSetting() {
        UserDefaults.standard.removeObject(forKey: "localLLMPolishEnabled")

        XCTAssertFalse(
            AppSettings().localLLMPolishEnabled,
            "Recognizer output must remain authoritative unless polish is explicitly enabled"
        )
    }

    func testReliabilityRecoveryRunsOnceThenPreservesExplicitOptIn() {
        // Its own defaults: the hosted app's startup (iCloud settings sync)
        // can write the shared domain while this runs.
        let suite = "OrttaaiTests.reliabilityRecovery.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "localLLMPolishEnabled")

        _ = AppSettings(defaults: defaults)
        XCTAssertFalse(defaults.bool(forKey: "localLLMPolishEnabled"))

        defaults.set(true, forKey: "localLLMPolishEnabled")
        _ = AppSettings(defaults: defaults)
        XCTAssertTrue(defaults.bool(forKey: "localLLMPolishEnabled"))
    }

    func testOrphanedPolishModeKeyIsRemovedAtInit() {
        UserDefaults.standard.set(true, forKey: "polishModeEnabled")

        _ = AppSettings()

        XCTAssertNil(
            UserDefaults.standard.object(forKey: "polishModeEnabled"),
            "The orphaned pre-1.7 polishModeEnabled key must be deleted"
        )
    }

    func testLegacyPolishDefaultsMigrateOnceAndLaterChoicesStick() {
        let defaults = UserDefaults.standard
        let versionKey = "polishDefaultsMigrationVersion"
        let saved = defaults.object(forKey: versionKey)
        defer {
            if let saved { defaults.set(saved, forKey: versionKey) } else { defaults.removeObject(forKey: versionKey) }
            defaults.removeObject(forKey: "localLLMInsightsContextTokens")
        }
        defaults.removeObject(forKey: versionKey)
        defaults.set(650, forKey: "localLLMPolishTimeoutMs")
        defaults.set(280, forKey: "localLLMPolishMaxChars")
        defaults.set(65_536, forKey: "localLLMInsightsContextTokens")

        let migrated = AppSettings(defaults: defaults)
        XCTAssertEqual(migrated.clampedLocalLLMPolishTimeoutMs, 3_000)
        XCTAssertEqual(migrated.clampedLocalLLMPolishMaxChars, 400, "polish covers longer dictation")
        XCTAssertEqual(migrated.clampedLocalLLMInsightsContextTokens, 16_384)

        // Picked afterwards, the same values are kept (they used to be
        // replaced on every read).
        migrated.localLLMPolishTimeoutMs = 650
        migrated.localLLMPolishMaxChars = 280
        let later = AppSettings(defaults: defaults)
        XCTAssertEqual(later.clampedLocalLLMPolishTimeoutMs, 650)
        XCTAssertEqual(later.clampedLocalLLMPolishMaxChars, 280)
    }

    func testPolishKeepsTheModelLoadedForAnHour() async throws {
        let client = MockLocalLLMClient(result: .success("Hello there, team."))
        let processor = LocalLLMTextProcessor(
            baseProcessor: PassthroughProcessor(), settings: settings, ollamaClient: client
        )
        _ = try await processor.process(
            TextProcessorInput(rawTranscript: "hello there team", targetApp: nil, mode: .clean)
        )
        XCTAssertEqual(client.keepAlives, [LocalLLMTextProcessor.polishKeepAlive])
    }

    func testRecordingWarmsAnIdlePolishModelOnce() async throws {
        settings.localLLMPolishModel = "warm-test-\(UUID().uuidString)"
        let client = MockLocalLLMClient(result: .success("ok"))
        let processor = LocalLLMTextProcessor(
            baseProcessor: PassthroughProcessor(), settings: settings, ollamaClient: client
        )

        processor.warmPolishIfIdle()
        for _ in 0..<100 where client.warmed.isEmpty {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(client.warmed.map(\.model), [settings.localLLMPolishModel])
        XCTAssertEqual(client.warmed.first?.keepAlive, LocalLLMTextProcessor.polishKeepAlive)

        // Still fresh: the next recording doesn't warm it again.
        processor.warmPolishIfIdle()
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(client.warmed.count, 1)
    }

    func testNoWarmUpWhenAnotherEngineOrPolishIsOff() async throws {
        settings.localLLMPolishModel = "warm-test-\(UUID().uuidString)"
        let client = MockLocalLLMClient(result: .success("ok"))
        let processor = LocalLLMTextProcessor(
            baseProcessor: PassthroughProcessor(), settings: settings, ollamaClient: client
        )
        settings.polishEngine = "s1Mini"
        processor.warmPolishIfIdle()
        settings.polishEngine = "localLLM"
        settings.localLLMPolishEnabled = false
        processor.warmPolishIfIdle()
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(client.warmed.isEmpty)
    }

    func testS1MiniEngineLeavesPolishToItAndNeverContactsTheProvider() async throws {
        settings.polishEngine = "s1Mini"
        let client = MockLocalLLMClient(result: .success("Should never be used."))
        let processor = makeProcessor(client: client)

        let output = try await processor.process(makeInput("this text stays as the rules wrote it"))

        XCTAssertEqual(output.text, "this text stays as the rules wrote it")
        XCTAssertEqual(client.generateCallCount, 0)
    }

    func testS1MiniIsTheDefaultPolishEngine() {
        UserDefaults.standard.removeObject(forKey: "polishEngine")
        XCTAssertTrue(AppSettings().usesS1MiniPolish)
    }

    func testDisabledPolishNeverContactsTheProvider() async throws {
        settings.localLLMPolishEnabled = false
        let client = MockLocalLLMClient(result: .success("Polished text."))
        let processor = makeProcessor(client: client)

        let output = try await processor.process(makeInput("polish should not run on this"))

        XCTAssertEqual(output.text, "polish should not run on this")
        XCTAssertEqual(client.generateCallCount, 0)
    }

    // MARK: - Graceful degradation

    func testUnreachableProviderFallsBackToRuleBasedOutput() async throws {
        let client = MockLocalLLMClient(result: .failure(URLError(.cannotConnectToHost)))
        let processor = makeProcessor(client: client)

        let output = try await processor.process(makeInput("hello there this is my dictation"))

        XCTAssertEqual(output.text, "hello there this is my dictation")
        XCTAssertEqual(output.changes, [])
        XCTAssertEqual(client.generateCallCount, 1)
    }

    func testUnreachableProviderIsNotRedialedOnTheNextDictation() async throws {
        let client = MockLocalLLMClient(result: .failure(URLError(.cannotConnectToHost)))
        let processor = makeProcessor(client: client)

        _ = try await processor.process(makeInput("first dictation goes to the dead port"))
        let second = try await processor.process(makeInput("second dictation must not redial"))

        XCTAssertEqual(second.text, "second dictation must not redial")
        XCTAssertEqual(
            client.generateCallCount, 1,
            "The circuit breaker must hold the connection attempt count at one"
        )
    }

    func testMissingModelIsNotRetriedOnTheNextDictation() async throws {
        let client = MockLocalLLMClient(
            result: .failure(OllamaClientError.httpError(status: 404, message: "model not found"))
        )
        let processor = makeProcessor(client: client)

        _ = try await processor.process(makeInput("first dictation hits the missing model"))
        let second = try await processor.process(makeInput("second dictation must not retry it"))

        XCTAssertEqual(second.text, "second dictation must not retry it")
        XCTAssertEqual(client.generateCallCount, 1)
    }

    func testReachableProviderPolishIsApplied() async throws {
        let client = MockLocalLLMClient(result: .success("Hello there, this is my dictation."))
        let processor = makeProcessor(client: client)

        let output = try await processor.process(makeInput("hello there this is my dictation"))

        XCTAssertEqual(output.text, "Hello there, this is my dictation.")
        XCTAssertTrue(output.changes.contains { $0.contains("Local LLM polish") })
    }

    func testProviderFailureNeverLosesTheTranscript() async throws {
        let client = MockLocalLLMClient(result: .failure(URLError(.timedOut)))
        let processor = makeProcessor(client: client)

        let output = try await processor.process(makeInput("the transcript must survive a timeout"))

        XCTAssertEqual(output.text, "the transcript must survive a timeout")
    }

    // MARK: - Sanitizer rails (exercised through the full process path)

    func testResponseDroppingADigitFallsBackToRawText() async throws {
        let client = MockLocalLLMClient(result: .success("The invoice total is due on the 30th."))
        let processor = makeProcessor(client: client)

        let output = try await processor.process(makeInput("the invoice total is $12,480.50 due on the 30th"))

        XCTAssertEqual(output.text, "the invoice total is $12,480.50 due on the 30th")
    }

    func testResponseSplittingAGluedTimeTokenIsRepaired() async throws {
        let client = MockLocalLLMClient(result: .success("The review moved to Thursday at 3 PM."))
        let processor = makeProcessor(client: client)

        let output = try await processor.process(makeInput("the review moved to thursday at 3pm"))

        XCTAssertEqual(output.text, "The review moved to Thursday at 3pm.")
    }

    func testResponseWithInventedBulletMarkerIsStripped() async throws {
        let client = MockLocalLLMClient(result: .success("* Summarize this thread in three points."))
        let processor = makeProcessor(client: client)

        let output = try await processor.process(makeInput("summarize this thread in three points"))

        XCTAssertEqual(output.text, "Summarize this thread in three points.")
    }

    func testResponseWithCurlyQuotesIsNormalizedToASCII() async throws {
        let client = MockLocalLLMClient(result: .success("It’s ready, let’s ship it."))
        let processor = makeProcessor(client: client)

        let output = try await processor.process(makeInput("its ready lets ship it"))

        XCTAssertEqual(output.text, "It's ready, let's ship it.")
    }

    func testRunawayResponseFallsBackToRawText() async throws {
        let runaway = String(repeating: "This is a much longer elaboration. ", count: 8)
        let client = MockLocalLLMClient(result: .success(runaway))
        let processor = makeProcessor(client: client)

        let output = try await processor.process(makeInput("short note about the plan today"))

        XCTAssertEqual(output.text, "short note about the plan today")
    }

    func testShortInputSkipsPolishEntirely() async throws {
        let client = MockLocalLLMClient(result: .success("Yes."))
        let processor = makeProcessor(client: client)

        let output = try await processor.process(makeInput("yes"))

        XCTAssertEqual(output.text, "yes")
        XCTAssertEqual(client.generateCallCount, 0)
    }
}

// MARK: - Test doubles

private struct PassthroughProcessor: TextProcessor {
    func process(_ input: TextProcessorInput) async throws -> TextProcessorOutput {
        TextProcessorOutput(text: input.rawTranscript, changes: [])
    }

    func isAvailable() -> Bool { true }
}

private final class MockLocalLLMClient: LocalLLMServing, @unchecked Sendable {
    private let result: Result<String, Error>
    private let lock = NSLock()
    private var _generateCallCount = 0
    private var _warmed: [(model: String, keepAlive: String)] = []
    private var _keepAlives: [String] = []

    var warmed: [(model: String, keepAlive: String)] {
        lock.lock()
        defer { lock.unlock() }
        return _warmed
    }

    var keepAlives: [String] {
        lock.lock()
        defer { lock.unlock() }
        return _keepAlives
    }

    var generateCallCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return _generateCallCount
    }

    init(result: Result<String, Error>) {
        self.result = result
    }

    var providerKind: LocalLLMProviderKind { .ollama }

    func checkHealth(baseURLString: String, timeoutMs: Int) async -> OllamaHealthStatus {
        OllamaHealthStatus(isReachable: true, installedModels: ["test-model"], message: "ok")
    }

    func fetchModelNames(baseURLString: String, timeoutMs: Int) async throws -> [String] {
        ["test-model"]
    }

    func generate(
        baseURLString: String,
        model: String,
        prompt: String,
        timeoutMs: Int?,
        think: Bool?,
        format: String?,
        formatJSONSchema: String?,
        temperature: Double,
        numPredict: Int,
        numContext: Int?,
        keepAlive: String
    ) async throws -> String {
        lock.lock()
        _generateCallCount += 1
        _keepAlives.append(keepAlive)
        lock.unlock()
        return try result.get()
    }

    func chat(
        baseURLString: String,
        model: String,
        messages: [OllamaChatMessage],
        timeoutMs: Int?,
        think: Bool?,
        temperature: Double,
        numPredict: Int,
        numContext: Int?,
        keepAlive: String
    ) async throws -> String {
        try result.get()
    }

    func embed(
        baseURLString: String,
        model: String,
        inputs: [String],
        timeoutMs: Int?,
        keepAlive: String,
        truncate: Bool
    ) async throws -> [[Float]] {
        []
    }

    func warmModel(
        baseURLString: String,
        model: String,
        timeoutMs: Int,
        keepAlive: String
    ) async throws -> Int {
        lock.lock()
        _warmed.append((model, keepAlive))
        lock.unlock()
        return 0
    }
}
