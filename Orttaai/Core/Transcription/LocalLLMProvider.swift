// LocalLLMProvider.swift
// Orttaai

import Foundation

/// Which inference provider powers LLM features (polish, insights, chat,
/// tone analysis, semantic embeddings). Ollama and LM Studio are local
/// servers; Codex routes to OpenAI cloud models through the user's own
/// ChatGPT subscription via the locally installed Codex CLI.
enum LocalLLMProviderKind: String, CaseIterable, Identifiable, Sendable {
    case ollama
    case lmStudio = "lmstudio"
    case codex

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .ollama: return "Ollama"
        case .lmStudio: return "LM Studio"
        case .codex: return "ChatGPT (Codex)"
        }
    }

    var defaultEndpoint: String {
        switch self {
        case .ollama: return "http://127.0.0.1:11434"
        case .lmStudio: return "http://127.0.0.1:1234"
        case .codex: return ""
        }
    }

    /// Whether models can be downloaded through the app. Ollama exposes
    /// /api/pull; LM Studio manages downloads inside its own app; Codex
    /// models are hosted by OpenAI.
    var supportsModelInstall: Bool { self == .ollama }

    /// Whether the server accepts an explicit think on/off flag per request.
    /// LM Studio's OpenAI-compatible API has no equivalent; reasoning models
    /// decide for themselves there. Codex uses a reasoning-effort setting.
    var supportsThinkFlag: Bool { self == .ollama }

    /// Whether the provider is reached over a user-configurable HTTP endpoint.
    /// Codex is a spawned subprocess, so there is nothing to configure.
    var usesHTTPEndpoint: Bool { self != .codex }

    /// Whether the provider can produce embeddings. The Codex app-server has
    /// no embedding endpoint, so semantic embeddings stay on a local provider
    /// even while generation runs on Codex.
    var supportsEmbeddings: Bool { self != .codex }

    /// Whether generation stays on-device. Cloud providers get an explicit
    /// consent caption in Settings and are excluded from the dictation-polish
    /// hot path, which cannot afford a network round-trip.
    var isLocal: Bool { self != .codex }
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

    /// Streaming variant of `chat`. `onDelta` receives the accumulated
    /// response text so far (not the increment) each time more arrives, so a
    /// consumer can replace its display content wholesale; the complete reply
    /// is still returned at the end exactly like `chat`.
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
    ) async throws -> String
}

extension LocalLLMServing {
    /// Providers without token streaming fall back to the blocking call;
    /// `onDelta` is never invoked and the caller renders the returned reply.
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

/// Shared client instances. `LMStudioClient` caches its model list and
/// `CodexClient` shares one app-server process, so reuse matters; all are
/// actors and safe to share.
enum LocalLLM {
    static let ollamaClient = OllamaClient()
    static let lmStudioClient = LMStudioClient()
    static let codexClient = CodexClient()

    static func client(for kind: LocalLLMProviderKind) -> any LocalLLMServing {
        switch kind {
        case .ollama: return ollamaClient
        case .lmStudio: return lmStudioClient
        case .codex: return codexClient
        }
    }
}
