// ExpressEngine.swift
// Orttaai

import ExpressAudio
import Foundation

/// Express: the opt-in Fluid Speech Mini engine (Parakeet TDT on the Neural
/// Engine, through FluidAudio). FluidAudio itself supports macOS 14, but the
/// Mini model's Core ML package needs macOS 15, so every Express code path sits
/// behind this gate and the app keeps running, with Express hidden, on 14.6.
nonisolated enum ExpressEngine {
    /// The model id TranscriptionService loads Express under. It is never a
    /// WhisperKit variant, and never stored as `activeModelId` or
    /// `selectedModelId`: those keep naming the Whisper model Express falls
    /// back to.
    static let modelID = "fluid-speech-mini"
    static let displayName = "Fluid Speech Mini"
    /// The credit line CC BY 4.0 asks for.
    static let attribution = "Fluid Speech Mini by FluidVoice"

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
        language == "en"
    }

    /// Fluid Speech Mini loads through FluidAudio as `.ultra`: the same
    /// encoder, decoder and joint contract, with its joint installed as
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
