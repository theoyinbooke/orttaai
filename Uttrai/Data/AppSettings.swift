// AppSettings.swift
// Uttrai

import SwiftUI

final class AppSettings: ObservableObject {
    @AppStorage("selectedModelId") var selectedModelId: String = "openai_whisper-large-v3_turbo"
    @AppStorage("selectedAudioDeviceID") var selectedAudioDeviceID: String = ""
    @AppStorage("polishModeEnabled") var polishModeEnabled: Bool = false
    @AppStorage("launchAtLogin") var launchAtLogin: Bool = false
    @AppStorage("hasCompletedSetup") var hasCompletedSetup: Bool = false
    @AppStorage("showProcessingEstimate") var showProcessingEstimate: Bool = true

    var selectedAudioDevice: String? {
        selectedAudioDeviceID.isEmpty ? nil : selectedAudioDeviceID
    }
}
