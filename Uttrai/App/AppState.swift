// AppState.swift
// Uttrai

import Foundation

@Observable
final class AppState {
    var hardwareInfo: HardwareInfo
    var settings: AppSettings
    var isSetupComplete: Bool

    init() {
        self.hardwareInfo = HardwareDetector.detect()
        self.settings = AppSettings()
        self.isSetupComplete = AppSettings().hasCompletedSetup
    }
}
