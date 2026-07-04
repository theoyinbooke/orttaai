// CodexClient.swift
// Orttaai

import Foundation

/// `LocalLLMServing` implementation backed by OpenAI cloud models through the
/// user's own ChatGPT subscription, via the locally installed Codex CLI's
/// app-server (JSON-RPC over stdio).
///
/// Design constraints (see docs/codex-chatgpt-integration-plan.md):
/// - Pure inference only: every request runs on a fresh **ephemeral** thread
///   with a read-only sandbox and `approvalPolicy: "never"`, so Codex never
///   executes anything on the user's machine and Orttaai turns never appear
///   in the user's Codex session history.
/// - No embeddings: the app-server has no embedding endpoint; semantic
///   embeddings stay on a local provider (`AppSettings.embeddingLLMClient`).
/// - `temperature`/`numPredict`/`numContext`/`keepAlive`/`think` have no
///   app-server equivalents and are ignored; reasoning depth is controlled by
///   the per-provider reasoning-effort setting instead.
actor CodexClient: LocalLLMServing {
    nonisolated var providerKind: LocalLLMProviderKind { .codex }

    static let reasoningEffortKey = "codexReasoningEffort"

    private let connection: CodexAppServerConnection
    private var cachedModelNames: [String] = []
    private var cachedModelNamesAt: Date?
    private static let modelCacheLifetime: TimeInterval = 30
    private static let defaultTurnTimeoutMs = 300_000
    /// Prompt-size cap for the single retry after ContextWindowExceeded.
    private static let contextRetryMaxChars = 48_000

    init(connection: CodexAppServerConnection = .shared) {
        self.connection = connection
    }

    // MARK: - Health & models

    func checkHealth(baseURLString: String, timeoutMs: Int) async -> OllamaHealthStatus {
        guard let info = await connection.detectBinary() else {
            return OllamaHealthStatus(
                isReachable: false,
                installedModels: [],
                message: "Codex CLI not found. Install it with `brew install --cask codex`, then re-check."
            )
        }
        guard CodexBinaryLocator.isVersionSupported(info.version) else {
            return OllamaHealthStatus(
                isReachable: false,
                installedModels: [],
                message: "Codex CLI \(info.version) is too old; Orttaai needs \(CodexBinaryLocator.minimumVersion) or newer. Run `codex update`."
            )
        }
        do {
            let account = try await connection.request(
                method: "account/read",
                params: ["refreshToken": false],
                timeoutMs: timeoutMs
            )
            guard let accountObject = account["account"] as? [String: Any],
                  (accountObject["type"] as? String) == "chatgpt" else {
                return OllamaHealthStatus(
                    isReachable: true,
                    installedModels: [],
                    message: "Codex is installed but not signed in with ChatGPT. Sign in from Settings → Model."
                )
            }
            let email = accountObject["email"] as? String
            let plan = accountObject["planType"] as? String
            let models = (try? await fetchModelNames(baseURLString: baseURLString, timeoutMs: timeoutMs)) ?? []
            var identity = "Signed in with ChatGPT"
            if let email, !email.isEmpty { identity += " as \(email)" }
            if let plan, !plan.isEmpty { identity += " (\(plan))" }
            return OllamaHealthStatus(
                isReachable: true,
                installedModels: models.sorted(),
                message: "\(identity). \(models.count) model\(models.count == 1 ? "" : "s") available."
            )
        } catch {
            return OllamaHealthStatus(
                isReachable: false,
                installedModels: [],
                message: "Codex app server unreachable: \(error.localizedDescription)"
            )
        }
    }

    func fetchModelNames(baseURLString: String, timeoutMs: Int) async throws -> [String] {
        if let cachedAt = cachedModelNamesAt,
           Date().timeIntervalSince(cachedAt) < Self.modelCacheLifetime,
           !cachedModelNames.isEmpty {
            return cachedModelNames
        }
        let result = try await connection.request(
            method: "model/list",
            params: ["limit": 50],
            timeoutMs: timeoutMs
        )
        let entries = result["data"] as? [[String: Any]] ?? []
        let names = entries.compactMap { entry -> String? in
            if (entry["hidden"] as? Bool) == true { return nil }
            let id = (entry["id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return (id?.isEmpty ?? true) ? nil : id
        }
        cachedModelNames = names
        cachedModelNamesAt = Date()
        return names
    }

    /// Full model metadata for the Settings picker (display name, description,
    /// supported reasoning efforts). Not part of `LocalLLMServing`.
    func fetchModelDetails(timeoutMs: Int = 15_000) async throws -> [CodexModelInfo] {
        let result = try await connection.request(
            method: "model/list",
            params: ["limit": 50],
            timeoutMs: timeoutMs
        )
        let entries = result["data"] as? [[String: Any]] ?? []
        return entries.compactMap { entry -> CodexModelInfo? in
            guard let id = entry["id"] as? String, !id.isEmpty,
                  (entry["hidden"] as? Bool) != true else { return nil }
            let efforts = (entry["supportedReasoningEfforts"] as? [[String: Any]])?
                .compactMap { $0["reasoningEffort"] as? String } ?? []
            return CodexModelInfo(
                id: id,
                displayName: entry["displayName"] as? String ?? id,
                summary: entry["description"] as? String ?? "",
                supportedReasoningEfforts: efforts,
                defaultReasoningEffort: entry["defaultReasoningEffort"] as? String,
                isDefault: entry["isDefault"] as? Bool ?? false
            )
        }
    }

    // MARK: - Generation

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
        _ = (think, format, temperature, numPredict, numContext, keepAlive)
        let normalizedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedPrompt.isEmpty else {
            throw OllamaClientError.requestFailed(message: "Missing prompt content for Codex.")
        }
        return try await runTurn(
            model: model,
            prompt: normalizedPrompt,
            formatJSONSchema: formatJSONSchema,
            timeoutMs: timeoutMs,
            allowContextRetry: true
        )
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
        _ = (think, temperature, numPredict, numContext, keepAlive)
        let prompt = Self.flattenedPrompt(messages: messages)
        guard !prompt.isEmpty else {
            throw OllamaClientError.requestFailed(message: "Missing chat messages for Codex.")
        }
        return try await runTurn(
            model: model,
            prompt: prompt,
            formatJSONSchema: nil,
            timeoutMs: timeoutMs,
            allowContextRetry: true
        )
    }

    func chatStream(
        baseURLString: String,
        model: String,
        messages: [OllamaChatMessage],
        timeoutMs: Int?,
        think: Bool?,
        temperature: Double,
        numPredict: Int,
        numContext: Int?,
        keepAlive: String,
        onDelta: @escaping @Sendable (String) -> Void
    ) async throws -> String {
        _ = (think, temperature, numPredict, numContext, keepAlive)
        let prompt = Self.flattenedPrompt(messages: messages)
        guard !prompt.isEmpty else {
            throw OllamaClientError.requestFailed(message: "Missing chat messages for Codex.")
        }
        return try await runTurn(
            model: model,
            prompt: prompt,
            formatJSONSchema: nil,
            timeoutMs: timeoutMs,
            allowContextRetry: true,
            onDelta: onDelta
        )
    }

    func embed(
        baseURLString: String,
        model: String,
        inputs: [String],
        timeoutMs: Int?,
        keepAlive: String,
        truncate: Bool
    ) async throws -> [[Float]] {
        throw OllamaClientError.requestFailed(
            message: "Embeddings are not available through ChatGPT (Codex); Orttaai keeps semantic embeddings on your local model."
        )
    }

    func warmModel(
        baseURLString: String,
        model: String,
        timeoutMs: Int,
        keepAlive: String
    ) async throws -> Int {
        // Cloud models have nothing to preload, and eagerly spawning the
        // app-server at app launch would be wasted work for users who never
        // touch an AI feature that session.
        return 0
    }

    // MARK: - Turn execution

    private func runTurn(
        model: String,
        prompt: String,
        formatJSONSchema: String?,
        timeoutMs: Int?,
        allowContextRetry: Bool,
        onDelta: (@Sendable (String) -> Void)? = nil
    ) async throws -> String {
        let normalizedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedModel.isEmpty else {
            throw OllamaClientError.requestFailed(message: "Missing Codex model name.")
        }
        let effectiveTimeoutMs = timeoutMs ?? Self.defaultTurnTimeoutMs

        do {
            return try await performTurn(
                model: normalizedModel,
                prompt: prompt,
                formatJSONSchema: formatJSONSchema,
                timeoutMs: effectiveTimeoutMs,
                onDelta: onDelta
            )
        } catch let error as CodexTurnFailure {
            switch error.kind {
            case .usageLimit:
                let resetsAt = await readPrimaryResetDate()
                throw CodexError.usageLimitReached(resetsAt: resetsAt)
            case .unauthorized:
                throw CodexError.notSignedIn
            case .contextWindowExceeded:
                guard allowContextRetry, prompt.count > Self.contextRetryMaxChars else {
                    throw OllamaClientError.requestFailed(message: error.message)
                }
                let truncated = Self.truncatedPrompt(prompt, maxChars: Self.contextRetryMaxChars)
                return try await runTurn(
                    model: normalizedModel,
                    prompt: truncated,
                    formatJSONSchema: formatJSONSchema,
                    timeoutMs: timeoutMs,
                    allowContextRetry: false,
                    onDelta: onDelta
                )
            case .other:
                throw OllamaClientError.requestFailed(message: error.message)
            }
        }
    }

    private func performTurn(
        model: String,
        prompt: String,
        formatJSONSchema: String?,
        timeoutMs: Int,
        onDelta: (@Sendable (String) -> Void)? = nil
    ) async throws -> String {
        // Ephemeral + read-only + never-approve: pure inference, no history,
        // no machine access. `sandbox` values are kebab-case on the wire.
        let thread = try await connection.request(
            method: "thread/start",
            params: [
                "model": model,
                "cwd": Self.workspaceDirectory(),
                "approvalPolicy": "never",
                "sandbox": "read-only",
                "ephemeral": true,
            ],
            timeoutMs: 20_000
        )
        guard let threadObject = thread["thread"] as? [String: Any],
              let threadID = threadObject["id"] as? String, !threadID.isEmpty else {
            throw CodexError.invalidResponse
        }

        // Subscribe before starting the turn so no completion event is missed.
        let notifications = try await connection.notifications()

        var turnParams: [String: Any] = [
            "threadId": threadID,
            "input": [["type": "text", "text": prompt]],
        ]
        if let schemaObject = try Self.schemaObject(fromJSONSchema: formatJSONSchema) {
            turnParams["outputSchema"] = schemaObject
        }
        let effort = Self.storedReasoningEffort()
        if !effort.isEmpty {
            turnParams["effort"] = effort
        }

        do {
            _ = try await connection.request(method: "turn/start", params: turnParams, timeoutMs: 20_000)
        } catch let error as CodexError {
            // Older/newer servers may reject fields we send (the app-server
            // API is experimental). Retry once without the effort override.
            if case .rpcError(let code, _) = error, code == -32600, turnParams["effort"] != nil {
                turnParams.removeValue(forKey: "effort")
                _ = try await connection.request(method: "turn/start", params: turnParams, timeoutMs: 20_000)
            } else {
                throw error
            }
        }

        return try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask { [connection] in
                var finalMessage = ""
                var streamed = ""
                for await notification in notifications {
                    guard Self.notification(notification, belongsToThread: threadID) else { continue }
                    switch notification.method {
                    case "item/agentMessage/delta":
                        if let onDelta, let delta = notification.params["delta"] as? String, !delta.isEmpty {
                            streamed += delta
                            onDelta(streamed)
                        }
                    case "item/completed":
                        if let item = notification.params["item"] as? [String: Any],
                           (item["type"] as? String) == "agentMessage",
                           let text = item["text"] as? String {
                            finalMessage = text
                        }
                    case "turn/completed":
                        let turn = notification.params["turn"] as? [String: Any] ?? [:]
                        let status = turn["status"] as? String ?? ""
                        if status == "completed" {
                            let trimmed = finalMessage.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !trimmed.isEmpty else {
                                throw OllamaClientError.requestFailed(message: "Codex returned an empty response.")
                            }
                            return trimmed
                        }
                        throw Self.turnFailure(fromTurn: turn, status: status)
                    case "error":
                        throw Self.turnFailure(fromErrorParams: notification.params)
                    default:
                        break
                    }
                }
                _ = connection
                throw CodexError.serverTerminated
            }
            group.addTask { [connection] in
                try await Task.sleep(nanoseconds: UInt64(max(1, timeoutMs)) * 1_000_000)
                _ = try? await connection.request(
                    method: "turn/interrupt",
                    params: ["threadId": threadID],
                    timeoutMs: 5_000
                )
                throw CodexError.timeout(method: "turn/start")
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw CodexError.invalidResponse }
            return first
        }
    }

    private func readPrimaryResetDate() async -> Date? {
        guard let result = try? await connection.request(method: "account/rateLimits/read", timeoutMs: 8_000),
              let rateLimits = result["rateLimits"] as? [String: Any],
              let primary = rateLimits["primary"] as? [String: Any],
              let resetsAt = (primary["resetsAt"] as? NSNumber)?.doubleValue else {
            return nil
        }
        return Date(timeIntervalSince1970: resetsAt)
    }

    // MARK: - Helpers (nonisolated static for testability)

    nonisolated static func workspaceDirectory() -> String {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("orttaai-codex-workspace", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.path
    }

    nonisolated static func storedReasoningEffort() -> String {
        let stored = UserDefaults.standard.string(forKey: reasoningEffortKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        return stored.isEmpty ? "medium" : stored
    }

    nonisolated static func schemaObject(fromJSONSchema formatJSONSchema: String?) throws -> Any? {
        guard let formatJSONSchema else { return nil }
        let trimmed = formatJSONSchema.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return try JSONSerialization.jsonObject(with: Data(trimmed.utf8), options: [])
    }

    /// The `LocalLLMServing` chat surface is stateless (full history each
    /// call), while app-server threads are stateful. Rather than persisting
    /// threads, flatten the history into a single prompt on an ephemeral
    /// thread — same semantics as the other providers.
    nonisolated static func flattenedPrompt(messages: [OllamaChatMessage]) -> String {
        let normalized = messages
            .map { OllamaChatMessage(role: $0.role, content: $0.content.trimmingCharacters(in: .whitespacesAndNewlines)) }
            .filter { !$0.content.isEmpty }
        guard !normalized.isEmpty else { return "" }

        var sections: [String] = []
        let systemBlocks = normalized.filter { $0.role == .system }.map(\.content)
        if !systemBlocks.isEmpty {
            sections.append(systemBlocks.joined(separator: "\n\n"))
        }

        let dialogue = normalized.filter { $0.role != .system }
        if dialogue.count == 1, let only = dialogue.first, only.role == .user {
            sections.append(only.content)
        } else if !dialogue.isEmpty {
            let transcript = dialogue
                .map { "\($0.role == .user ? "User" : "Assistant"): \($0.content)" }
                .joined(separator: "\n\n")
            sections.append("Conversation so far:\n\n\(transcript)")
            sections.append("Reply as the assistant to the last user message. Respond with the reply only — no role prefix.")
        }
        return sections.joined(separator: "\n\n")
    }

    nonisolated static func truncatedPrompt(_ prompt: String, maxChars: Int) -> String {
        guard prompt.count > maxChars else { return prompt }
        let head = prompt.prefix(maxChars)
        return head + "\n\n[Input truncated to fit the model's context window.]"
    }

    nonisolated static func notification(
        _ notification: CodexServerNotification,
        belongsToThread threadID: String
    ) -> Bool {
        if let id = notification.params["threadId"] as? String {
            return id == threadID
        }
        // Item events may omit threadId on some server versions; accept them
        // (each request runs its own ephemeral thread and short-lived
        // subscription, so cross-talk is unlikely and turn/completed is
        // always thread-scoped).
        return notification.method.hasPrefix("item/")
    }

    nonisolated static func turnFailure(fromTurn turn: [String: Any], status: String) -> CodexTurnFailure {
        if status == "interrupted" {
            return CodexTurnFailure(kind: .other, message: "Codex request was interrupted.")
        }
        let errorObject = turn["error"] as? [String: Any] ?? [:]
        return turnFailure(fromErrorObject: errorObject)
    }

    nonisolated static func turnFailure(fromErrorParams params: [String: Any]) -> CodexTurnFailure {
        let errorObject = params["error"] as? [String: Any] ?? params
        return turnFailure(fromErrorObject: errorObject)
    }

    private nonisolated static func turnFailure(fromErrorObject errorObject: [String: Any]) -> CodexTurnFailure {
        let message = errorObject["message"] as? String ?? "Codex request failed."
        // codexErrorInfo may be a string ("UsageLimitExceeded") or a tagged
        // object ({"type": "UsageLimitExceeded", ...}); match on either.
        var infoText = ""
        if let info = errorObject["codexErrorInfo"] as? String {
            infoText = info
        } else if let info = errorObject["codexErrorInfo"],
                  let data = try? JSONSerialization.data(withJSONObject: info, options: []),
                  let text = String(data: data, encoding: .utf8) {
            infoText = text
        }
        let haystack = (infoText + " " + message).lowercased()
        let kind: CodexTurnFailure.Kind
        if haystack.contains("usagelimit") || haystack.contains("usage limit") {
            kind = .usageLimit
        } else if haystack.contains("unauthorized") {
            kind = .unauthorized
        } else if haystack.contains("contextwindow") || haystack.contains("context window") {
            kind = .contextWindowExceeded
        } else {
            kind = .other
        }
        return CodexTurnFailure(kind: kind, message: message)
    }
}

/// Classified turn failure, internal to CodexClient's error mapping.
struct CodexTurnFailure: Error, Sendable {
    enum Kind: Sendable {
        case usageLimit
        case unauthorized
        case contextWindowExceeded
        case other
    }

    let kind: Kind
    let message: String
}

/// Model metadata surfaced in the Settings picker.
struct CodexModelInfo: Sendable, Identifiable {
    let id: String
    let displayName: String
    let summary: String
    let supportedReasoningEfforts: [String]
    let defaultReasoningEffort: String?
    let isDefault: Bool
}
