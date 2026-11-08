import XCTest
@testable import Orttaai

final class AppSettingsTests: XCTestCase {
    private var savedDefaults: [String: Any] = [:]
    private let resetKeys = [
        "dictationLanguage",
        "selectedModelId",
        "activeModelId",
        "computeMode",
        "spokenFormattingEnabled",
        "decodingPreset",
        "advancedDecodingEnabled",
        "decodingTemperature",
        "decodingTopK",
        "decodingFallbackCount",
        "decodingCompressionRatioThreshold",
        "decodingLogProbThreshold",
        "decodingNoSpeechThreshold",
        "decodingWorkerCount",
        "dictationReliabilityRecoveryVersion",
        "localLLMPolishEnabled",
        "polishEngine",
        "appleIntelligencePolishEnabled",
        "localLLMPolishModel",
        "localLLMInsightsModel",
    ]

    override func setUp() {
        super.setUp()
        savedDefaults = resetKeys.reduce(into: [:]) { snapshot, key in
            if let value = UserDefaults.standard.object(forKey: key) {
                snapshot[key] = value
            }
        }
        resetDefaults()
    }

    override func tearDown() {
        let defaults = UserDefaults.standard
        for key in resetKeys {
            if let value = savedDefaults[key] {
                defaults.set(value, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }
        super.tearDown()
    }

    func testEffectiveDictationLanguageIsTheChosenLanguage() {
        let settings = AppSettings()
        settings.dictationLanguage = "auto"
        XCTAssertEqual(settings.effectiveDictationLanguage, "auto")
        settings.dictationLanguage = "es"
        XCTAssertEqual(settings.effectiveDictationLanguage, "es")
    }

    func testAppleIntelligencePolishOnItsOwnBecomesThePolishEngine() {
        let defaults = UserDefaults.standard
        defaults.set(1, forKey: "dictationReliabilityRecoveryVersion")
        defaults.set(true, forKey: "appleIntelligencePolishEnabled")
        defaults.set(false, forKey: "localLLMPolishEnabled")

        let settings = AppSettings(defaults: defaults)

        XCTAssertTrue(settings.localLLMPolishEnabled, "Polish stays on for someone who used Apple's")
        XCTAssertEqual(settings.polishEngine, PolishEngineChoice.appleIntelligence.rawValue)
        XCTAssertNil(defaults.object(forKey: "appleIntelligencePolishEnabled"))
    }

    func testAppleIntelligencePolishAlongsidePolishKeepsTheChosenEngine() {
        let defaults = UserDefaults.standard
        defaults.set(1, forKey: "dictationReliabilityRecoveryVersion")
        defaults.set(true, forKey: "appleIntelligencePolishEnabled")
        defaults.set(true, forKey: "localLLMPolishEnabled")
        defaults.set(PolishEngineChoice.localLLM.rawValue, forKey: "polishEngine")

        let settings = AppSettings(defaults: defaults)

        XCTAssertTrue(settings.localLLMPolishEnabled)
        XCTAssertEqual(settings.polishEngineChoice, .localLLM, "one engine, no second pass")
        XCTAssertNil(defaults.object(forKey: "appleIntelligencePolishEnabled"))
    }

    func testPolishEngineChoice() {
        let settings = AppSettings()
        settings.polishEngine = "localLLM"
        XCTAssertEqual(settings.polishEngineChoice, .localLLM)
        XCTAssertTrue(settings.usesLocalLLMPolish)
        settings.polishEngine = "something-old"
        XCTAssertEqual(settings.polishEngineChoice, .s1Mini, "unknown values use the built-in engine")
        settings.polishEngine = PolishEngineChoice.appleIntelligence.rawValue
        XCTAssertEqual(
            settings.polishEngineChoice,
            AppleIntelligencePolishProcessor.isModelAvailable ? .appleIntelligence : .s1Mini,
            "Apple Intelligence falls back to S1-mini where it can't run"
        )
    }

    func testTheChosenLocalModelIsTheOneThatRuns() {
        let settings = AppSettings()
        settings.localLLMPolishModel = "llama3.2:3b"
        settings.localLLMInsightsModel = "  llama3.1:8b  "
        XCTAssertEqual(settings.normalizedLocalLLMPolishModel, "llama3.2:3b")
        XCTAssertEqual(settings.normalizedLocalLLMInsightsModel, "llama3.1:8b")
        settings.localLLMPolishModel = "   "
        XCTAssertEqual(settings.normalizedLocalLLMPolishModel, "gemma4:e2b", "only an empty choice falls back")
    }

    func testAppleIntelligencePolishDoesNothingWhilePolishIsOff() async throws {
        let settings = AppSettings()
        settings.localLLMPolishEnabled = false
        settings.polishEngine = PolishEngineChoice.appleIntelligence.rawValue
        let processor = AppleIntelligencePolishProcessor(baseProcessor: PassThroughProcessor(), settings: settings)

        let output = try await processor.process(
            TextProcessorInput(rawTranscript: "so um this is the the text", targetApp: nil, mode: .clean)
        )

        XCTAssertEqual(output.text, "so um this is the the text")
        XCTAssertFalse(output.changes.contains("Apple Intelligence polish applied"))
    }

    func testRetiredLowLatencyPreferenceIsCleared() {
        let defaults = UserDefaults.standard
        defaults.set(true, forKey: "lowLatencyModeEnabled")
        _ = AppSettings(defaults: defaults)
        XCTAssertNil(defaults.object(forKey: "lowLatencyModeEnabled"))
    }

    func testQualityDefaultsUseBalancedDecodeAndNoLLMRewrite() {
        let settings = AppSettings()

        XCTAssertEqual(settings.decodingPreset, .balanced)
        XCTAssertFalse(settings.advancedDecodingEnabled)
        XCTAssertFalse(settings.localLLMPolishEnabled)
    }

    func testApplyingLanguageOptimizedSmallSelectionUpdatesPreferenceAndInvalidatesActiveModel() {
        let settings = AppSettings()
        settings.selectedModelId = "openai_whisper-small"
        settings.activeModelId = "openai_whisper-small"
        settings.dictationLanguage = "en"

        let resolvedModelID = settings.applyLanguageOptimizedSmallModelSelection()

        XCTAssertEqual(resolvedModelID, "openai_whisper-small.en")
        XCTAssertEqual(settings.selectedModelId, "openai_whisper-small.en")
        XCTAssertEqual(settings.activeModelId, "")
    }

    func testApplyingLanguageOptimizedSmallSelectionPreservesAutoDetectModel() {
        let settings = AppSettings()
        settings.selectedModelId = "openai_whisper-small"
        settings.activeModelId = "openai_whisper-small"
        settings.dictationLanguage = "auto"

        let resolvedModelID = settings.applyLanguageOptimizedSmallModelSelection()

        XCTAssertEqual(resolvedModelID, "openai_whisper-small")
        XCTAssertEqual(settings.selectedModelId, "openai_whisper-small")
        XCTAssertEqual(settings.activeModelId, "openai_whisper-small")
    }

    func testSyncTranscriptionSettingsPassesCurrentRuntimeValues() async {
        let settings = AppSettings()
        settings.dictationLanguage = "auto"
        settings.computeMode = "cpuOnly"
        settings.decodingPresetRaw = DecodingPreset.accuracy.rawValue
        settings.advancedDecodingEnabled = true
        settings.decodingTemperature = 0.4
        settings.decodingTopK = 9
        settings.decodingFallbackCount = 4
        settings.decodingCompressionRatioThreshold = 2.9
        settings.decodingLogProbThreshold = -1.4
        settings.decodingNoSpeechThreshold = 0.45
        settings.decodingWorkerCount = 6

        let transcriptionService = RecordingTranscriptionService()
        await settings.syncTranscriptionSettings(to: transcriptionService)

        let snapshot = await transcriptionService.lastSettings
        XCTAssertEqual(snapshot?.language, "auto")
        XCTAssertEqual(snapshot?.computeMode, "cpuOnly")
        XCTAssertEqual(snapshot?.decodingPreferences.preset, .accuracy)
        XCTAssertEqual(snapshot?.decodingPreferences.expertOverridesEnabled, true)
        XCTAssertEqual(snapshot?.decodingPreferences.temperature, 0.4)
        XCTAssertEqual(snapshot?.decodingPreferences.topK, 9)
        XCTAssertEqual(snapshot?.decodingPreferences.fallbackCount, 4)
        XCTAssertEqual(snapshot?.decodingPreferences.compressionRatioThreshold, 2.9)
        XCTAssertEqual(snapshot?.decodingPreferences.logProbThreshold, -1.4)
        XCTAssertEqual(snapshot?.decodingPreferences.noSpeechThreshold, 0.45)
        XCTAssertEqual(snapshot?.decodingPreferences.workerCount, 6)
    }

    private func resetDefaults() {
        let defaults = UserDefaults.standard
        for key in resetKeys {
            defaults.removeObject(forKey: key)
        }
    }
}

private actor RecordingTranscriptionService: Transcribing {
    struct SettingsSnapshot: Equatable {
        let language: String
        let computeMode: String
        let decodingPreferences: DecodingPreferences
    }

    private(set) var lastSettings: SettingsSnapshot?
    let isLoaded: Bool = false

    func loadedModelID() -> String? { nil }
    func loadModel(named modelName: String) async throws {}
    func transcribe(audioSamples: [Float]) async throws -> String { "" }
    func beginLiveTranscriptionSession() {}
    func processLiveAudioSnapshot(_ audioSamples: [Float]) {}
    func finalizeLiveTranscription(audioSamples: [Float]) async throws -> String { "" }
    func cancelLiveTranscriptionSession() {}
    func setLiveTranscriptEventHandler(_ handler: (@Sendable (LiveTranscriptEvent) -> Void)?) {}
    func setVocabularyBias(terms: [String]) {}

    func updateSettings(
        language: String,
        computeMode: String,
        decodingPreferences: DecodingPreferences
    ) {
        lastSettings = SettingsSnapshot(
            language: language,
            computeMode: computeMode,
            decodingPreferences: decodingPreferences
        )
    }
}

private struct PassThroughProcessor: TextProcessor {
    func process(_ input: TextProcessorInput) async throws -> TextProcessorOutput {
        TextProcessorOutput(text: input.rawTranscript, changes: [])
    }

    func isAvailable() -> Bool { true }
}
