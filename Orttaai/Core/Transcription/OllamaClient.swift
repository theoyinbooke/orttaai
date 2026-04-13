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
        timeoutMs: Int,
        think: Bool? = nil,
        temperature: Double = 0,
        numPredict: Int = 220,
        keepAlive: String = "20m"
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
        request.timeoutInterval = max(0.08, Double(timeoutMs) / 1_000.0)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let effectiveThink: Bool? = {
            if let think {
                return think
            }
            if normalizedModel.lowercased().hasPrefix("qwen") {
                // Keep polish fast by default for Qwen unless caller explicitly requests thinking.
                return false
            }
            return nil
        }()

        var payload: [String: Any] = [
            "model": normalizedModel,
            "prompt": normalizedPrompt,
            "stream": false,
            "options": [
                "temperature": temperature,
                "num_predict": max(32, min(1_500, numPredict)),
            ],
            "keep_alive": keepAlive,
        ]
        if let effectiveThink {
            payload["think"] = effectiveThink
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: payload, options: [])

        let (data, response) = try await session.data(for: request)
        try validateHTTPResponse(response, data: data)

        let json = try parseJSONObject(data)
        let responseText = (json["response"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !responseText.isEmpty else {
            throw OllamaClientError.invalidResponse
        }
        return responseText
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
        let boundedLimit = max(1, min(limit, Self.curatedLightweightOllamaModels.count))
        return Array(Self.curatedLightweightOllamaModels.prefix(boundedLimit))
    }

    func warmModel(
        baseURLString: String,
        model: String,
        timeoutMs: Int = 35_000,
        keepAlive: String = "30m"
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

}
