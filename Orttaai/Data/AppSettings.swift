// AppSettings.swift
// Orttaai

import CoreAudio
import SwiftUI
import Combine

enum TranscriptionModelSelectionPolicy {
    static let multilingualSmallModelID = "openai_whisper-small"
    static let englishSmallModelID = "openai_whisper-small.en"

    static func resolvedModelID(
        selectedModelID: String,
        dictationLanguage: String
    ) -> String {
        let selected = selectedModelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard selected == multilingualSmallModelID else { return selected }

        let language = dictationLanguage
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard language == "en" || language.hasPrefix("en-") else { return selected }
        return englishSmallModelID
    }
}

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
        // Remove retired insertion/rewrite state. Version this reliability
        // recovery so users can deliberately re-enable optional polish later
        // without every launch overriding their choice.
        defaults.removeObject(forKey: "polishModeEnabled")
        let recoveryVersionKey = "dictationReliabilityRecoveryVersion"
        if defaults.integer(forKey: recoveryVersionKey) < 1 {
            defaults.set(false, forKey: "localLLMPolishEnabled")
            defaults.removeObject(forKey: "inFieldStreamingEnabled")
            defaults.removeObject(forKey: "KeyboardShortcuts_pasteLastTranscript")
            defaults.set(1, forKey: recoveryVersionKey)
        }
    }

    @AppStorage("selectedModelId") var selectedModelId: String = "openai_whisper-small"
    @AppStorage("activeModelId") var activeModelId: String = ""
    /// Dictate with Express (Fluid Speech Mini) instead of the selected
    /// Whisper model, which stays selected as the fallback. Per Mac: the
    /// model package is downloaded on each Mac separately.
    @AppStorage("expressEngineEnabled") var expressEngineEnabled: Bool = false
    /// Express checks Personal Memory dictionary words against the audio.
    @AppStorage("expressWordBoostEnabled") var expressWordBoostEnabled: Bool = true
    /// Express decodes each stretch of speech at the speaker's pauses while
    /// recording, leaving only the last stretch for after the key is released.
    @AppStorage("expressLiveSegmentsEnabled") var expressLiveSegmentsEnabled: Bool = false
    @AppStorage("selectedAudioDeviceID") var selectedAudioDeviceID: String = ""
    /// Persistent UID of the chosen microphone; see `AudioInputSelection`.
    /// Empty for System Default and for choices made before it was kept.
    @AppStorage("selectedAudioDeviceUID") var selectedAudioDeviceUID: String = ""
    @AppStorage("launchAtLogin") var launchAtLogin: Bool = false
    @AppStorage("hasCompletedSetup") var hasCompletedSetup: Bool = false
    @AppStorage("showProcessingEstimate") var showProcessingEstimate: Bool = true
    /// Corner toast and in-window celebration when a badge is earned.
    @AppStorage("celebrateMilestones") var celebrateMilestones: Bool = true
    @AppStorage("homeWorkspaceAutoOpenEnabled") var homeWorkspaceAutoOpenEnabled: Bool = true
    @AppStorage("lowLatencyModeEnabled") var lowLatencyModeEnabled: Bool = false
    @AppStorage("spokenFormattingEnabled") var spokenFormattingEnabled: Bool = true
    /// Breaks a long dictation that came out as one block into paragraphs.
    @AppStorage("autoParagraphsEnabled") var autoParagraphsEnabled: Bool = true
    @AppStorage("dictionaryEnabled") var dictionaryEnabled: Bool = true
    /// Corrects recognizer near-misses of dictionary targets (Tematope ->
    /// Temitope) after the literal source rows have run.
    @AppStorage("fuzzyDictionaryEnabled") var fuzzyDictionaryEnabled: Bool = true
    /// Removes fillers and stutters and capitalizes a lowercase "i" in the
    /// recognizer's output.
    @AppStorage("disfluencyCleanupEnabled") var disfluencyCleanupEnabled: Bool = true
    @AppStorage("snippetsEnabled") var snippetsEnabled: Bool = true
    /// Feeds active dictionary targets and snippet triggers to short,
    /// whole-utterance recognizer decodes. Live clip bias is disabled because
    /// the ASR corpus measured worse WER, latency, and prompt hallucinations;
    /// post-hoc dictionary replacement still applies to every path.
    @AppStorage("vocabularyBiasEnabled") var vocabularyBiasEnabled: Bool = true
    @AppStorage("aiSuggestionsEnabled") var aiSuggestionsEnabled: Bool = false
    /// Suggests dictionary words from fixes the user makes right after a
    /// dictation is inserted (`EditLearningWatcher`).
    @AppStorage("learnFromEditsEnabled") var learnFromEditsEnabled: Bool = true
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
    @AppStorage("handsFreeSilenceStopSeconds") var handsFreeSilenceStopSeconds: Double = 4.0
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
    @AppStorage("decodingPreset") var decodingPresetRaw: String = DecodingPreset.balanced.rawValue
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
    /// Optional rewriting is off by default so the recognizer's final result
    /// remains authoritative. Users can opt in from Model settings.
    @AppStorage("localLLMPolishEnabled") var localLLMPolishEnabled: Bool = false
    @AppStorage("appleIntelligencePolishEnabled") var appleIntelligencePolishEnabled: Bool = false
    @AppStorage("localLLMEndpoint") var localLLMEndpoint: String = "http://127.0.0.1:11434"
    @AppStorage("localLLMPolishModel") var localLLMPolishModel: String = "gemma4:e2b"
    /// Which model Text Polish uses: "s1Mini" (S1-mini by Superwhisper,
    /// built in) or "localLLM" (the local LLM server's model below).
    @AppStorage("polishEngine") var polishEngine: String = "s1Mini"
    @AppStorage("localLLMPolishTimeoutMs") var localLLMPolishTimeoutMs: Int = 3_000
    @AppStorage("localLLMPolishMaxChars") var localLLMPolishMaxChars: Int = 400
    @AppStorage("localLLMInsightsEnabled") var localLLMInsightsEnabled: Bool = false
    @AppStorage("localLLMInsightsModel") var localLLMInsightsModel: String = "gemma4:e2b"
    @AppStorage("localLLMInsightsContextTokens") var localLLMInsightsContextTokens: Int = 16_384
    @AppStorage("localLLMInsightsThinkingEnabled") var localLLMInsightsThinkingEnabled: Bool = false
    @AppStorage("semanticMemoryEnabled") var semanticMemoryEnabled: Bool = true
    @AppStorage("semanticMemoryAutoIndexEnabled") var semanticMemoryAutoIndexEnabled: Bool = true
    @AppStorage("semanticEmbeddingFallbackEnabled") var semanticEmbeddingFallbackEnabled: Bool = true
    @AppStorage("semanticEmbeddingModel") var semanticEmbeddingModel: String = "all-minilm"
    @AppStorage("semanticActiveIndexModelID") var semanticActiveIndexModelID: String = ""
    @AppStorage("semanticInsightSummaryEnabled") var semanticInsightSummaryEnabled: Bool = true
    @AppStorage("semanticInsightSummaryModel") var semanticInsightSummaryModel: String = "gemma4:e2b"

    /// Set once LocalAIMigration has moved this install off the removed
    /// cloud providers; see `LocalAIMigration.currentVersion`.
    @AppStorage("aiProviderMigrationVersion") var aiProviderMigrationVersion: Int = 0
    /// Shown once in Model settings after the migration switched provider.
    @AppStorage("aiProviderMigrationNotice") var aiProviderMigrationNotice: String = ""

    var selectedAudioDevice: String? {
        selectedAudioDeviceID.isEmpty ? nil : selectedAudioDeviceID
    }

    /// The device to record from for the chosen mic, nil for System Default
    /// (including when the chosen mic is not connected).
    var selectedInputDeviceID: AudioDeviceID? {
        AudioInputSelection.deviceID(
            selectedUID: selectedAudioDeviceUID,
            legacyID: selectedAudioDevice,
            devices: AudioDeviceManager.currentInputDevices
        )
    }

    var decodingPreset: DecodingPreset {
        DecodingPreset(rawValue: decodingPresetRaw) ?? .balanced
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
    /// the supported 1–10s range.
    var effectiveHandsFreeSilenceStopSeconds: TimeInterval? {
        guard handsFreeSilenceStopEnabled else { return nil }
        return max(1.0, min(10.0, handsFreeSilenceStopSeconds))
    }

    /// Supported recording caps (seconds); the Settings sliders use the same
    /// ranges. The stored values arrive from cloud sync and from test runs
    /// that share this defaults domain, so they are never trusted raw.
    static let pushToTalkMaxRecordingDurationRange: ClosedRange<Int> = 10...300
    static let handsFreeMaxRecordingDurationRange: ClosedRange<Int> = 120...1800

    /// Push-to-talk recording cap, clamped to the supported range.
    var effectiveMaxRecordingDuration: TimeInterval {
        let range = Self.pushToTalkMaxRecordingDurationRange
        return TimeInterval(max(range.lowerBound, min(range.upperBound, maxRecordingDuration)))
    }

    /// Hands-free recording cap, clamped to the supported range so a stray
    /// tiny value can never cut a recording off after a few seconds.
    var effectiveHandsFreeMaxRecordingDuration: TimeInterval {
        let range = Self.handsFreeMaxRecordingDurationRange
        return TimeInterval(max(range.lowerBound, min(range.upperBound, handsFreeMaxRecordingDuration)))
    }

    var effectiveDictationLanguage: String {
        (lowLatencyModeEnabled && dictationLanguage == "auto")
            ? "en"
            : dictationLanguage
    }

    var effectiveSelectedModelId: String {
        TranscriptionModelSelectionPolicy.resolvedModelID(
            selectedModelID: selectedModelId,
            dictationLanguage: dictationLanguage
        )
    }

    /// Keeps an explicit English Small selection on Whisper's English-only
    /// checkpoint. The multilingual checkpoint remains authoritative for
    /// Auto Detect and every non-English language.
    @discardableResult
    func applyLanguageOptimizedSmallModelSelection() -> String {
        let resolved = effectiveSelectedModelId
        if resolved != selectedModelId {
            selectedModelId = resolved
            activeModelId = ""
        }
        return resolved
    }

    /// Express runs only when it is on, this Mac supports it, and dictation is
    /// in English; anything else dictates with the selected Whisper model.
    var isExpressEngineActive: Bool {
        expressEngineEnabled
            && ExpressEngine.isSupported
            && ExpressEngine.supportsLanguage(effectiveDictationLanguage)
    }

    /// The model dictation runs on, for the dashboards: Express when it is
    /// active (it is never stored as `activeModelId`), otherwise the loaded
    /// Whisper model; nil before any model has loaded.
    var dictationModelIDForDisplay: String? {
        if isExpressEngineActive { return ExpressEngine.modelID }
        let active = activeModelId.trimmingCharacters(in: .whitespacesAndNewlines)
        return active.isEmpty ? nil : active
    }

    /// The model dictation should load: Express when it is active, otherwise
    /// the Whisper selection (with its English Small adjustment applied).
    @discardableResult
    func dictationModelID() -> String {
        let whisperModelID = applyLanguageOptimizedSmallModelSelection()
        return isExpressEngineActive ? ExpressEngine.modelID : whisperModelID
    }

    /// Records the model that just transcribed. `activeModelId` names the
    /// Whisper model, so an Express load never overwrites it.
    func recordLoadedModel(_ modelID: String) {
        guard modelID != ExpressEngine.modelID else { return }
        activeModelId = modelID
    }

    var normalizedLocalLLMEndpoint: String {
        let trimmed = localLLMEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "http://127.0.0.1:11434" : trimmed
    }

    /// The local model server in use. A stored value from a removed cloud
    /// provider reads as Ollama until LocalAIMigration rewrites it.
    var localLLMProvider: LocalLLMProviderKind {
        get { LocalLLMProviderKind(rawValue: localLLMProviderRaw) ?? .ollama }
        set { localLLMProviderRaw = newValue.rawValue }
    }

    var normalizedLMStudioEndpoint: String {
        let trimmed = lmStudioEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? LocalLLMProviderKind.lmStudio.defaultEndpoint : trimmed
    }

    func endpoint(for kind: LocalLLMProviderKind) -> String {
        switch kind {
        case .ollama: return normalizedLocalLLMEndpoint
        case .lmStudio: return normalizedLMStudioEndpoint
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

    /// Embeddings and dictation polish run on the same local provider as
    /// everything else; these names remain for their call sites.
    var embeddingLLMClient: any LocalLLMServing { activeLocalLLMClient }
    var embeddingLLMEndpoint: String { activeLocalLLMEndpoint }
    var polishLLMProvider: LocalLLMProviderKind { localLLMProvider }
    var polishLLMClient: any LocalLLMServing { activeLocalLLMClient }
    var polishLLMEndpoint: String { activeLocalLLMEndpoint }

    var normalizedLocalLLMPolishModel: String {
        sanitizeLocalLLMModel(localLLMPolishModel, fallback: "gemma4:e2b")
    }

    var normalizedLocalLLMInsightsModel: String {
        sanitizeLocalLLMModel(localLLMInsightsModel, fallback: "gemma4:e2b")
    }

    var normalizedSemanticEmbeddingModel: String {
        sanitizeSemanticEmbeddingModel(semanticEmbeddingModel, fallback: "all-minilm")
    }

    var normalizedSemanticInsightSummaryModel: String {
        sanitizeLocalLLMModel(semanticInsightSummaryModel, fallback: "gemma4:e2b")
    }

    var localLLMInsightCandidateModels: [String] {
        var candidates: [String] = []
        if localLLMInsightsEnabled {
            candidates.append(normalizedLocalLLMInsightsModel)
        }
        // The polish model doubles as an insights fallback.
        if localLLMPolishEnabled {
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

    /// Text Polish runs S1-mini in-process rather than the local LLM server.
    var usesS1MiniPolish: Bool {
        polishEngine != "localLLM"
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
        await transcriptionService.setExpressLiveSegments(expressLiveSegmentsEnabled)
    }
}
