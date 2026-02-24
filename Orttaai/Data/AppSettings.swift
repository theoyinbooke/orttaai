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
            return "Balanced speed and recognition stability."
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

    static let defaultTemperature = 0.0
    static let defaultTopK = 5
    static let defaultFallbackCount = 3
    static let defaultCompressionRatioThreshold = 2.4
    static let defaultLogProbThreshold = -1.0
    static let defaultNoSpeechThreshold = 0.6
    static let defaultWorkerCount = 0 // 0 means auto

    static let `default` = DecodingPreferences(
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

    func clamped() -> DecodingPreferences {
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

    @AppStorage("selectedModelId") var selectedModelId: String = "openai_whisper-large-v3_turbo"
    @AppStorage("activeModelId") var activeModelId: String = ""
    @AppStorage("selectedAudioDeviceID") var selectedAudioDeviceID: String = ""
    @AppStorage("polishModeEnabled") var polishModeEnabled: Bool = false
    @AppStorage("launchAtLogin") var launchAtLogin: Bool = false
    @AppStorage("hasCompletedSetup") var hasCompletedSetup: Bool = false
    @AppStorage("showProcessingEstimate") var showProcessingEstimate: Bool = true
    @AppStorage("homeWorkspaceAutoOpenEnabled") var homeWorkspaceAutoOpenEnabled: Bool = true
    @AppStorage("lowLatencyModeEnabled") var lowLatencyModeEnabled: Bool = false
    @AppStorage("fastFirstOnboardingEnabled") var fastFirstOnboardingEnabled: Bool = false
    @AppStorage("fastFirstRecommendedModelId") var fastFirstRecommendedModelId: String = ""
    @AppStorage("fastFirstPrefetchStarted") var fastFirstPrefetchStarted: Bool = false
    @AppStorage("fastFirstPrefetchReady") var fastFirstPrefetchReady: Bool = false
    @AppStorage("fastFirstUpgradeDismissed") var fastFirstUpgradeDismissed: Bool = false
    @AppStorage("fastFirstPrefetchErrorMessage") var fastFirstPrefetchErrorMessage: String = ""

    // Transcription
    @AppStorage("dictationLanguage") var dictationLanguage: String = "en"
    @AppStorage("maxRecordingDuration") var maxRecordingDuration: Int = 45

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
}
