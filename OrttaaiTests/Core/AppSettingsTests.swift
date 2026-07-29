import XCTest
@testable import Orttaai

final class AppSettingsTests: XCTestCase {
    private var savedDefaults: [String: Any] = [:]
    private let resetKeys = [
        "dictationLanguage",
        "selectedModelId",
        "activeModelId",
        "lowLatencyModeEnabled",
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

    func testEffectiveDictationLanguageForcesEnglishWhenLowLatencyUsesAutoDetect() {
        let settings = AppSettings()
        settings.lowLatencyModeEnabled = true
        settings.dictationLanguage = "auto"

        XCTAssertEqual(settings.effectiveDictationLanguage, "en")
    }

    func testEffectiveDictationLanguagePreservesExplicitLanguage() {
        let settings = AppSettings()
        settings.lowLatencyModeEnabled = true
        settings.dictationLanguage = "es"

        XCTAssertEqual(settings.effectiveDictationLanguage, "es")
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
        settings.lowLatencyModeEnabled = true
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
        XCTAssertEqual(snapshot?.language, "en")
        XCTAssertEqual(snapshot?.computeMode, "cpuOnly")
        XCTAssertEqual(snapshot?.lowLatencyMode, true)
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
        let lowLatencyMode: Bool
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
        lowLatencyMode: Bool,
        decodingPreferences: DecodingPreferences
    ) {
        lastSettings = SettingsSnapshot(
            language: language,
            computeMode: computeMode,
            lowLatencyMode: lowLatencyMode,
            decodingPreferences: decodingPreferences
        )
    }
}
