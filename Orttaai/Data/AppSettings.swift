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

    init(defaults: UserDefaults = .standard) {
        // "polishModeEnabled" (pre-1.7) was written and iCloud-synced but read
        // nowhere; "localLLMPolishEnabled" is the single source of truth for
        // polish. Delete the stale key so it stops shadowing the real one.
        defaults.removeObject(forKey: "polishModeEnabled")

        // The pre-default-on Model settings screen unconditionally persisted
        // localLLMPolishModel="gemma3:1b" for anyone who ever opened it, but
        // that model scores far below the shipped default on the golden eval
        // set (see gauntlet/eval_results.json). Users who never explicitly
        // chose polish (no stored localLLMPolishEnabled) are flipped ON by the
        // new default, so migrate them to the eval-proven model. An explicit
        // enabled/disabled choice means the user may also have chosen the
        // model deliberately; leave those untouched.
        if defaults.object(forKey: "localLLMPolishEnabled") == nil,
           defaults.string(forKey: "localLLMPolishModel") == "gemma3:1b" {
            defaults.set("gemma4:e2b", forKey: "localLLMPolishModel")
        }
    }

    @AppStorage("selectedModelId") var selectedModelId: String = "openai_whisper-small"
    @AppStorage("activeModelId") var activeModelId: String = ""
    @AppStorage("selectedAudioDeviceID") var selectedAudioDeviceID: String = ""
    @AppStorage("launchAtLogin") var launchAtLogin: Bool = false
    @AppStorage("hasCompletedSetup") var hasCompletedSetup: Bool = false
    @AppStorage("showProcessingEstimate") var showProcessingEstimate: Bool = true
    @AppStorage("homeWorkspaceAutoOpenEnabled") var homeWorkspaceAutoOpenEnabled: Bool = true
    @AppStorage("lowLatencyModeEnabled") var lowLatencyModeEnabled: Bool = false
    /// In-field streaming: committed words are typed at the caret while the
    /// user is still speaking, and the pill stays compact. Falls back to the
    /// pill transcript wherever streaming is unsafe (terminals, secure
    /// fields, unreadable elements, focus changes). Streamed sessions defer
    /// LLM polish so finished words are never rewritten in front of the user.
    @AppStorage("inFieldStreamingEnabled") var inFieldStreamingEnabled: Bool = true
    @AppStorage("spokenFormattingEnabled") var spokenFormattingEnabled: Bool = true
    @AppStorage("dictionaryEnabled") var dictionaryEnabled: Bool = true
    @AppStorage("snippetsEnabled") var snippetsEnabled: Bool = true
    /// Feeds active dictionary targets and snippet triggers to the recognizer
    /// as decoding bias context so hard vocabulary is transcribed correctly
    /// in the first place (post-hoc replacement still applies either way).
    @AppStorage("vocabularyBiasEnabled") var vocabularyBiasEnabled: Bool = true
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

    // Hands-free (tap-to-toggle) dictation
    @AppStorage("handsFreeModeEnabled") var handsFreeModeEnabled: Bool = true
    @AppStorage("handsFreeSilenceStopEnabled") var handsFreeSilenceStopEnabled: Bool = true
    @AppStorage("handsFreeSilenceStopSeconds") var handsFreeSilenceStopSeconds: Double = 2.0
    /// Hands-free recordings get their own generous cap (seconds), separate
    /// from the push-to-talk max duration.
    @AppStorage("handsFreeMaxRecordingDuration") var handsFreeMaxRecordingDuration: Int = 600

    // Voice edit commands (select text, speak an instruction, selection is
    // transformed in place). Rides the polish LLM provider/model; when no
    // local provider is reachable the edit fails honestly and the selection
    // stays untouched, so the default is safe.
    @AppStorage("editCommandsEnabled") var editCommandsEnabled: Bool = true
    @AppStorage("editCommandTimeoutMs") var editCommandTimeoutMs: Int = 6_000
    @AppStorage("editCommandMaxChars") var editCommandMaxChars: Int = 1_500

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
    /// Local LLM polish is ON by default (eval-proven on the golden set, see
    /// gauntlet/eval_results.json). Users who explicitly turned it off have a
    /// stored `false` that this default never overrides; when no local
    /// provider is reachable the processor falls back to rule-based output
    /// behind the circuit breaker, so the default is safe for users without
    /// Ollama.
    @AppStorage("localLLMPolishEnabled") var localLLMPolishEnabled: Bool = true
    @AppStorage("appleIntelligencePolishEnabled") var appleIntelligencePolishEnabled: Bool = false
    @AppStorage("localLLMEndpoint") var localLLMEndpoint: String = "http://127.0.0.1:11434"
    @AppStorage("localLLMPolishModel") var localLLMPolishModel: String = "gemma4:e2b"
    @AppStorage("localLLMPolishTimeoutMs") var localLLMPolishTimeoutMs: Int = 3_000
    @AppStorage("localLLMPolishMaxChars") var localLLMPolishMaxChars: Int = 400
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

    /// The silence window (seconds) after which a hands-free recording
    /// auto-stops, or nil when silence auto-stop is turned off. Clamped to
    /// the supported 1–5s range.
    var effectiveHandsFreeSilenceStopSeconds: TimeInterval? {
        guard handsFreeSilenceStopEnabled else { return nil }
        return max(1.0, min(5.0, handsFreeSilenceStopSeconds))
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
        sanitizeLocalLLMModel(localLLMPolishModel, fallback: "gemma4:e2b")
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
        let clamped = max(80, min(4_000, localLLMPolishTimeoutMs))
        // Migrate from old defaults that are too low for real local
        // generation latency (220 pre-1.5, 650 pre-polish-default-on).
        if clamped == 220 || clamped == 650 {
            return 3_000
        }
        return clamped
    }

    var clampedLocalLLMPolishMaxChars: Int {
        // Migrate the old 280-char default so polish covers longer dictation
        // (ModelSettingsView persists the same migration when settings open).
        if localLLMPolishMaxChars == 280 {
            return 400
        }
        return max(80, min(2_000, localLLMPolishMaxChars))
    }

    var clampedEditCommandTimeoutMs: Int {
        max(1_000, min(12_000, editCommandTimeoutMs))
    }

    var clampedEditCommandMaxChars: Int {
        max(200, min(6_000, editCommandMaxChars))
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
