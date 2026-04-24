import XCTest
@testable import Orttaai

final class AppSettingsTests: XCTestCase {
    private let resetKeys = [
        "dictationLanguage",
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
    ]

    override func setUp() {
        super.setUp()
        resetDefaults()
    }

    override func tearDown() {
        resetDefaults()
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
    func transcribe(audioSamples: [Float]) async throws -> String { "" }
    func beginLiveTranscriptionSession() {}
    func processLiveAudioSnapshot(_ audioSamples: [Float]) {}
    func finalizeLiveTranscription(audioSamples: [Float]) async throws -> String { "" }
    func cancelLiveTranscriptionSession() {}

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
