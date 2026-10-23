// LocalLLMProvider.swift
// Orttaai

import Foundation

/// Which local model server powers LLM features (polish, insights, chat,
/// tone analysis, semantic embeddings). Orttaai only talks to servers on the
/// user's own hardware; there is no cloud provider.
enum LocalLLMProviderKind: String, CaseIterable, Identifiable, Sendable {
    case ollama
    /// LM Studio's server, which Bionic (LM Studio's agent app) also runs:
    /// same port, same endpoints, same model library.
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

/// nomic-embed-text, the embedding model Orttaai recommends for semantic
/// memory. Optional: without it, semantic memory falls back to keywords.
/// The user's own server downloads, stores and serves it; Orttaai never
/// hosts model files.
extension LocalLLMProviderKind {
    static let recommendedEmbeddingName = "nomic-embed-text"

    /// What to ask the server to download: Ollama's library name, or for LM
    /// Studio the model's Hugging Face repository.
    var recommendedEmbeddingDownload: String {
        switch self {
        case .ollama: return "nomic-embed-text"
        case .lmStudio: return "https://huggingface.co/nomic-ai/nomic-embed-text-v1.5-GGUF"
        }
    }

    /// Roughly how much the server downloads, when known.
    var recommendedEmbeddingSize: String? {
        switch self {
        case .ollama: return "274 MB"
        case .lmStudio: return nil
        }
    }

    /// The installed copy, under whatever name the server gave it
    /// ("nomic-embed-text:latest", "text-embedding-nomic-embed-text-v1.5").
    static func installedRecommendedEmbeddingModel(in models: [String]) -> String? {
        models.first { $0.lowercased().contains(recommendedEmbeddingName) }
    }
}

/// The local-LLM surface the app actually uses. `OllamaClient` implements it
/// with Ollama's native API; `LMStudioClient` implements it over the
/// OpenAI-compatible API — which also makes any other OpenAI-compatible server
/// (llama.cpp, vLLM, mlx_lm.server) reachable through the LM Studio provider.
protocol LocalLLMServing: Sendable {
    var providerKind: LocalLLMProviderKind { get }

    func checkHealth(baseURLString: String, timeoutMs: Int) async -> OllamaHealthStatus
    func fetchModelNames(baseURLString: String, timeoutMs: Int) async throws -> [String]
    /// What a model can do as the provider reports it ("completion",
    /// "thinking", "embedding"…), or nil when the provider doesn't say.
    func modelCapabilities(baseURLString: String, model: String, timeoutMs: Int) async -> Set<String>?

    /// Asks the server to download a model, which it then stores and serves.
    /// `onProgress` reports the download as it goes; returns when it's done.
    func downloadModel(
        baseURLString: String,
        model: String,
        onProgress: @escaping @Sendable (OllamaPullProgress) -> Void
    ) async throws

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

    /// Streaming variant of `chat`. `onDelta` receives the accumulated
    /// response text so far (not the increment) each time more arrives, so a
    /// consumer can replace its display content wholesale; `onThinking` does
    /// the same for a thinking model's reasoning, when the provider streams
    /// it. The complete reply is still returned at the end exactly like `chat`.
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
        onDelta: @escaping @Sendable (String) -> Void,
        onThinking: @escaping @Sendable (String) -> Void
    ) async throws -> String
}

extension LocalLLMServing {
    func modelCapabilities(baseURLString: String, model: String, timeoutMs: Int) async -> Set<String>? {
        nil
    }

    func downloadModel(
        baseURLString: String,
        model: String,
        onProgress: @escaping @Sendable (OllamaPullProgress) -> Void
    ) async throws {
        throw OllamaClientError.requestFailed(message: "\(providerKind.displayName) can't download models from Orttaai.")
    }

    /// `chatStream` for callers that don't show reasoning.
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
        try await chatStream(
            baseURLString: baseURLString,
            model: model,
            messages: messages,
            timeoutMs: timeoutMs,
            think: think,
            temperature: temperature,
            numPredict: numPredict,
            numContext: numContext,
            keepAlive: keepAlive,
            onDelta: onDelta,
            onThinking: { _ in }
        )
    }

    /// Providers without token streaming fall back to the blocking call;
    /// the callbacks are never invoked and the caller renders the returned reply.
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
        onDelta: @escaping @Sendable (String) -> Void,
        onThinking: @escaping @Sendable (String) -> Void
    ) async throws -> String {
        try await chat(
            baseURLString: baseURLString,
            model: model,
            messages: messages,
            timeoutMs: timeoutMs,
            think: think,
            temperature: temperature,
            numPredict: numPredict,
            numContext: numContext,
            keepAlive: keepAlive
        )
    }
}

/// Shared client instances. `LMStudioClient` caches its model list, so
/// reuse matters; both are actors and safe to share.
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
