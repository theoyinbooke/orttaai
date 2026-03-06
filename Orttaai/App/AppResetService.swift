// AppResetService.swift
// Orttaai

import Foundation
import os

enum AppResetService {
    static let fullResetLaunchArgument = "--reset-app-data"
    static let onboardingResetLaunchArgument = "--reset-onboarding"

    static func resetOnboardingState() {
        let settings = AppSettings()
        settings.hasCompletedSetup = false
        settings.fastFirstOnboardingEnabled = false
        settings.fastFirstRecommendedModelId = ""
        settings.fastFirstPrefetchStarted = false
        settings.fastFirstPrefetchReady = false
        settings.fastFirstUpgradeDismissed = false
        settings.fastFirstPrefetchErrorMessage = ""
        settings.githubStarPromptCompleted = false
        settings.githubStarPromptShownCount = 0
        settings.githubStarPromptLastShownAtEpoch = 0
        settings.activeModelId = ""
        Logger.ui.info("Onboarding state reset")
    }

    static func resetUserDefaults(bundleIdentifier: String = "com.orttaai.Orttaai") {
        UserDefaults.standard.removePersistentDomain(forName: bundleIdentifier)
        UserDefaults.standard.synchronize()
        Logger.ui.info("User defaults reset for \(bundleIdentifier)")
    }

    static func removeAppSupportArtifacts() {
        let fileManager = FileManager.default
        guard let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            Logger.ui.error("Unable to locate Application Support for reset")
            return
        }

        let appSupportFolder = appSupport.appendingPathComponent("Orttaai")
        if fileManager.fileExists(atPath: appSupportFolder.path) {
            do {
                try fileManager.removeItem(at: appSupportFolder)
                Logger.ui.info("Removed app support folder at \(appSupportFolder.path)")
            } catch {
                Logger.ui.error("Failed to remove app support folder: \(error.localizedDescription)")
            }
        }
    }

    static func removeDownloadedModels() {
        let fileManager = FileManager.default
        guard let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            Logger.ui.error("Unable to locate Application Support for model reset")
            return
        }

        let modelsFolder = appSupport.appendingPathComponent("Orttaai/Models")
        guard fileManager.fileExists(atPath: modelsFolder.path) else { return }

        do {
            try fileManager.removeItem(at: modelsFolder)
            Logger.ui.info("Removed downloaded models at \(modelsFolder.path)")
        } catch {
            Logger.ui.error("Failed to remove downloaded models: \(error.localizedDescription)")
        }
    }

    static func resetAllLocalData(bundleIdentifier: String = "com.orttaai.Orttaai") {
        resetUserDefaults(bundleIdentifier: bundleIdentifier)
        removeAppSupportArtifacts()
    }

    static func handleLaunchArguments() {
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains(fullResetLaunchArgument) {
            resetAllLocalData()
        } else if arguments.contains(onboardingResetLaunchArgument) {
            resetOnboardingState()
        }
    }
}
