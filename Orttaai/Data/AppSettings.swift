// AppSettings.swift
// Orttaai

import SwiftUI
import Combine

enum DecodingPreset: String, CaseIterable, Sendable {
    case fast
    case balanced
    case accuracy

    var title: String {
        switch self {
        case .fast:
            return "Fast"
        case .balanced:
            return "Balanced"
        case .accuracy:
            return "Accuracy"
        }
    }

    var summary: String {
        switch self {
        case .fast:
            return "Fastest response for quick dictation."
        case .balanced:
            return "Balanced speed and reliable accuracy."
        case .accuracy:
            return "Higher resilience for difficult audio."
        }
    }
}

struct DecodingPreferences: Sendable, Equatable {
    let preset: DecodingPreset
    let expertOverridesEnabled: Bool
    let temperature: Double
    let topK: Int
    let fallbackCount: Int
    let compressionRatioThreshold: Double
    let logProbThreshold: Double
    let noSpeechThreshold: Double
    let workerCount: Int

    nonisolated static let defaultTemperature = 0.0
    nonisolated static let defaultTopK = 5
    nonisolated static let defaultFallbackCount = 3
    nonisolated static let defaultCompressionRatioThreshold = 2.4
    nonisolated static let defaultLogProbThreshold = -1.0
    nonisolated static let defaultNoSpeechThreshold = 0.6
    nonisolated static let defaultWorkerCount = 0 // 0 means auto

    nonisolated static let `default` = DecodingPreferences(
        preset: .fast,
        expertOverridesEnabled: false,
        temperature: defaultTemperature,
        topK: defaultTopK,
        fallbackCount: defaultFallbackCount,
        compressionRatioThreshold: defaultCompressionRatioThreshold,
        logProbThreshold: defaultLogProbThreshold,
        noSpeechThreshold: defaultNoSpeechThreshold,
        workerCount: defaultWorkerCount
    )

    nonisolated func clamped() -> DecodingPreferences {
        DecodingPreferences(
            preset: preset,
            expertOverridesEnabled: expertOverridesEnabled,
            temperature: max(0.0, min(1.0, temperature)),
            topK: max(1, min(20, topK)),
            fallbackCount: max(0, min(10, fallbackCount)),
            compressionRatioThreshold: max(1.5, min(4.0, compressionRatioThreshold)),
            logProbThreshold: max(-3.0, min(0.0, logProbThreshold)),
            noSpeechThreshold: max(0.0, min(1.0, noSpeechThreshold)),
            workerCount: max(0, min(8, workerCount))
        )
    }
}

final class AppSettings: ObservableObject {
    let objectWillChange = ObservableObjectPublisher()

    @AppStorage("selectedModelId") var selectedModelId: String = "openai_whisper-small"
    @AppStorage("activeModelId") var activeModelId: String = ""
    @AppStorage("selectedAudioDeviceID") var selectedAudioDeviceID: String = ""
    @AppStorage("polishModeEnabled") var polishModeEnabled: Bool = false
    @AppStorage("launchAtLogin") var launchAtLogin: Bool = false
    @AppStorage("hasCompletedSetup") var hasCompletedSetup: Bool = false
    @AppStorage("showProcessingEstimate") var showProcessingEstimate: Bool = true
    @AppStorage("homeWorkspaceAutoOpenEnabled") var homeWorkspaceAutoOpenEnabled: Bool = true
    @AppStorage("lowLatencyModeEnabled") var lowLatencyModeEnabled: Bool = false
    @AppStorage("spokenFormattingEnabled") var spokenFormattingEnabled: Bool = true
    @AppStorage("dictionaryEnabled") var dictionaryEnabled: Bool = true
    @AppStorage("snippetsEnabled") var snippetsEnabled: Bool = true
    @AppStorage("aiSuggestionsEnabled") var aiSuggestionsEnabled: Bool = false
    @AppStorage("fastFirstOnboardingEnabled") var fastFirstOnboardingEnabled: Bool = false
    @AppStorage("fastFirstRecommendedModelId") var fastFirstRecommendedModelId: String = ""
    @AppStorage("fastFirstPrefetchStarted") var fastFirstPrefetchStarted: Bool = false
    @AppStorage("fastFirstPrefetchReady") var fastFirstPrefetchReady: Bool = false
    @AppStorage("fastFirstUpgradeDismissed") var fastFirstUpgradeDismissed: Bool = false
    @AppStorage("fastFirstPrefetchErrorMessage") var fastFirstPrefetchErrorMessage: String = ""
    @AppStorage("githubStarPromptCompleted") var githubStarPromptCompleted: Bool = false
    @AppStorage("githubStarPromptShownCount") var githubStarPromptShownCount: Int = 0
    @AppStorage("githubStarPromptLastShownAtEpoch") var githubStarPromptLastShownAtEpoch: Double = 0

    // Transcription
    @AppStorage("dictationLanguage") var dictationLanguage: String = "en"
    @AppStorage("maxRecordingDuration") var maxRecordingDuration: Int = 90

    // Advanced / Compute
    @AppStorage("computeMode") var computeMode: String = "cpuAndNeuralEngine"
    @AppStorage("decodingPreset") var decodingPresetRaw: String = DecodingPreset.fast.rawValue
    @AppStorage("advancedDecodingEnabled") var advancedDecodingEnabled: Bool = false
    @AppStorage("decodingTemperature") var decodingTemperature: Double = DecodingPreferences.defaultTemperature
    @AppStorage("decodingTopK") var decodingTopK: Int = DecodingPreferences.defaultTopK
    @AppStorage("decodingFallbackCount") var decodingFallbackCount: Int = DecodingPreferences.defaultFallbackCount
    @AppStorage("decodingCompressionRatioThreshold") var decodingCompressionRatioThreshold: Double = DecodingPreferences.defaultCompressionRatioThreshold
    @AppStorage("decodingLogProbThreshold") var decodingLogProbThreshold: Double = DecodingPreferences.defaultLogProbThreshold
    @AppStorage("decodingNoSpeechThreshold") var decodingNoSpeechThreshold: Double = DecodingPreferences.defaultNoSpeechThreshold
    @AppStorage("decodingWorkerCount") var decodingWorkerCount: Int = DecodingPreferences.defaultWorkerCount

    // Local LLM (Ollama or LM Studio)
    // Provider choice and endpoints are device-specific and intentionally not
    // synced across Macs.
    @AppStorage("localLLMProvider") var localLLMProviderRaw: String = LocalLLMProviderKind.ollama.rawValue
    @AppStorage("lmStudioEndpoint") var lmStudioEndpoint: String = "http://127.0.0.1:1234"
    @AppStorage("localLLMPolishEnabled") var localLLMPolishEnabled: Bool = false
    @AppStorage("localLLMEndpoint") var localLLMEndpoint: String = "http://127.0.0.1:11434"
    @AppStorage("localLLMPolishModel") var localLLMPolishModel: String = "gemma3:1b"
    @AppStorage("localLLMPolishTimeoutMs") var localLLMPolishTimeoutMs: Int = 650
    @AppStorage("localLLMPolishMaxChars") var localLLMPolishMaxChars: Int = 280
    @AppStorage("localLLMInsightsEnabled") var localLLMInsightsEnabled: Bool = false
    @AppStorage("localLLMInsightsModel") var localLLMInsightsModel: String = "qwen3.5:0.8b"
    @AppStorage("localLLMInsightsContextTokens") var localLLMInsightsContextTokens: Int = 16_384
    @AppStorage("localLLMInsightsThinkingEnabled") var localLLMInsightsThinkingEnabled: Bool = false
    @AppStorage("semanticMemoryEnabled") var semanticMemoryEnabled: Bool = true
    @AppStorage("semanticMemoryAutoIndexEnabled") var semanticMemoryAutoIndexEnabled: Bool = true
    @AppStorage("semanticEmbeddingFallbackEnabled") var semanticEmbeddingFallbackEnabled: Bool = true
    @AppStorage("semanticEmbeddingModel") var semanticEmbeddingModel: String = "all-minilm"
    @AppStorage("semanticActiveIndexModelID") var semanticActiveIndexModelID: String = ""
    @AppStorage("semanticInsightSummaryEnabled") var semanticInsightSummaryEnabled: Bool = true
    @AppStorage("semanticInsightSummaryModel") var semanticInsightSummaryModel: String = "qwen3.5:0.8b"

    // ChatGPT (Codex) cloud provider. Auth lives in ~/.codex (owned by the
    // Codex CLI); these are only model choice and routing preferences.
    @AppStorage("codexModel") var codexModel: String = "gpt-5.4-mini"
    @AppStorage(CodexClient.reasoningEffortKey) var codexReasoningEffort: String = "medium"
    @AppStorage("codexConsentAcknowledged") var codexConsentAcknowledged: Bool = false
    /// Last local provider the user had selected; features that must stay
    /// on-device (embeddings, dictation polish) fall back to it while the
    /// active provider is cloud-based.
    @AppStorage("lastLocalLLMProvider") var lastLocalLLMProviderRaw: String = LocalLLMProviderKind.ollama.rawValue

    var selectedAudioDevice: String? {
        selectedAudioDeviceID.isEmpty ? nil : selectedAudioDeviceID
    }

    var decodingPreset: DecodingPreset {
        DecodingPreset(rawValue: decodingPresetRaw) ?? .fast
    }

    var decodingPreferences: DecodingPreferences {
        DecodingPreferences(
            preset: decodingPreset,
            expertOverridesEnabled: advancedDecodingEnabled,
            temperature: decodingTemperature,
            topK: decodingTopK,
            fallbackCount: decodingFallbackCount,
            compressionRatioThreshold: decodingCompressionRatioThreshold,
            logProbThreshold: decodingLogProbThreshold,
            noSpeechThreshold: decodingNoSpeechThreshold,
            workerCount: decodingWorkerCount
        ).clamped()
    }

    var effectiveDictationLanguage: String {
        (lowLatencyModeEnabled && dictationLanguage == "auto")
            ? "en"
            : dictationLanguage
    }

    var normalizedLocalLLMEndpoint: String {
        let trimmed = localLLMEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "http://127.0.0.1:11434" : trimmed
    }

    var localLLMProvider: LocalLLMProviderKind {
        get { LocalLLMProviderKind(rawValue: localLLMProviderRaw) ?? .ollama }
        set {
            localLLMProviderRaw = newValue.rawValue
            if newValue.isLocal {
                lastLocalLLMProviderRaw = newValue.rawValue
            }
        }
    }

    /// The local provider used for features that must stay on-device while a
    /// cloud provider is active.
    var localFallbackLLMProvider: LocalLLMProviderKind {
        if localLLMProvider.isLocal { return localLLMProvider }
        let stored = LocalLLMProviderKind(rawValue: lastLocalLLMProviderRaw) ?? .ollama
        return stored.isLocal ? stored : .ollama
    }

    var normalizedLMStudioEndpoint: String {
        let trimmed = lmStudioEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? LocalLLMProviderKind.lmStudio.defaultEndpoint : trimmed
    }

    func endpoint(for kind: LocalLLMProviderKind) -> String {
        switch kind {
        case .ollama: return normalizedLocalLLMEndpoint
        case .lmStudio: return normalizedLMStudioEndpoint
        case .codex: return "" // Spawned subprocess; no HTTP endpoint.
        }
    }

    /// Endpoint for the currently selected LLM provider. Every feature
    /// (polish, insights, chat, tone, semantic memory) resolves through this.
    var activeLocalLLMEndpoint: String {
        endpoint(for: localLLMProvider)
    }

    /// Client for the currently selected LLM provider.
    var activeLocalLLMClient: any LocalLLMServing {
        LocalLLM.client(for: localLLMProvider)
    }

    /// Provider/client/endpoint for semantic embeddings. The Codex app-server
    /// has no embedding endpoint, so embeddings stay on the local fallback
    /// provider while generation runs in the cloud.
    var embeddingLLMProvider: LocalLLMProviderKind {
        localLLMProvider.supportsEmbeddings ? localLLMProvider : localFallbackLLMProvider
    }

    var embeddingLLMClient: any LocalLLMServing {
        LocalLLM.client(for: embeddingLLMProvider)
    }

    var embeddingLLMEndpoint: String {
        endpoint(for: embeddingLLMProvider)
    }

    /// Provider/client/endpoint for dictation polish, which cannot afford a
    /// cloud round-trip on the dictation hot path and therefore always runs
    /// on the local fallback provider.
    var polishLLMProvider: LocalLLMProviderKind {
        localLLMProvider.isLocal ? localLLMProvider : localFallbackLLMProvider
    }

    var polishLLMClient: any LocalLLMServing {
        LocalLLM.client(for: polishLLMProvider)
    }

    var polishLLMEndpoint: String {
        endpoint(for: polishLLMProvider)
    }

    var normalizedLocalLLMPolishModel: String {
        sanitizeLocalLLMModel(localLLMPolishModel, fallback: "gemma3:1b")
    }

    var normalizedCodexModel: String {
        let trimmed = codexModel.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "gpt-5.4-mini" : trimmed
    }

    /// Insights model for the active provider: the Codex cloud model when the
    /// cloud provider is selected, otherwise the configured local model (the
    /// local sanitizer's "llama" filter must not touch cloud model ids).
    var normalizedLocalLLMInsightsModel: String {
        localLLMProvider == .codex
            ? normalizedCodexModel
            : sanitizeLocalLLMModel(localLLMInsightsModel, fallback: "qwen3.5:0.8b")
    }

    var normalizedSemanticEmbeddingModel: String {
        sanitizeSemanticEmbeddingModel(semanticEmbeddingModel, fallback: "all-minilm")
    }

    var normalizedSemanticInsightSummaryModel: String {
        localLLMProvider == .codex
            ? normalizedCodexModel
            : sanitizeLocalLLMModel(semanticInsightSummaryModel, fallback: "qwen3.5:0.8b")
    }

    var localLLMInsightCandidateModels: [String] {
        var candidates: [String] = []
        if localLLMInsightsEnabled {
            candidates.append(normalizedLocalLLMInsightsModel)
        }
        // The polish model is only a sensible insights fallback when the
        // active provider is local — it doesn't exist on a cloud provider.
        if localLLMPolishEnabled, localLLMProvider.isLocal {
            candidates.append(normalizedLocalLLMPolishModel)
        }
        var seen = Set<String>()
        return candidates.filter { model in
            let key = model.lowercased()
            guard !key.isEmpty, !seen.contains(key) else { return false }
            seen.insert(key)
            return true
        }
    }

    var clampedLocalLLMPolishTimeoutMs: Int {
        let clamped = max(80, min(1_500, localLLMPolishTimeoutMs))
        // Migrate from old default that is too low for real local generation latency.
        if clamped == 220 {
            return 650
        }
        return clamped
    }

    var clampedLocalLLMPolishMaxChars: Int {
        max(80, min(2_000, localLLMPolishMaxChars))
    }

    var clampedLocalLLMInsightsContextTokens: Int {
        if localLLMInsightsContextTokens == 65_536 {
            return 16_384
        }
        return max(8_192, min(262_144, localLLMInsightsContextTokens))
    }

    private func sanitizeLocalLLMModel(_ value: String, fallback: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return fallback
        }
        if trimmed.lowercased().contains("llama") {
            return fallback
        }
        return trimmed
    }

    private func sanitizeSemanticEmbeddingModel(_ value: String, fallback: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : trimmed
    }

    func syncTranscriptionSettings(to transcriptionService: any Transcribing) async {
        await transcriptionService.updateSettings(
            language: effectiveDictationLanguage,
            computeMode: computeMode,
            lowLatencyMode: lowLatencyModeEnabled,
            decodingPreferences: decodingPreferences
        )
    }
}
