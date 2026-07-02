// LMStudioClient.swift
// Orttaai

import Foundation

/// Client for LM Studio's OpenAI-compatible server (default
/// http://127.0.0.1:1234): GET /v1/models, POST /v1/chat/completions (with
/// json_schema structured output), POST /v1/embeddings.
///
/// Two LM Studio behaviors this client papers over:
/// - The server silently falls back to whatever model is loaded when the
///   requested model id doesn't exist, so every request first verifies the
///   model against a short-lived /v1/models cache and fails loudly instead.
/// - There is no keep_alive; LM Studio accepts a "ttl" (seconds) extension,
///   which we derive from the Ollama-style keepAlive strings ("5m", "10m").
actor LMStudioClient: LocalLLMServing {
    nonisolated var providerKind: LocalLLMProviderKind { .lmStudio }

    private let session: URLSession
    private var cachedModelNames: [String] = []
    private var cachedModelNamesAt: Date?
    private var cachedModelNamesEndpoint: String = ""
    private static let modelCacheLifetime: TimeInterval = 30

    init(session: URLSession = .shared) {
        self.session = session
    }

    // MARK: - Health & models

    func checkHealth(baseURLString: String, timeoutMs: Int) async -> OllamaHealthStatus {
        do {
            let models = try await fetchModelNames(baseURLString: baseURLString, timeoutMs: timeoutMs)
            let installed = models.sorted()
            if installed.isEmpty {
                return OllamaHealthStatus(
                    isReachable: true,
                    installedModels: [],
                    message: "LM Studio is reachable, but no models are downloaded yet. Add models in the LM Studio app."
                )
            }
            return OllamaHealthStatus(
                isReachable: true,
                installedModels: installed,
                message: "LM Studio is reachable. \(installed.count) model\(installed.count == 1 ? "" : "s") available."
            )
        } catch {
            return OllamaHealthStatus(
                isReachable: false,
                installedModels: [],
                message: "LM Studio unreachable: \(error.localizedDescription) Start the server from LM Studio's Developer tab (or run `lms server start`)."
            )
        }
    }

    func fetchModelNames(baseURLString: String, timeoutMs: Int) async throws -> [String] {
        let url = try endpointURL(baseURLString: baseURLString, path: "/v1/models")
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = max(0.08, Double(timeoutMs) / 1_000.0)

        let (data, response) = try await session.data(for: request)
        try validateHTTPResponse(response, data: data)

        let json = try parseJSONObject(data)
        guard let entries = json["data"] as? [[String: Any]] else { return [] }
        let names = entries.compactMap { entry in
            (entry["id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        .filter { !$0.isEmpty }

        cachedModelNames = names
        cachedModelNamesAt = Date()
        cachedModelNamesEndpoint = baseURLString
        return names
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
        let normalizedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedPrompt.isEmpty else {
            throw OllamaClientError.requestFailed(message: "Missing prompt content for LM Studio.")
        }
        return try await chat(
            baseURLString: baseURLString,
            model: model,
            messages: [OllamaChatMessage(role: .user, content: normalizedPrompt)],
            timeoutMs: timeoutMs,
            think: think,
            format: format,
            formatJSONSchema: formatJSONSchema,
            temperature: temperature,
            numPredict: numPredict,
            numContext: numContext,
            keepAlive: keepAlive
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
        try await chat(
            baseURLString: baseURLString,
            model: model,
            messages: messages,
            timeoutMs: timeoutMs,
            think: think,
            format: nil,
            formatJSONSchema: nil,
            temperature: temperature,
            numPredict: numPredict,
            numContext: numContext,
            keepAlive: keepAlive
        )
    }

    private func chat(
        baseURLString: String,
        model: String,
        messages: [OllamaChatMessage],
        timeoutMs: Int?,
        think: Bool?,
        format: String?,
        formatJSONSchema: String?,
        temperature: Double,
        numPredict: Int,
        numContext: Int?,
        keepAlive: String
    ) async throws -> String {
        // `think` and `numContext` are Ollama concepts: LM Studio reasoning
        // models decide for themselves, and context length is fixed when the
        // model is loaded in LM Studio.
        _ = think
        _ = numContext

        let normalizedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedMessages = messages
            .map { OllamaChatMessage(role: $0.role, content: $0.content.trimmingCharacters(in: .whitespacesAndNewlines)) }
            .filter { !$0.content.isEmpty }

        guard !normalizedModel.isEmpty else {
            throw OllamaClientError.requestFailed(message: "Missing LM Studio model name.")
        }
        guard !normalizedMessages.isEmpty else {
            throw OllamaClientError.requestFailed(message: "Missing chat messages for LM Studio.")
        }

        try await ensureModelAvailable(normalizedModel, baseURLString: baseURLString)

        let url = try endpointURL(baseURLString: baseURLString, path: "/v1/chat/completions")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeoutMs.map { max(0.08, Double($0) / 1_000.0) } ?? 24 * 60 * 60
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var payload: [String: Any] = [
            "model": normalizedModel,
            "messages": normalizedMessages.map { ["role": $0.role.rawValue, "content": $0.content] },
            "stream": false,
            "temperature": temperature,
            "max_tokens": max(1, min(16_000, numPredict)),
        ]
        if let ttl = Self.ttlSeconds(fromKeepAlive: keepAlive) {
            payload["ttl"] = ttl
        }
        if let responseFormat = try Self.responseFormatPayload(format: format, formatJSONSchema: formatJSONSchema) {
            payload["response_format"] = responseFormat
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: payload, options: [])

        let (data, response) = try await session.data(for: request)
        try validateHTTPResponse(response, data: data)

        let json = try parseJSONObject(data)
        let content = Self.messageContent(fromChatCompletion: json)
        guard let content, !content.isEmpty else {
            let finishReason = Self.finishReason(fromChatCompletion: json).map { " finish_reason=\($0)." } ?? ""
            throw OllamaClientError.requestFailed(
                message: "LM Studio returned an empty response.\(finishReason)"
            )
        }
        return content
    }

    // MARK: - Embeddings

    func embed(
        baseURLString: String,
        model: String,
        inputs: [String],
        timeoutMs: Int?,
        keepAlive: String,
        truncate: Bool
    ) async throws -> [[Float]] {
        _ = truncate // LM Studio truncates to the model's limit automatically.

        let normalizedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedInputs = inputs
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard !normalizedModel.isEmpty else {
            throw OllamaClientError.requestFailed(message: "Missing LM Studio embedding model name.")
        }
        guard !normalizedInputs.isEmpty else {
            throw OllamaClientError.requestFailed(message: "Missing text for LM Studio embeddings.")
        }

        try await ensureModelAvailable(normalizedModel, baseURLString: baseURLString)

        let url = try endpointURL(baseURLString: baseURLString, path: "/v1/embeddings")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeoutMs.map { max(0.08, Double($0) / 1_000.0) } ?? 24 * 60 * 60
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var payload: [String: Any] = [
            "model": normalizedModel,
            "input": normalizedInputs,
        ]
        if let ttl = Self.ttlSeconds(fromKeepAlive: keepAlive) {
            payload["ttl"] = ttl
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: payload, options: [])

        let (data, response) = try await session.data(for: request)
        try validateHTTPResponse(response, data: data)

        let json = try parseJSONObject(data)
        let embeddings = Self.embeddings(fromEmbeddingsResponse: json)
        guard embeddings.count == normalizedInputs.count else {
            throw OllamaClientError.requestFailed(
                message: "LM Studio returned \(embeddings.count) embeddings for \(normalizedInputs.count) input(s)."
            )
        }
        return embeddings
    }

    // MARK: - Warm-up

    func warmModel(
        baseURLString: String,
        model: String,
        timeoutMs: Int,
        keepAlive: String
    ) async throws -> Int {
        let startedAt = Date()
        _ = try await generate(
            baseURLString: baseURLString,
            model: model,
            prompt: "Reply with OK.",
            timeoutMs: timeoutMs,
            think: false,
            format: nil,
            formatJSONSchema: nil,
            temperature: 0,
            numPredict: 8,
            numContext: nil,
            keepAlive: keepAlive
        )
        return Int(Date().timeIntervalSince(startedAt) * 1_000)
    }

    // MARK: - Model verification

    /// LM Studio silently substitutes a loaded model when the requested id is
    /// unknown; verify against the (cached) model list and fail loudly.
    private func ensureModelAvailable(_ model: String, baseURLString: String) async throws {
        let names: [String]
        if let cachedAt = cachedModelNamesAt,
           cachedModelNamesEndpoint == baseURLString,
           Date().timeIntervalSince(cachedAt) < Self.modelCacheLifetime,
           !cachedModelNames.isEmpty {
            names = cachedModelNames
        } else {
            names = try await fetchModelNames(baseURLString: baseURLString, timeoutMs: 4_000)
        }

        let target = model.lowercased()
        guard names.contains(where: { $0.lowercased() == target }) else {
            throw OllamaClientError.requestFailed(
                message: "Model \"\(model)\" is not available in LM Studio. Download or load it in the LM Studio app, then pick it from the model list."
            )
        }
    }

    // MARK: - Payload/parsing helpers (nonisolated static for testability)

    /// "5m" → 300, "90s" → 90, "1h" → 3600, "300" → 300. Nil for unparseable.
    nonisolated static func ttlSeconds(fromKeepAlive keepAlive: String) -> Int? {
        let trimmed = keepAlive.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return nil }
        if let seconds = Int(trimmed) {
            return seconds > 0 ? seconds : nil
        }
        guard let unit = trimmed.last, let value = Int(trimmed.dropLast()) else { return nil }
        guard value > 0 else { return nil }
        switch unit {
        case "s": return value
        case "m": return value * 60
        case "h": return value * 3_600
        default: return nil
        }
    }

    nonisolated static func responseFormatPayload(
        format: String?,
        formatJSONSchema: String?
    ) throws -> [String: Any]? {
        if let formatJSONSchema {
            let trimmedSchema = formatJSONSchema.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedSchema.isEmpty {
                let schemaObject = try JSONSerialization.jsonObject(with: Data(trimmedSchema.utf8), options: [])
                return [
                    "type": "json_schema",
                    "json_schema": [
                        "name": "structured_response",
                        "strict": true,
                        "schema": schemaObject,
                    ],
                ]
            }
        }
        if let format, format.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "json" {
            return ["type": "json_object"]
        }
        return nil
    }

    nonisolated static func messageContent(fromChatCompletion json: [String: Any]) -> String? {
        guard let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else {
            return nil
        }
        let stripped = strippingThinkTags(content).trimmingCharacters(in: .whitespacesAndNewlines)
        return stripped.isEmpty ? nil : stripped
    }

    nonisolated static func finishReason(fromChatCompletion json: [String: Any]) -> String? {
        guard let choices = json["choices"] as? [[String: Any]] else { return nil }
        return choices.first?["finish_reason"] as? String
    }

    nonisolated static func embeddings(fromEmbeddingsResponse json: [String: Any]) -> [[Float]] {
        guard let data = json["data"] as? [[String: Any]] else { return [] }
        return data
            .sorted { lhs, rhs in
                let lhsIndex = (lhs["index"] as? NSNumber)?.intValue ?? 0
                let rhsIndex = (rhs["index"] as? NSNumber)?.intValue ?? 0
                return lhsIndex < rhsIndex
            }
            .compactMap { entry -> [Float]? in
                guard let values = entry["embedding"] as? [Any] else { return nil }
                let vector = values.compactMap { value -> Float? in
                    (value as? NSNumber)?.floatValue
                }
                return vector.isEmpty ? nil : vector
            }
    }

    /// Some reasoning models inline their chain of thought in <think> tags
    /// even over the OpenAI-compatible API; strip it from user-facing output.
    nonisolated static func strippingThinkTags(_ text: String) -> String {
        guard text.contains("<think>") else { return text }
        return text.replacingOccurrences(
            of: #"<think>[\s\S]*?</think>"#,
            with: "",
            options: .regularExpression
        )
    }

    // MARK: - HTTP plumbing

    private func endpointURL(baseURLString: String, path: String) throws -> URL {
        let trimmed = baseURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        let raw = trimmed.isEmpty ? LocalLLMProviderKind.lmStudio.defaultEndpoint : trimmed
        guard let baseURL = URL(string: raw) else {
            throw OllamaClientError.invalidBaseURL
        }
        let cleanPath = path.hasPrefix("/") ? String(path.dropFirst()) : path
        return baseURL.appendingPathComponent(cleanPath)
    }

    private func validateHTTPResponse(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else {
            throw OllamaClientError.invalidResponse
        }
        guard (200...299).contains(http.statusCode) else {
            if let json = try? parseJSONObject(data) {
                if let errorObject = json["error"] as? [String: Any],
                   let message = errorObject["message"] as? String, !message.isEmpty {
                    throw OllamaClientError.httpError(status: http.statusCode, message: message)
                }
                if let message = json["error"] as? String, !message.isEmpty {
                    throw OllamaClientError.httpError(status: http.statusCode, message: message)
                }
            }
            if let body = String(data: data, encoding: .utf8), !body.isEmpty {
                throw OllamaClientError.httpError(status: http.statusCode, message: body)
            }
            throw OllamaClientError.httpError(status: http.statusCode, message: "Unknown error")
        }
    }

    private func parseJSONObject(_ data: Data) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw OllamaClientError.invalidResponse
        }
        return object
    }
}
