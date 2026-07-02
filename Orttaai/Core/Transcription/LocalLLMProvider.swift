// LocalLLMProvider.swift
// Orttaai

import Foundation

/// Which local inference server powers LLM features (polish, insights, chat,
/// tone analysis, semantic embeddings).
enum LocalLLMProviderKind: String, CaseIterable, Identifiable, Sendable {
    case ollama
    case lmStudio = "lmstudio"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .ollama: return "Ollama"
        case .lmStudio: return "LM Studio"
        }
    }

    var defaultEndpoint: String {
        switch self {
        case .ollama: return "http://127.0.0.1:11434"
        case .lmStudio: return "http://127.0.0.1:1234"
        }
    }

    /// Whether models can be downloaded through the app. Ollama exposes
    /// /api/pull; LM Studio manages downloads inside its own app.
    var supportsModelInstall: Bool { self == .ollama }

    /// Whether the server accepts an explicit think on/off flag per request.
    /// LM Studio's OpenAI-compatible API has no equivalent; reasoning models
    /// decide for themselves there.
    var supportsThinkFlag: Bool { self == .ollama }
}

/// The local-LLM surface the app actually uses. `OllamaClient` implements it
/// with Ollama's native API; `LMStudioClient` implements it over the
/// OpenAI-compatible API — which also makes any other OpenAI-compatible server
/// (llama.cpp, vLLM, mlx_lm.server) reachable through the LM Studio provider.
protocol LocalLLMServing: Sendable {
    var providerKind: LocalLLMProviderKind { get }

    func checkHealth(baseURLString: String, timeoutMs: Int) async -> OllamaHealthStatus
    func fetchModelNames(baseURLString: String, timeoutMs: Int) async throws -> [String]

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
    ) async throws -> String

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
    ) async throws -> String

    func embed(
        baseURLString: String,
        model: String,
        inputs: [String],
        timeoutMs: Int?,
        keepAlive: String,
        truncate: Bool
    ) async throws -> [[Float]]

    func warmModel(
        baseURLString: String,
        model: String,
        timeoutMs: Int,
        keepAlive: String
    ) async throws -> Int
}

/// Shared client instances. `LMStudioClient` caches its model list, so reuse
/// matters; both are actors and safe to share.
enum LocalLLM {
    static let ollamaClient = OllamaClient()
    static let lmStudioClient = LMStudioClient()

    static func client(for kind: LocalLLMProviderKind) -> any LocalLLMServing {
        switch kind {
        case .ollama: return ollamaClient
        case .lmStudio: return lmStudioClient
        }
    }
}
