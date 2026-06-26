// OllamaClient.swift
// Orttaai

import Foundation

struct OllamaHealthStatus: Sendable {
    let isReachable: Bool
    let installedModels: [String]
    let message: String
}

struct OllamaPullProgress: Sendable {
    let model: String
    let status: String
    let completedBytes: Int64?
    let totalBytes: Int64?

    var fractionCompleted: Double? {
        guard let completedBytes, let totalBytes, totalBytes > 0 else { return nil }
        return min(1.0, max(0.0, Double(completedBytes) / Double(totalBytes)))
    }
}

struct OllamaCatalogModel: Sendable, Identifiable {
    let name: String
    let sizeBytes: Int64?

    var id: String { name }
}

enum OllamaChatRole: String, Sendable {
    case system
    case user
    case assistant
}

struct OllamaChatMessage: Sendable {
    let role: OllamaChatRole
    let content: String
}

enum OllamaClientError: LocalizedError {
    case invalidBaseURL
    case invalidResponse
    case requestFailed(message: String)
    case httpError(status: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .invalidBaseURL:
            return "Invalid Ollama endpoint URL."
        case .invalidResponse:
            return "Invalid response from Ollama."
        case .requestFailed(let message):
            return message
        case .httpError(let status, let message):
            return "Ollama error \(status): \(message)"
        }
    }
}

actor OllamaClient {
    nonisolated private static let curatedLightweightOllamaModels: [OllamaCatalogModel] = [
        OllamaCatalogModel(name: "gemma3:1b", sizeBytes: nil),
        OllamaCatalogModel(name: "gemma3:4b", sizeBytes: 8_600_000_000),
        OllamaCatalogModel(name: "qwen3.5:0.8b", sizeBytes: nil),
        OllamaCatalogModel(name: "qwen3.5:2b", sizeBytes: nil),
        OllamaCatalogModel(name: "qwen3.5:4b", sizeBytes: nil),
        OllamaCatalogModel(name: "ministral-3:3b", sizeBytes: 4_670_000_000),
        OllamaCatalogModel(name: "granite4:1b", sizeBytes: nil),
        OllamaCatalogModel(name: "granite4:3b", sizeBytes: nil),
    ]

    nonisolated private static let curatedEmbeddingOllamaModels: [OllamaCatalogModel] = [
        OllamaCatalogModel(name: "all-minilm", sizeBytes: 67_000_000),
        OllamaCatalogModel(name: "nomic-embed-text", sizeBytes: 274_000_000),
        OllamaCatalogModel(name: "embeddinggemma", sizeBytes: 622_000_000),
        OllamaCatalogModel(name: "qwen3-embedding:0.6b", sizeBytes: 639_000_000),
    ]

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func checkHealth(baseURLString: String, timeoutMs: Int = 1_200) async -> OllamaHealthStatus {
        do {
            let models = try await fetchModelNames(baseURLString: baseURLString, timeoutMs: timeoutMs)
            let installed = models.sorted()
            if installed.isEmpty {
                return OllamaHealthStatus(
                    isReachable: true,
                    installedModels: [],
                    message: "Ollama is reachable, but no local models are installed yet."
                )
            }

            return OllamaHealthStatus(
                isReachable: true,
                installedModels: installed,
                message: "Ollama is reachable. \(installed.count) model\(installed.count == 1 ? "" : "s") available."
            )
        } catch {
            return OllamaHealthStatus(
                isReachable: false,
                installedModels: [],
                message: "Ollama unreachable: \(error.localizedDescription)"
            )
        }
    }

    func fetchModelNames(baseURLString: String, timeoutMs: Int = 1_200) async throws -> [String] {
        let url = try endpointURL(baseURLString: baseURLString, path: "/api/tags")
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = max(0.08, Double(timeoutMs) / 1_000.0)

        let (data, response) = try await session.data(for: request)
        try validateHTTPResponse(response, data: data)

        let json = try parseJSONObject(data)
        guard let models = json["models"] as? [[String: Any]] else { return [] }
        return models.compactMap { item in
            (item["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        .filter { !$0.isEmpty }
    }

    func generate(
        baseURLString: String,
        model: String,
        prompt: String,
        timeoutMs: Int?,
        think: Bool? = nil,
        format: String? = nil,
        formatJSONSchema: String? = nil,
        temperature: Double = 0,
        numPredict: Int = 220,
        numContext: Int? = nil,
        keepAlive: String = "5m"
    ) async throws -> String {
        let normalizedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedModel.isEmpty else {
            throw OllamaClientError.requestFailed(message: "Missing Ollama model name.")
        }
        guard !normalizedPrompt.isEmpty else {
            throw OllamaClientError.requestFailed(message: "Missing prompt content for Ollama.")
        }

        let url = try endpointURL(baseURLString: baseURLString, path: "/api/generate")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        if let timeoutMs {
            request.timeoutInterval = max(0.08, Double(timeoutMs) / 1_000.0)
        } else {
            request.timeoutInterval = 24 * 60 * 60
        }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var options: [String: Any] = [
            "temperature": temperature,
            "num_predict": max(32, min(16_000, numPredict)),
        ]
        if let numContext {
            options["num_ctx"] = max(2_048, min(262_144, numContext))
        }

        var payload: [String: Any] = [
            "model": normalizedModel,
            "prompt": normalizedPrompt,
            "stream": false,
            "options": options,
            "keep_alive": keepAlive,
        ]
        if let think {
            payload["think"] = think
        }
        if let formatJSONSchema {
            let trimmedSchema = formatJSONSchema.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedSchema.isEmpty {
                let schemaData = Data(trimmedSchema.utf8)
                payload["format"] = try JSONSerialization.jsonObject(with: schemaData, options: [])
            }
        } else if let format {
            let normalizedFormat = format.trimmingCharacters(in: .whitespacesAndNewlines)
            if !normalizedFormat.isEmpty {
                payload["format"] = normalizedFormat
            }
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: payload, options: [])

        let (data, response) = try await session.data(for: request)
        try validateHTTPResponse(response, data: data)

        let json = try parseJSONObject(data)
        let responseText = (json["response"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !responseText.isEmpty else {
            let fields = json.keys.sorted().joined(separator: ", ")
            let doneReason = (json["done_reason"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let thinkingMessage = ((json["thinking"] as? String)?.isEmpty == false)
                ? " Thinking content was present, but no final response was returned."
                : ""
            let reasonMessage = doneReason.map { " done_reason=\($0)." } ?? ""
            throw OllamaClientError.requestFailed(
                message: "Ollama returned an empty generation response. fields=\(fields).\(reasonMessage)\(thinkingMessage)"
            )
        }
        return responseText
    }

    func chat(
        baseURLString: String,
        model: String,
        messages: [OllamaChatMessage],
        timeoutMs: Int? = nil,
        think: Bool? = nil,
        temperature: Double = 0.35,
        numPredict: Int = 1_800,
        numContext: Int? = nil,
        keepAlive: String = "5m"
    ) async throws -> String {
        let normalizedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedMessages = messages
            .map { message in
                OllamaChatMessage(
                    role: message.role,
                    content: message.content.trimmingCharacters(in: .whitespacesAndNewlines)
                )
            }
            .filter { !$0.content.isEmpty }

        guard !normalizedModel.isEmpty else {
            throw OllamaClientError.requestFailed(message: "Missing Ollama model name.")
        }
        guard !normalizedMessages.isEmpty else {
            throw OllamaClientError.requestFailed(message: "Missing chat messages for Ollama.")
        }

        let url = try endpointURL(baseURLString: baseURLString, path: "/api/chat")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        if let timeoutMs {
            request.timeoutInterval = max(0.08, Double(timeoutMs) / 1_000.0)
        } else {
            request.timeoutInterval = 24 * 60 * 60
        }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var options: [String: Any] = [
            "temperature": temperature,
            "num_predict": max(32, min(16_000, numPredict)),
        ]
        if let numContext {
            options["num_ctx"] = max(2_048, min(262_144, numContext))
        }

        var payload: [String: Any] = [
            "model": normalizedModel,
            "messages": normalizedMessages.map { message in
                [
                    "role": message.role.rawValue,
                    "content": message.content,
                ]
            },
            "stream": false,
            "options": options,
            "keep_alive": keepAlive,
        ]
        if let think {
            payload["think"] = think
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: payload, options: [])

        let (data, response) = try await session.data(for: request)
        try validateHTTPResponse(response, data: data)

        let json = try parseJSONObject(data)
        let responseText: String
        if let message = json["message"] as? [String: Any] {
            responseText = (message["content"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        } else {
            responseText = (json["response"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }

        guard !responseText.isEmpty else {
            let fields = json.keys.sorted().joined(separator: ", ")
            let doneReason = (json["done_reason"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let thinkingMessage = ((json["thinking"] as? String)?.isEmpty == false)
                ? " Thinking content was present, but no final response was returned."
                : ""
            let reasonMessage = doneReason.map { " done_reason=\($0)." } ?? ""
            throw OllamaClientError.requestFailed(
                message: "Ollama returned an empty chat response. fields=\(fields).\(reasonMessage)\(thinkingMessage)"
            )
        }
        return responseText
    }

    func embed(
        baseURLString: String,
        model: String,
        inputs: [String],
        timeoutMs: Int? = nil,
        keepAlive: String = "5m",
        truncate: Bool = true
    ) async throws -> [[Float]] {
        let normalizedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedInputs = inputs
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard !normalizedModel.isEmpty else {
            throw OllamaClientError.requestFailed(message: "Missing Ollama embedding model name.")
        }
        guard !normalizedInputs.isEmpty else {
            throw OllamaClientError.requestFailed(message: "Missing text for Ollama embeddings.")
        }

        let url = try endpointURL(baseURLString: baseURLString, path: "/api/embed")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        if let timeoutMs {
            request.timeoutInterval = max(0.08, Double(timeoutMs) / 1_000.0)
        } else {
            request.timeoutInterval = 24 * 60 * 60
        }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let payload: [String: Any] = [
            "model": normalizedModel,
            "input": normalizedInputs,
            "truncate": truncate,
            "keep_alive": keepAlive,
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: payload, options: [])

        let (data, response) = try await session.data(for: request)
        try validateHTTPResponse(response, data: data)

        let json = try parseJSONObject(data)
        let rawEmbeddings: [[Any]]
        if let embeddings = json["embeddings"] as? [[Any]] {
            rawEmbeddings = embeddings
        } else if let embedding = json["embedding"] as? [Any] {
            rawEmbeddings = [embedding]
        } else {
            throw OllamaClientError.invalidResponse
        }

        let embeddings = rawEmbeddings.compactMap { values -> [Float]? in
            let vector = values.compactMap { value -> Float? in
                if let number = value as? NSNumber {
                    return number.floatValue
                }
                if let double = value as? Double {
                    return Float(double)
                }
                if let string = value as? String, let double = Double(string) {
                    return Float(double)
                }
                return nil
            }
            return vector.isEmpty ? nil : vector
        }

        guard embeddings.count == normalizedInputs.count else {
            throw OllamaClientError.requestFailed(
                message: "Ollama returned \(embeddings.count) embeddings for \(normalizedInputs.count) input(s)."
            )
        }
        return embeddings
    }

    func pullModel(
        baseURLString: String,
        model: String,
        timeoutMs: Int = 3_600_000,
        onProgress: ((OllamaPullProgress) -> Void)? = nil
    ) async throws {
        let normalizedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedModel.isEmpty else {
            throw OllamaClientError.requestFailed(message: "Missing model name to install.")
        }

        let url = try endpointURL(baseURLString: baseURLString, path: "/api/pull")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = max(300, Double(timeoutMs) / 1_000.0)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let payload: [String: Any] = [
            "model": normalizedModel,
            "stream": true,
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: payload, options: [])

        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw OllamaClientError.invalidResponse
        }
        guard (200...299).contains(http.statusCode) else {
            throw OllamaClientError.httpError(status: http.statusCode, message: "Failed to start model download.")
        }

        var hasReceivedEvents = false
        var didReportSuccess = false

        for try await line in bytes.lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            guard let data = trimmed.data(using: .utf8),
                  let json = try? parseJSONObject(data) else {
                continue
            }

            if let errorMessage = json["error"] as? String, !errorMessage.isEmpty {
                throw OllamaClientError.requestFailed(message: errorMessage)
            }

            let status = (json["status"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "Downloading model..."
            let completedBytes = anyToInt64(json["completed"])
            let totalBytes = anyToInt64(json["total"])
            let progress = OllamaPullProgress(
                model: normalizedModel,
                status: status,
                completedBytes: completedBytes,
                totalBytes: totalBytes
            )

            onProgress?(progress)
            hasReceivedEvents = true

            let normalizedStatus = status.lowercased()
            if normalizedStatus.contains("success") || normalizedStatus.contains("complete") {
                didReportSuccess = true
            }
        }

        if !hasReceivedEvents {
            throw OllamaClientError.invalidResponse
        }

        if !didReportSuccess {
            onProgress?(
                OllamaPullProgress(
                    model: normalizedModel,
                    status: "Model download finished.",
                    completedBytes: nil,
                    totalBytes: nil
                )
            )
        }
    }

    func fetchLibraryModels(timeoutMs: Int = 3_200, limit: Int = 80) async throws -> [OllamaCatalogModel] {
        _ = timeoutMs
        let catalog = Self.deduplicatedCatalog(Self.curatedLightweightOllamaModels + Self.curatedEmbeddingOllamaModels)
        let boundedLimit = max(1, min(limit, catalog.count))
        return Array(catalog.prefix(boundedLimit))
    }

    func fetchEmbeddingLibraryModels(timeoutMs: Int = 3_200, limit: Int = 20) async throws -> [OllamaCatalogModel] {
        _ = timeoutMs
        let boundedLimit = max(1, min(limit, Self.curatedEmbeddingOllamaModels.count))
        return Array(Self.curatedEmbeddingOllamaModels.prefix(boundedLimit))
    }

    func warmModel(
        baseURLString: String,
        model: String,
        timeoutMs: Int = 35_000,
        keepAlive: String = "5m"
    ) async throws -> Int {
        let startedAt = Date()
        _ = try await generate(
            baseURLString: baseURLString,
            model: model,
            prompt: "Reply with OK.",
            timeoutMs: timeoutMs,
            think: false,
            temperature: 0,
            numPredict: 8,
            keepAlive: keepAlive
        )
        return Int(Date().timeIntervalSince(startedAt) * 1_000)
    }

    private func endpointURL(baseURLString: String, path: String) throws -> URL {
        let trimmed = baseURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = "http://127.0.0.1:11434"
        let raw = trimmed.isEmpty ? fallback : trimmed
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
            if let json = try? parseJSONObject(data),
               let decodedError = json["error"] as? String,
               !decodedError.isEmpty
            {
                throw OllamaClientError.httpError(status: http.statusCode, message: decodedError)
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

    private func anyToInt64(_ value: Any?) -> Int64? {
        if let number = value as? NSNumber {
            return number.int64Value
        }
        if let string = value as? String {
            return Int64(string)
        }
        return nil
    }

    nonisolated private static func deduplicatedCatalog(_ models: [OllamaCatalogModel]) -> [OllamaCatalogModel] {
        var seen = Set<String>()
        return models.filter { model in
            let key = model.name.lowercased()
            guard !seen.contains(key) else { return false }
            seen.insert(key)
            return true
        }
    }

}
