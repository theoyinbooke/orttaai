// CodexAppServerConnection.swift
// Orttaai

import Foundation

// MARK: - Errors

enum CodexError: LocalizedError {
    case binaryNotFound
    case binaryOutdated(found: String, required: String)
    case notSignedIn
    case serverStartFailed(message: String)
    case serverTerminated
    case rpcError(code: Int, message: String)
    case timeout(method: String)
    case invalidResponse
    case usageLimitReached(resetsAt: Date?)
    case unsupported(String)

    var errorDescription: String? {
        switch self {
        case .binaryNotFound:
            return "Codex CLI not found. Install it with `brew install --cask codex`, then re-check."
        case .binaryOutdated(let found, let required):
            return "Codex CLI \(found) is too old; Orttaai needs \(required) or newer. Run `codex update` or `brew upgrade --cask codex`."
        case .notSignedIn:
            return "Not signed in to ChatGPT. Sign in from Settings → Model → ChatGPT (Codex)."
        case .serverStartFailed(let message):
            return "Could not start the Codex app server: \(message)"
        case .serverTerminated:
            return "The Codex app server stopped unexpectedly."
        case .rpcError(let code, let message):
            return "Codex error \(code): \(message)"
        case .timeout(let method):
            return "Codex request timed out (\(method))."
        case .invalidResponse:
            return "Invalid response from the Codex app server."
        case .usageLimitReached(let resetsAt):
            if let resetsAt {
                let formatter = DateFormatter()
                formatter.dateStyle = .none
                formatter.timeStyle = .short
                return "You've reached your ChatGPT usage limit. It resets around \(formatter.string(from: resetsAt))."
            }
            return "You've reached your ChatGPT usage limit. Try again later."
        case .unsupported(let message):
            return message
        }
    }
}

// MARK: - Binary discovery

struct CodexBinaryInfo: Sendable {
    let path: String
    let version: String
}

/// Locates a user-installed Codex CLI. Orttaai deliberately does not bundle
/// the binary (~240 MB); users install it themselves via Homebrew or npm.
enum CodexBinaryLocator {
    /// Minimum CLI version whose app-server protocol Orttaai has been
    /// validated against (see docs/codex-chatgpt-integration-plan.md §8).
    static let minimumVersion = "0.142.0"

    /// UserDefaults key for a manual path override set from Settings.
    static let overridePathKey = "codexBinaryPathOverride"

    static func discover() -> CodexBinaryInfo? {
        for path in candidatePaths() {
            guard FileManager.default.isExecutableFile(atPath: path) else { continue }
            if let version = readVersion(atPath: path) {
                return CodexBinaryInfo(path: path, version: version)
            }
        }
        return nil
    }

    static func candidatePaths() -> [String] {
        var paths: [String] = []
        let override = UserDefaults.standard.string(forKey: overridePathKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let override, !override.isEmpty {
            paths.append(override)
        }
        paths.append(contentsOf: [
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
            (NSHomeDirectory() as NSString).appendingPathComponent(".local/bin/codex"),
        ])
        if let fromPath = searchEnvironmentPath() {
            paths.append(fromPath)
        }
        return paths
    }

    static func isVersionSupported(_ version: String) -> Bool {
        compareVersions(version, minimumVersion) >= 0
    }

    /// Parses "codex-cli 0.142.5" (or a bare "0.142.5") into the version string.
    static func parseVersionOutput(_ output: String) -> String? {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let token = trimmed.split(separator: " ").last.map(String.init) ?? trimmed
        let numeric = token.trimmingCharacters(in: CharacterSet(charactersIn: "v"))
        guard numeric.split(separator: ".").allSatisfy({ Int($0.prefix(while: \.isNumber)) != nil }),
              numeric.contains(".") else {
            return nil
        }
        return numeric
    }

    static func compareVersions(_ lhs: String, _ rhs: String) -> Int {
        let lhsParts = lhs.split(separator: ".").map { Int($0.prefix(while: \.isNumber)) ?? 0 }
        let rhsParts = rhs.split(separator: ".").map { Int($0.prefix(while: \.isNumber)) ?? 0 }
        for index in 0..<max(lhsParts.count, rhsParts.count) {
            let left = index < lhsParts.count ? lhsParts[index] : 0
            let right = index < rhsParts.count ? rhsParts[index] : 0
            if left != right { return left < right ? -1 : 1 }
        }
        return 0
    }

    private static func readVersion(atPath path: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["--version"]
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return nil
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8) else { return nil }
        return parseVersionOutput(output)
    }

    private static func searchEnvironmentPath() -> String? {
        guard let pathVariable = ProcessInfo.processInfo.environment["PATH"] else { return nil }
        for directory in pathVariable.split(separator: ":") {
            let candidate = (String(directory) as NSString).appendingPathComponent("codex")
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }
}

// MARK: - Transport

/// One newline-delimited JSON frame in either direction. Abstracted so tests
/// can replay captured frames without spawning the real 240 MB binary.
protocol CodexTransport: Sendable {
    /// Launches the underlying server and returns a stream of incoming lines.
    /// The stream finishes when the server exits or the transport is stopped.
    func start() async throws -> AsyncStream<String>
    func send(_ line: String) async throws
    func stop() async
}

/// Real transport: spawns `codex app-server` and speaks JSONL over its pipes.
final class CodexProcessTransport: CodexTransport, @unchecked Sendable {
    /// Orttaai turns are pure inference (read-only sandbox, never-approve,
    /// no tools), but by default the app-server boots every configured
    /// Codex plugin/app MCP server before sending the model request —
    /// measured at 2-3s of dead time per turn on a plugin-heavy install.
    /// Disabling both feature layers only affects this spawned process,
    /// never the user's own Codex CLI or desktop app.
    static let appServerArguments = [
        "app-server",
        "-c", "features.plugins=false",
        "-c", "features.apps=false",
    ]

    private let binaryPath: String
    private let queue = DispatchQueue(label: "orttaai.codex.transport")
    private var process: Process?
    private var stdinHandle: FileHandle?

    init(binaryPath: String) {
        self.binaryPath = binaryPath
    }

    func start() async throws -> AsyncStream<String> {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binaryPath)
        process.arguments = Self.appServerArguments
        // Codex resolves its own home (~/.codex) from the environment; pass it
        // through unchanged so auth.json and config are found.
        process.environment = ProcessInfo.processInfo.environment

        let stdin = Pipe()
        let stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice

        let readingHandle = stdout.fileHandleForReading
        let (stream, continuation) = AsyncStream.makeStream(of: String.self, bufferingPolicy: .unbounded)

        process.terminationHandler = { _ in
            continuation.finish()
        }

        do {
            try process.run()
        } catch {
            throw CodexError.serverStartFailed(message: error.localizedDescription)
        }

        queue.sync {
            self.process = process
            self.stdinHandle = stdin.fileHandleForWriting
        }

        Task.detached {
            var buffer = Data()
            do {
                for try await byte in readingHandle.bytes {
                    if byte == UInt8(ascii: "\n") {
                        if let line = String(data: buffer, encoding: .utf8), !line.isEmpty {
                            continuation.yield(line)
                        }
                        buffer.removeAll(keepingCapacity: true)
                    } else {
                        buffer.append(byte)
                    }
                }
            } catch {
                // Pipe closed; termination handler finishes the stream.
            }
            continuation.finish()
        }

        return stream
    }

    func send(_ line: String) async throws {
        let handle: FileHandle? = queue.sync { stdinHandle }
        guard let handle else { throw CodexError.serverTerminated }
        guard let data = (line + "\n").data(using: .utf8) else { throw CodexError.invalidResponse }
        do {
            try handle.write(contentsOf: data)
        } catch {
            throw CodexError.serverTerminated
        }
    }

    func stop() async {
        let (process, handle): (Process?, FileHandle?) = queue.sync { (self.process, self.stdinHandle) }
        try? handle?.close()
        process?.terminate()
        queue.sync {
            self.process = nil
            self.stdinHandle = nil
        }
    }
}

// MARK: - Notifications

/// A server-initiated JSON-RPC notification (no id), e.g. turn/completed,
/// item/completed, account/login/completed, account/rateLimits/updated.
struct CodexServerNotification: @unchecked Sendable {
    let method: String
    let params: [String: Any]
}

// MARK: - Connection

/// Owns one `codex app-server` process and multiplexes JSON-RPC over it:
/// request/response correlation by id, notification fan-out, the
/// initialize/initialized handshake, lazy start, idle shutdown, and
/// crash recovery. The app-server API is experimental, so all decoding here
/// is defensive: unknown fields and methods are tolerated, never fatal.
actor CodexAppServerConnection {
    static let shared = CodexAppServerConnection()

    /// Idle window after the last request before the server is shut down.
    private static let idleShutdownInterval: TimeInterval = 300
    /// Give up spawning if this many launches fail within `crashWindow`.
    private static let maxLaunchAttempts = 3
    private static let crashWindow: TimeInterval = 60
    private static let defaultRequestTimeoutMs = 15_000

    private let transportFactory: @Sendable (String) -> any CodexTransport
    private let binaryDiscovery: @Sendable () -> CodexBinaryInfo?

    private var transport: (any CodexTransport)?
    private var startTask: Task<Void, any Error>?
    private var readTask: Task<Void, Never>?
    private var idleTask: Task<Void, Never>?
    private var nextRequestID = 1
    private var pending: [Int: CheckedContinuation<[String: Any], any Error>] = [:]
    private var subscribers: [UUID: AsyncStream<CodexServerNotification>.Continuation] = [:]
    private var recentLaunchFailures: [Date] = []
    private var lastActivityAt = Date()
    private(set) var binaryInfo: CodexBinaryInfo?

    init(
        transportFactory: @escaping @Sendable (String) -> any CodexTransport = { CodexProcessTransport(binaryPath: $0) },
        binaryDiscovery: @escaping @Sendable () -> CodexBinaryInfo? = { CodexBinaryLocator.discover() }
    ) {
        self.transportFactory = transportFactory
        self.binaryDiscovery = binaryDiscovery
    }

    // MARK: Public API

    /// Sends a request and returns the `result` object. Starts the server and
    /// performs the handshake on first use.
    func request(
        method: String,
        params: [String: Any] = [:],
        timeoutMs: Int = CodexAppServerConnection.defaultRequestTimeoutMs
    ) async throws -> [String: Any] {
        try await ensureStarted()
        return try await sendRequest(method: method, params: params, timeoutMs: timeoutMs)
    }

    /// Subscribes to server notifications. The stream ends when the server
    /// stops. Cancel the consuming task to unsubscribe.
    func notifications() async throws -> AsyncStream<CodexServerNotification> {
        try await ensureStarted()
        let id = UUID()
        let (stream, continuation) = AsyncStream.makeStream(
            of: CodexServerNotification.self,
            bufferingPolicy: .unbounded
        )
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeSubscriber(id) }
        }
        subscribers[id] = continuation
        return stream
    }

    /// Sends a JSON-RPC notification (no response expected).
    func notify(method: String, params: [String: Any] = [:]) async throws {
        try await ensureStarted()
        var frame: [String: Any] = ["method": method]
        if !params.isEmpty { frame["params"] = params }
        try await sendFrame(frame)
    }

    /// True when a codex binary is installed, regardless of server state.
    func detectBinary() -> CodexBinaryInfo? {
        binaryDiscovery()
    }

    /// Stops the server if running. Safe to call at app termination.
    func shutdown() async {
        await stopServer(failInFlight: true)
    }

    // MARK: Lifecycle

    private func ensureStarted() async throws {
        if transport != nil {
            lastActivityAt = Date()
            return
        }

        // The actor suspends inside startServer() (spawn + handshake), so a
        // second concurrent first caller re-enters here while transport is
        // still nil and would spawn a second process whose handshake frames
        // interleave with the first. Piggyback on the in-flight start instead.
        if let startTask {
            try await startTask.value
            lastActivityAt = Date()
            return
        }

        let task = Task { try await startServer() }
        startTask = task
        defer { startTask = nil }
        try await task.value
    }

    private func startServer() async throws {
        let now = Date()
        recentLaunchFailures.removeAll { now.timeIntervalSince($0) > Self.crashWindow }
        guard recentLaunchFailures.count < Self.maxLaunchAttempts else {
            throw CodexError.serverStartFailed(
                message: "The Codex app server failed to start \(Self.maxLaunchAttempts) times in a row. Run `codex doctor` to diagnose, then try again."
            )
        }

        guard let info = binaryDiscovery() else {
            throw CodexError.binaryNotFound
        }
        guard CodexBinaryLocator.isVersionSupported(info.version) else {
            throw CodexError.binaryOutdated(found: info.version, required: CodexBinaryLocator.minimumVersion)
        }
        binaryInfo = info

        let transport = transportFactory(info.path)
        let lines: AsyncStream<String>
        do {
            lines = try await transport.start()
        } catch {
            recentLaunchFailures.append(Date())
            throw error
        }

        self.transport = transport
        lastActivityAt = Date()

        readTask = Task { [weak self] in
            for await line in lines {
                await self?.handleIncomingLine(line)
            }
            await self?.handleServerExit()
        }

        do {
            try await performHandshake()
        } catch {
            recentLaunchFailures.append(Date())
            await stopServer(failInFlight: true)
            throw error
        }

        startIdleWatchdog()
    }

    private func performHandshake() async throws {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
        _ = try await sendRequest(
            method: "initialize",
            params: [
                "clientInfo": [
                    "name": "orttaai",
                    "title": "Orttaai",
                    "version": version,
                ],
            ],
            timeoutMs: 10_000
        )
        try await sendFrame(["method": "initialized", "params": [String: Any]()])
    }

    private func startIdleWatchdog() {
        idleTask?.cancel()
        idleTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                guard let self else { return }
                if await self.shouldIdleShutdown() {
                    await self.stopServer(failInFlight: false)
                    return
                }
            }
        }
    }

    private func shouldIdleShutdown() -> Bool {
        transport != nil
            && pending.isEmpty
            && subscribers.isEmpty
            && Date().timeIntervalSince(lastActivityAt) > Self.idleShutdownInterval
    }

    private func stopServer(failInFlight: Bool) async {
        let transport = self.transport
        self.transport = nil
        readTask?.cancel()
        readTask = nil
        idleTask?.cancel()
        idleTask = nil
        if let transport {
            await transport.stop()
        }
        if failInFlight {
            failAllPending(with: CodexError.serverTerminated)
        }
        finishAllSubscribers()
    }

    private func handleServerExit() {
        guard transport != nil else { return }
        transport = nil
        readTask = nil
        idleTask?.cancel()
        idleTask = nil
        recentLaunchFailures.append(Date())
        failAllPending(with: CodexError.serverTerminated)
        finishAllSubscribers()
    }

    private func failAllPending(with error: any Error) {
        let waiting = pending
        pending.removeAll()
        for continuation in waiting.values {
            continuation.resume(throwing: error)
        }
    }

    private func finishAllSubscribers() {
        let active = subscribers
        subscribers.removeAll()
        for continuation in active.values {
            continuation.finish()
        }
    }

    private func removeSubscriber(_ id: UUID) {
        subscribers.removeValue(forKey: id)
    }

    // MARK: Wire protocol

    private func sendRequest(method: String, params: [String: Any], timeoutMs: Int) async throws -> [String: Any] {
        let id = nextRequestID
        nextRequestID += 1
        lastActivityAt = Date()

        var frame: [String: Any] = ["method": method, "id": id]
        if !params.isEmpty { frame["params"] = params }

        // The pending continuation can't observe cancellation, so the timeout
        // resolves it explicitly through the actor instead of racing tasks.
        let timeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(1, timeoutMs)) * 1_000_000)
            guard !Task.isCancelled else { return }
            await self?.failPending(id: id, error: CodexError.timeout(method: method))
        }
        defer { timeoutTask.cancel() }

        return try await withCheckedThrowingContinuation { continuation in
            Task { await self.registerPending(id: id, continuation: continuation, frame: frame) }
        }
    }

    private func failPending(id: Int, error: any Error) {
        if let continuation = pending.removeValue(forKey: id) {
            continuation.resume(throwing: error)
        }
    }

    private func registerPending(
        id: Int,
        continuation: CheckedContinuation<[String: Any], any Error>,
        frame: [String: Any]
    ) async {
        pending[id] = continuation
        do {
            try await sendFrame(frame)
        } catch {
            if let waiting = pending.removeValue(forKey: id) {
                waiting.resume(throwing: error)
            }
        }
    }

    private func sendFrame(_ frame: [String: Any]) async throws {
        guard let transport else { throw CodexError.serverTerminated }
        let data = try JSONSerialization.data(withJSONObject: frame, options: [])
        guard let line = String(data: data, encoding: .utf8) else { throw CodexError.invalidResponse }
        try await transport.send(line)
    }

    private func handleIncomingLine(_ line: String) async {
        guard let data = line.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return
        }
        lastActivityAt = Date()

        let method = object["method"] as? String
        let id = (object["id"] as? NSNumber)?.intValue

        if let method, let id {
            // Server-initiated request (approvals, token refresh). With
            // approvalPolicy "never" and read-only ephemeral threads these
            // shouldn't occur; decline instead of leaving the server hanging.
            let reply: [String: Any] = [
                "id": id,
                "error": ["code": -32601, "message": "Request \(method) is not supported by Orttaai."],
            ]
            try? await sendFrame(reply)
            return
        }

        if let method {
            let params = object["params"] as? [String: Any] ?? [:]
            let notification = CodexServerNotification(method: method, params: params)
            for continuation in subscribers.values {
                continuation.yield(notification)
            }
            return
        }

        if let id, let continuation = pending.removeValue(forKey: id) {
            if let errorObject = object["error"] as? [String: Any] {
                let code = (errorObject["code"] as? NSNumber)?.intValue ?? -1
                let message = errorObject["message"] as? String ?? "Unknown error"
                continuation.resume(throwing: CodexError.rpcError(code: code, message: message))
            } else if let result = object["result"] as? [String: Any] {
                continuation.resume(returning: result)
            } else {
                // Result may legitimately be an empty object or non-dictionary.
                continuation.resume(returning: [:])
            }
        }
    }
}
