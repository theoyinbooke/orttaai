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
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: "dictationReliabilityRecoveryVersion")
        defaults.set(true, forKey: "localLLMPolishEnabled")

        XCTAssertFalse(AppSettings().localLLMPolishEnabled)

        defaults.set(true, forKey: "localLLMPolishEnabled")
        XCTAssertTrue(AppSettings().localLLMPolishEnabled)
    }

    func testOrphanedPolishModeKeyIsRemovedAtInit() {
        UserDefaults.standard.set(true, forKey: "polishModeEnabled")

        _ = AppSettings()

        XCTAssertNil(
            UserDefaults.standard.object(forKey: "polishModeEnabled"),
            "The orphaned pre-1.7 polishModeEnabled key must be deleted"
        )
    }

    func testLegacyMaxChars280MigratesTo400OnRead() {
        settings.localLLMPolishMaxChars = 280

        XCTAssertEqual(
            settings.clampedLocalLLMPolishMaxChars,
            400,
            "The old 280-char default must migrate so polish covers longer dictation"
        )
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
        0
    }
}
