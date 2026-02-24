// AppSettings.swift
// Orttaai

import SwiftUI
import Combine

final class AppSettings: ObservableObject {
    let objectWillChange = ObservableObjectPublisher()

    @AppStorage("selectedModelId") var selectedModelId: String = "openai_whisper-large-v3_turbo"
    @AppStorage("selectedAudioDeviceID") var selectedAudioDeviceID: String = ""
    @AppStorage("polishModeEnabled") var polishModeEnabled: Bool = false
    @AppStorage("launchAtLogin") var launchAtLogin: Bool = false
    @AppStorage("hasCompletedSetup") var hasCompletedSetup: Bool = false
    @AppStorage("showProcessingEstimate") var showProcessingEstimate: Bool = true
    @AppStorage("homeWorkspaceAutoOpenEnabled") var homeWorkspaceAutoOpenEnabled: Bool = true

    // Transcription
    @AppStorage("dictationLanguage") var dictationLanguage: String = "en"
    @AppStorage("maxRecordingDuration") var maxRecordingDuration: Int = 45

    // Advanced / Compute
    @AppStorage("computeMode") var computeMode: String = "cpuAndNeuralEngine"

    var selectedAudioDevice: String? {
        selectedAudioDeviceID.isEmpty ? nil : selectedAudioDeviceID
    }
}
