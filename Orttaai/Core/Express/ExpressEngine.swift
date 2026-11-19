// ExpressEngine.swift
// Orttaai

import ExpressAudio
import Foundation

/// The speech model Express runs. Mini is the default; Pro is an optional,
/// larger download that is a little more accurate and also covers 24
/// European languages beyond English.
nonisolated enum ExpressModel: String, CaseIterable, Sendable {
    case mini
    case pro

    /// The id TranscriptionService loads this model under. It is never a
    /// WhisperKit variant, and never stored as `activeModelId` or
    /// `selectedModelId`: those keep naming the Whisper model Express falls
    /// back to.
    var modelID: String {
        switch self {
        case .mini: return "fluid-speech-mini"
        case .pro: return "fluid-speech-pro"
        }
    }

    var displayName: String {
        switch self {
        case .mini: return "Fluid Speech Mini"
        case .pro: return "Fluid Speech Pro"
        }
    }

    /// The name Settings shows: "Express" or "Express Pro".
    var productName: String {
        switch self {
        case .mini: return "Express"
        case .pro: return "Express Pro"
        }
    }

    /// The credit line CC BY 4.0 asks for.
    var attribution: String {
        "\(displayName) by FluidVoice"
    }

    /// Dictation languages this model was trained and measured on. Pro
    /// detects which of its languages is spoken on its own, but Express only
    /// runs when one is chosen: "auto" may mean a language it doesn't know.
    var languages: Set<String> {
        switch self {
        case .mini:
            return ["en"]
        case .pro:
            return [
                "en", "bg", "hr", "cs", "da", "nl", "et", "fi", "fr", "de", "el", "hu", "it",
                "lv", "lt", "mt", "pl", "pt", "ro", "sk", "sl", "es", "sv", "ru", "uk",
            ]
        }
    }

    func supportsLanguage(_ language: String) -> Bool {
        languages.contains(language)
    }

    init?(modelID: String) {
        guard let model = Self.allCases.first(where: { $0.modelID == modelID }) else { return nil }
        self = model
    }
}

/// Express: the opt-in Fluid Speech engine (Parakeet TDT on the Neural
/// Engine, through FluidAudio). FluidAudio itself supports macOS 14, but the
/// models' Core ML packages need macOS 15, so every Express code path sits
/// behind this gate and the app keeps running, with Express hidden, on 14.6.
nonisolated enum ExpressEngine {
    /// Mini's model id, the default Express model.
    static let modelID = ExpressModel.mini.modelID
    static let displayName = ExpressModel.mini.displayName
    static let attribution = ExpressModel.mini.attribution

    /// Whether `modelID` names an Express model, Mini or Pro.
    static func isModelID(_ modelID: String) -> Bool {
        ExpressModel(modelID: modelID) != nil
    }

    /// Word Boost's model and the number formatter are English, so they
    /// only run on English dictation.
    static func usesEnglishPostProcessing(language: String) -> Bool {
        language == "en"
    }

    static let minimumOSVersion = OperatingSystemVersion(majorVersion: 15, minorVersion: 0, patchVersion: 0)

    /// Whether this Mac can run Express. Settings hides Express when false.
    static var isSupported: Bool {
        isSupported(on: ProcessInfo.processInfo.operatingSystemVersion)
    }

    static func isSupported(on version: OperatingSystemVersion) -> Bool {
        (version.majorVersion, version.minorVersion, version.patchVersion)
            >= (minimumOSVersion.majorVersion, minimumOSVersion.minorVersion, minimumOSVersion.patchVersion)
    }

    /// Mini was trained and measured on English only.
    static func supportsLanguage(_ language: String) -> Bool {
        ExpressModel.mini.supportsLanguage(language)
    }

    /// Fluid Speech Mini and Pro load through FluidAudio as `.ultra`: the same
    /// encoder, decoder and joint contract, with the joint installed as
    /// JointDecisionv3.mlmodelc. Always load with `AsrModels.loadLocal`;
    /// `load(from:)` downloads the version's own repository beside the folder.
    @available(macOS 15, *)
    static let modelVersion: AsrModelVersion = .ultra
}

extension Notification.Name {
    /// Posted when a dictation could not load Express and used Whisper
    /// instead. The object is the load error's description.
    static let expressEngineDidFallBack = Notification.Name("Orttaai.expressEngineDidFallBack")
}
