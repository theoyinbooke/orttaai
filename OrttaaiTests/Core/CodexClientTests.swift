// CodexClientTests.swift
// OrttaaiTests

import XCTest
@testable import Orttaai

/// Replays scripted JSON-RPC frames so the connection/client stack can be
/// exercised without spawning the real (240 MB) codex binary.
final class FakeCodexTransport: CodexTransport, @unchecked Sendable {
    /// Maps a sent request (method, id, params) to response frames to emit.
    typealias Handler = @Sendable (_ method: String, _ id: Int?, _ params: [String: Any]) -> [[String: Any]]

    private let lock = NSLock()
    private let handler: Handler
    private var continuation: AsyncStream<String>.Continuation?
    private var recordedFrames: [[String: Any]] = []

    init(handler: @escaping Handler) {
        self.handler = handler
    }

    var sentFrames: [[String: Any]] {
        lock.lock()
        defer { lock.unlock() }
        return recordedFrames
    }

    func sentFrames(method: String) -> [[String: Any]] {
        sentFrames.filter { ($0["method"] as? String) == method }
    }

    func start() async throws -> AsyncStream<String> {
        let (stream, continuation) = AsyncStream.makeStream(of: String.self, bufferingPolicy: .unbounded)
        lock.lock()
        self.continuation = continuation
        lock.unlock()
        return stream
    }

    func send(_ line: String) async throws {
        guard let data = line.data(using: .utf8),
              let frame = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return
        }
        lock.lock()
        recordedFrames.append(frame)
        lock.unlock()

        let method = frame["method"] as? String ?? ""
        let id = (frame["id"] as? NSNumber)?.intValue
        let params = frame["params"] as? [String: Any] ?? [:]
        for response in handler(method, id, params) {
            emit(response)
        }
    }

    func emit(_ frame: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: frame),
              let line = String(data: data, encoding: .utf8) else {
            return
        }
        lock.lock()
        let continuation = self.continuation
        lock.unlock()
        continuation?.yield(line)
    }

    func stop() async {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.finish()
    }
}

final class CodexClientTests: XCTestCase {

    private static let testBinary = CodexBinaryInfo(path: "/fake/bin/codex", version: "0.142.5")

    /// Standard handler covering the handshake; `extra` handles everything else.
    private func makeStack(
        extra: @escaping FakeCodexTransport.Handler
    ) -> (transport: FakeCodexTransport, connection: CodexAppServerConnection, client: CodexClient) {
        let transport = FakeCodexTransport { method, id, params in
            switch method {
            case "initialize":
                return [["id": id ?? 0, "result": ["userAgent": "test"]]]
            case "initialized":
                return []
            default:
                return extra(method, id, params)
            }
        }
        let connection = CodexAppServerConnection(
            transportFactory: { _ in transport },
            binaryDiscovery: { Self.testBinary }
        )
        return (transport, connection, CodexClient(connection: connection))
    }

    // MARK: - Binary locator

    func testVersionOutputParsing() {
        XCTAssertEqual(CodexBinaryLocator.parseVersionOutput("codex-cli 0.142.5"), "0.142.5")
        XCTAssertEqual(CodexBinaryLocator.parseVersionOutput("0.150.0\n"), "0.150.0")
        XCTAssertNil(CodexBinaryLocator.parseVersionOutput(""))
        XCTAssertNil(CodexBinaryLocator.parseVersionOutput("not a version"))
    }

    func testVersionComparison() {
        XCTAssertEqual(CodexBinaryLocator.compareVersions("0.142.5", "0.142.0"), 1)
        XCTAssertEqual(CodexBinaryLocator.compareVersions("0.142.0", "0.142.0"), 0)
        XCTAssertEqual(CodexBinaryLocator.compareVersions("0.141.9", "0.142.0"), -1)
        XCTAssertEqual(CodexBinaryLocator.compareVersions("1.0", "0.999.999"), 1)
        XCTAssertTrue(CodexBinaryLocator.isVersionSupported("0.142.5"))
        XCTAssertFalse(CodexBinaryLocator.isVersionSupported("0.100.0"))
    }

    // MARK: - Model list

    func testFetchModelNamesFiltersHiddenModels() async throws {
        let (_, _, client) = makeStack { method, id, _ in
            guard method == "model/list" else { return [] }
            return [[
                "id": id ?? 0,
                "result": [
                    "data": [
                        ["id": "gpt-5.5", "hidden": false],
                        ["id": "gpt-5.4-mini", "hidden": false],
                        ["id": "gpt-secret", "hidden": true],
                        ["id": "  ", "hidden": false],
                    ],
                ],
            ]]
        }
        let names = try await client.fetchModelNames(baseURLString: "", timeoutMs: 2_000)
        XCTAssertEqual(names, ["gpt-5.5", "gpt-5.4-mini"])
    }

    // MARK: - Turn lifecycle

    func testGenerateRunsEphemeralReadOnlyTurnAndReturnsFinalMessage() async throws {
        let threadID = "thread-123"
        let (transport, _, client) = makeStack { method, id, params in
            switch method {
            case "thread/start":
                return [["id": id ?? 0, "result": ["thread": ["id": threadID]]]]
            case "turn/start":
                let turn: [String: Any] = ["id": "turn-1", "status": "inProgress"]
                return [
                    ["id": id ?? 0, "result": ["turn": turn]],
                    ["method": "item/started", "params": ["threadId": threadID, "item": ["type": "agentMessage", "id": "i1", "text": ""]]],
                    ["method": "item/completed", "params": ["threadId": threadID, "item": ["type": "agentMessage", "id": "i1", "text": "{\"answer\":42}"]]],
                    ["method": "turn/completed", "params": ["threadId": threadID, "turn": ["id": "turn-1", "status": "completed"]]],
                ]
            default:
                return []
            }
        }

        let result = try await client.generate(
            baseURLString: "",
            model: "gpt-5.4-mini",
            prompt: "Answer with JSON.",
            timeoutMs: 5_000,
            think: nil,
            format: nil,
            formatJSONSchema: #"{"type":"object","properties":{"answer":{"type":"integer"}},"required":["answer"],"additionalProperties":false}"#,
            temperature: 0,
            numPredict: 100,
            numContext: nil,
            keepAlive: "5m"
        )
        XCTAssertEqual(result, "{\"answer\":42}")

        // Pure-inference guarantees: ephemeral thread, kebab-case read-only
        // sandbox (the wire format the server actually accepts), no approvals.
        let threadStart = try XCTUnwrap(transport.sentFrames(method: "thread/start").first)
        let params = try XCTUnwrap(threadStart["params"] as? [String: Any])
        XCTAssertEqual(params["sandbox"] as? String, "read-only")
        XCTAssertEqual(params["approvalPolicy"] as? String, "never")
        XCTAssertEqual(params["ephemeral"] as? Bool, true)
        XCTAssertEqual(params["model"] as? String, "gpt-5.4-mini")

        let turnStart = try XCTUnwrap(transport.sentFrames(method: "turn/start").first)
        let turnParams = try XCTUnwrap(turnStart["params"] as? [String: Any])
        XCTAssertNotNil(turnParams["outputSchema"], "formatJSONSchema should map to outputSchema")
    }

    /// The spawn arguments must disable the plugin/app layers: with them on,
    /// the app-server boots every configured MCP server before each turn's
    /// model request (measured 2-3s of latency per chat message).
    func testAppServerArgumentsDisablePluginAndAppLayers() {
        let args = CodexProcessTransport.appServerArguments
        XCTAssertEqual(args.first, "app-server")
        XCTAssertTrue(args.contains("features.plugins=false"))
        XCTAssertTrue(args.contains("features.apps=false"))
    }

    func testChatStreamDeliversAccumulatedDeltasAndFinalReply() async throws {
        let threadID = "thread-stream"
        let (_, _, client) = makeStack { method, id, _ in
            switch method {
            case "thread/start":
                return [["id": id ?? 0, "result": ["thread": ["id": threadID]]]]
            case "turn/start":
                return [
                    ["id": id ?? 0, "result": ["turn": ["id": "turn-1", "status": "inProgress"]]],
                    ["method": "item/agentMessage/delta", "params": ["threadId": threadID, "itemId": "i1", "turnId": "turn-1", "delta": "Hello"]],
                    ["method": "item/agentMessage/delta", "params": ["threadId": threadID, "itemId": "i1", "turnId": "turn-1", "delta": ", world"]],
                    ["method": "item/completed", "params": ["threadId": threadID, "item": ["type": "agentMessage", "id": "i1", "text": "Hello, world"]]],
                    ["method": "turn/completed", "params": ["threadId": threadID, "turn": ["id": "turn-1", "status": "completed"]]],
                ]
            default:
                return []
            }
        }

        final class DeltaLog: @unchecked Sendable {
            private let lock = NSLock()
            private var values: [String] = []
            func append(_ value: String) { lock.lock(); values.append(value); lock.unlock() }
            var snapshot: [String] { lock.lock(); defer { lock.unlock() }; return values }
        }
        let deltas = DeltaLog()

        let reply = try await client.chatStream(
            baseURLString: "",
            model: "gpt-5.4-mini",
            messages: [OllamaChatMessage(role: .user, content: "Say hello")],
            timeoutMs: 5_000,
            think: nil,
            temperature: 0.35,
            numPredict: 400,
            numContext: nil,
            keepAlive: "5m",
            onDelta: { deltas.append($0) }
        )

        XCTAssertEqual(reply, "Hello, world")
        // onDelta receives the accumulated text so far, not the increments.
        XCTAssertEqual(deltas.snapshot, ["Hello", "Hello, world"])
    }

    func testGenerateMapsUsageLimitFailure() async {
        let threadID = "thread-limit"
        let (_, _, client) = makeStack { method, id, _ in
            switch method {
            case "thread/start":
                return [["id": id ?? 0, "result": ["thread": ["id": threadID]]]]
            case "turn/start":
                return [
                    ["id": id ?? 0, "result": ["turn": ["id": "t", "status": "inProgress"]]],
                    ["method": "turn/completed", "params": [
                        "threadId": threadID,
                        "turn": [
                            "id": "t",
                            "status": "failed",
                            "error": ["message": "Usage limit reached", "codexErrorInfo": "UsageLimitExceeded"],
                        ],
                    ]],
                ]
            case "account/rateLimits/read":
                return [["id": id ?? 0, "result": [
                    "rateLimits": ["primary": ["usedPercent": 100, "resetsAt": 1_800_000_000]],
                ]]]
            default:
                return []
            }
        }

        do {
            _ = try await client.chat(
                baseURLString: "",
                model: "gpt-5.5",
                messages: [OllamaChatMessage(role: .user, content: "hi")],
                timeoutMs: 5_000,
                think: nil,
                temperature: 0,
                numPredict: 100,
                numContext: nil,
                keepAlive: "5m"
            )
            XCTFail("Expected usage-limit error")
        } catch let error as CodexError {
            guard case .usageLimitReached(let resetsAt) = error else {
                return XCTFail("Expected usageLimitReached, got \(error)")
            }
            XCTAssertEqual(resetsAt, Date(timeIntervalSince1970: 1_800_000_000))
        } catch {
            XCTFail("Expected CodexError, got \(error)")
        }
    }

    func testGenerateMapsUnauthorizedFailureToNotSignedIn() async {
        let threadID = "thread-auth"
        let (_, _, client) = makeStack { method, id, _ in
            switch method {
            case "thread/start":
                return [["id": id ?? 0, "result": ["thread": ["id": threadID]]]]
            case "turn/start":
                return [
                    ["id": id ?? 0, "result": ["turn": ["id": "t", "status": "inProgress"]]],
                    ["method": "error", "params": [
                        "threadId": threadID,
                        "error": ["message": "Token expired", "codexErrorInfo": ["type": "Unauthorized"]],
                    ]],
                ]
            default:
                return []
            }
        }

        do {
            _ = try await client.generate(
                baseURLString: "", model: "gpt-5.5", prompt: "hi", timeoutMs: 5_000,
                think: nil, format: nil, formatJSONSchema: nil,
                temperature: 0, numPredict: 10, numContext: nil, keepAlive: "5m"
            )
            XCTFail("Expected not-signed-in error")
        } catch let error as CodexError {
            guard case .notSignedIn = error else {
                return XCTFail("Expected notSignedIn, got \(error)")
            }
        } catch {
            XCTFail("Expected CodexError, got \(error)")
        }
    }

    func testEmbedIsUnsupported() async {
        let (_, _, client) = makeStack { _, _, _ in [] }
        do {
            _ = try await client.embed(
                baseURLString: "", model: "gpt-5.5", inputs: ["text"],
                timeoutMs: 1_000, keepAlive: "5m", truncate: true
            )
            XCTFail("Expected embed to be unsupported")
        } catch {
            XCTAssertTrue(error.localizedDescription.lowercased().contains("embedding"))
        }
    }

    // MARK: - Health

    func testCheckHealthReportsMissingBinary() async {
        let transport = FakeCodexTransport { _, _, _ in [] }
        let connection = CodexAppServerConnection(
            transportFactory: { _ in transport },
            binaryDiscovery: { nil }
        )
        let client = CodexClient(connection: connection)
        let health = await client.checkHealth(baseURLString: "", timeoutMs: 1_000)
        XCTAssertFalse(health.isReachable)
        XCTAssertTrue(health.message.contains("not found"))
    }

    func testCheckHealthReportsOutdatedBinary() async {
        let transport = FakeCodexTransport { _, _, _ in [] }
        let connection = CodexAppServerConnection(
            transportFactory: { _ in transport },
            binaryDiscovery: { CodexBinaryInfo(path: "/fake/bin/codex", version: "0.100.0") }
        )
        let client = CodexClient(connection: connection)
        let health = await client.checkHealth(baseURLString: "", timeoutMs: 1_000)
        XCTAssertFalse(health.isReachable)
        XCTAssertTrue(health.message.contains("too old"))
    }

    func testCheckHealthRequiresChatGPTSignIn() async {
        let (_, _, client) = makeStack { method, id, _ in
            guard method == "account/read" else { return [] }
            return [["id": id ?? 0, "result": ["account": ["type": "apiKey"]]]]
        }
        let health = await client.checkHealth(baseURLString: "", timeoutMs: 2_000)
        XCTAssertTrue(health.isReachable)
        XCTAssertTrue(health.message.contains("not signed in"))
        XCTAssertTrue(health.installedModels.isEmpty)
    }

    func testCheckHealthSignedInListsModels() async {
        let (_, _, client) = makeStack { method, id, _ in
            switch method {
            case "account/read":
                return [["id": id ?? 0, "result": [
                    "account": ["type": "chatgpt", "email": "user@example.com", "planType": "pro"],
                ]]]
            case "model/list":
                return [["id": id ?? 0, "result": ["data": [["id": "gpt-5.5", "hidden": false]]]]]
            default:
                return []
            }
        }
        let health = await client.checkHealth(baseURLString: "", timeoutMs: 2_000)
        XCTAssertTrue(health.isReachable)
        XCTAssertTrue(health.message.contains("user@example.com"))
        XCTAssertTrue(health.message.contains("pro"))
        XCTAssertEqual(health.installedModels, ["gpt-5.5"])
    }

    // MARK: - Connection behavior

    func testServerInitiatedRequestIsDeclined() async throws {
        let (transport, connection, _) = makeStack { method, id, _ in
            guard method == "account/read" else { return [] }
            return [["id": id ?? 0, "result": ["account": NSNull()]]]
        }
        _ = try await connection.request(method: "account/read")

        // A server->client request (has both method and id) must get an error
        // reply instead of leaving the server hanging on an approval.
        transport.emit(["method": "item/commandExecution/requestApproval", "id": 999, "params": [:]])
        try await Task.sleep(nanoseconds: 200_000_000)

        let reply = transport.sentFrames.first { ($0["id"] as? NSNumber)?.intValue == 999 && $0["error"] != nil }
        let errorObject = reply?["error"] as? [String: Any]
        XCTAssertEqual((errorObject?["code"] as? NSNumber)?.intValue, -32601)
    }

    func testServerExitFailsInFlightRequests() async throws {
        let (transport, connection, _) = makeStack { _, _, _ in [] }

        async let pending: [String: Any] = connection.request(method: "never/answered", timeoutMs: 10_000)
        try await Task.sleep(nanoseconds: 200_000_000)
        await transport.stop()

        do {
            _ = try await pending
            XCTFail("Expected in-flight request to fail on server exit")
        } catch let error as CodexError {
            guard case .serverTerminated = error else {
                return XCTFail("Expected serverTerminated, got \(error)")
            }
        }
    }

    /// Regression: two concurrent first requests must share one server start.
    /// ensureStarted() suspends mid-start (actor reentrancy), which used to
    /// let the second caller spawn a second `codex app-server` whose handshake
    /// frames interleaved with the first — wedging the connection so every
    /// request timed out and browser sign-in never opened.
    func testConcurrentFirstRequestsSpawnOnlyOneServer() async throws {
        final class Counter: @unchecked Sendable {
            private let lock = NSLock()
            private var count = 0
            func increment() { lock.lock(); count += 1; lock.unlock() }
            var value: Int { lock.lock(); defer { lock.unlock() }; return count }
        }

        /// Delays start() so both callers are inside ensureStarted's
        /// suspension window before either finishes spawning.
        final class SlowStartTransport: CodexTransport, @unchecked Sendable {
            let wrapped: FakeCodexTransport
            init(wrapped: FakeCodexTransport) { self.wrapped = wrapped }
            func start() async throws -> AsyncStream<String> {
                try await Task.sleep(nanoseconds: 100_000_000)
                return try await wrapped.start()
            }
            func send(_ line: String) async throws { try await wrapped.send(line) }
            func stop() async { await wrapped.stop() }
        }

        let starts = Counter()
        let connection = CodexAppServerConnection(
            transportFactory: { _ in
                starts.increment()
                return SlowStartTransport(wrapped: FakeCodexTransport { method, id, _ in
                    switch method {
                    case "initialize":
                        return [["id": id ?? 0, "result": ["userAgent": "test"]]]
                    case "initialized":
                        return []
                    default:
                        return [["id": id ?? 0, "result": [:]]]
                    }
                })
            },
            binaryDiscovery: { Self.testBinary }
        )

        async let first: [String: Any] = connection.request(method: "account/read")
        async let second: [String: Any] = connection.request(method: "model/list")
        _ = try await (first, second)

        XCTAssertEqual(starts.value, 1, "Concurrent first requests must not spawn a second app-server")
    }

    func testRequestTimeoutThrows() async {
        let (_, connection, _) = makeStack { _, _, _ in [] }
        do {
            _ = try await connection.request(method: "never/answered", timeoutMs: 150)
            XCTFail("Expected timeout")
        } catch let error as CodexError {
            guard case .timeout = error else {
                return XCTFail("Expected timeout, got \(error)")
            }
        } catch {
            XCTFail("Expected CodexError, got \(error)")
        }
    }

    // MARK: - Static helpers

    func testFlattenedPromptWithSystemAndDialogue() {
        let prompt = CodexClient.flattenedPrompt(messages: [
            OllamaChatMessage(role: .system, content: "You are helpful."),
            OllamaChatMessage(role: .user, content: "First question"),
            OllamaChatMessage(role: .assistant, content: "First answer"),
            OllamaChatMessage(role: .user, content: "Second question"),
        ])
        XCTAssertTrue(prompt.hasPrefix("You are helpful."))
        XCTAssertTrue(prompt.contains("User: First question"))
        XCTAssertTrue(prompt.contains("Assistant: First answer"))
        XCTAssertTrue(prompt.contains("User: Second question"))
        XCTAssertTrue(prompt.contains("Reply as the assistant"))
    }

    func testFlattenedPromptSingleUserMessageStaysPlain() {
        let prompt = CodexClient.flattenedPrompt(messages: [
            OllamaChatMessage(role: .user, content: "Just this"),
        ])
        XCTAssertEqual(prompt, "Just this")
    }

    func testTurnFailureClassification() {
        XCTAssertEqual(
            CodexClient.turnFailure(fromErrorParams: ["error": ["message": "x", "codexErrorInfo": "UsageLimitExceeded"]]).kind,
            .usageLimit
        )
        XCTAssertEqual(
            CodexClient.turnFailure(fromErrorParams: ["error": ["message": "x", "codexErrorInfo": ["type": "ContextWindowExceeded"]]]).kind,
            .contextWindowExceeded
        )
        XCTAssertEqual(
            CodexClient.turnFailure(fromErrorParams: ["error": ["message": "Something else"]]).kind,
            .other
        )
    }

    func testTruncatedPromptKeepsHeadAndMarksTruncation() {
        let long = String(repeating: "a", count: 100)
        let truncated = CodexClient.truncatedPrompt(long, maxChars: 50)
        XCTAssertTrue(truncated.hasPrefix(String(repeating: "a", count: 50)))
        XCTAssertTrue(truncated.contains("truncated"))
        XCTAssertEqual(CodexClient.truncatedPrompt("short", maxChars: 50), "short")
    }

    // MARK: - Account parsing

    func testAccountStateParsing() {
        XCTAssertEqual(
            CodexAccountService.accountState(fromReadResult: [
                "account": ["type": "chatgpt", "email": "a@b.c", "planType": "prolite"],
            ]),
            .signedIn(email: "a@b.c", planType: "prolite")
        )
        XCTAssertEqual(
            CodexAccountService.accountState(fromReadResult: ["account": ["type": "apiKey"]]),
            .apiKeyOnly
        )
        XCTAssertEqual(
            CodexAccountService.accountState(fromReadResult: ["account": NSNull()]),
            .signedOut
        )
        XCTAssertEqual(
            CodexAccountService.accountState(fromReadResult: [:]),
            .signedOut
        )
    }

    func testRateLimitSnapshotParsing() throws {
        let snapshot = try XCTUnwrap(CodexAccountService.rateLimitSnapshot(fromReadResult: [
            "rateLimits": [
                "primary": ["usedPercent": 11, "windowDurationMins": 300, "resetsAt": 1_783_107_934],
                "secondary": ["usedPercent": 21, "windowDurationMins": 10_080],
            ],
        ]))
        XCTAssertEqual(snapshot.primary?.usedPercent, 11)
        XCTAssertEqual(snapshot.primary?.windowDurationMins, 300)
        XCTAssertEqual(snapshot.primary?.resetsAt, Date(timeIntervalSince1970: 1_783_107_934))
        XCTAssertEqual(snapshot.secondary?.usedPercent, 21)
        XCTAssertNil(snapshot.secondary?.resetsAt)
    }
}
