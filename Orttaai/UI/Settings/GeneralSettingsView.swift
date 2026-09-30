// GeneralSettingsView.swift
// Orttaai

import SwiftUI
import AppKit
import ServiceManagement
import os

/// App-level behavior, sync, and the destructive resets.
struct GeneralSettingsView: View {
    @AppStorage("launchAtLogin") private var launchAtLogin = false
    @AppStorage("showProcessingEstimate") private var showProcessingEstimate = true
    @State private var showClearConfirmation = false
    @State private var showResetConfirmation = false

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            SettingsCard("App") {
                SettingsToggleRow(
                    title: "Launch at Login",
                    info: "Starts Orttaai when you log in to your Mac so dictation is always ready.",
                    isOn: $launchAtLogin
                )
                .onChange(of: launchAtLogin) { _, newValue in
                    updateLoginItem(enabled: newValue)
                }

                SettingsDivider()

                SettingsToggleRow(
                    title: "Show Processing Estimate",
                    info: "Shows roughly how long transcription will take in the pill while it finishes a recording.",
                    isOn: $showProcessingEstimate
                )
            }

            CloudSyncSettingsView()

            dangerZoneCard
        }
    }

    private var dangerZoneCard: some View {
        SettingsCard("Danger Zone") {
            SettingsRow(
                title: "Clear History",
                info: "Permanently deletes every saved transcription. Settings, Personal Memory, and models are kept."
            ) {
                Button("Clear History…") {
                    showClearConfirmation = true
                }
                .buttonStyle(OrttaaiButtonStyle(.secondary, destructive: true, size: .small))
                .confirmationDialog(
                    "Clear All History?",
                    isPresented: $showClearConfirmation,
                    titleVisibility: .visible
                ) {
                    Button("Clear History", role: .destructive) {
                        clearHistory()
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("This will permanently delete all transcriptions. This cannot be undone.")
                }
            }

            SettingsDivider()

            SettingsRow(
                title: "Reset App Data",
                info: "Clears onboarding, history, Personal Memory, insights, and downloaded models, then quits Orttaai."
            ) {
                Button("Reset App Data…") {
                    showResetConfirmation = true
                }
                .buttonStyle(OrttaaiButtonStyle(.secondary, destructive: true, size: .small))
                .confirmationDialog(
                    "Reset App Data?",
                    isPresented: $showResetConfirmation,
                    titleVisibility: .visible
                ) {
                    Button("Reset and Quit", role: .destructive) {
                        resetAppData()
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("This clears onboarding state, history, Personal Memory, insights, and downloaded models, then quits Orttaai.")
                }
            }
        }
    }

    private func updateLoginItem(enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            Logger.ui.error("Failed to update login item: \(error.localizedDescription)")
        }
    }

    private func clearHistory() {
        do {
            let db = try DatabaseManager()
            try db.deleteAll()
        } catch {
            Logger.database.error("Failed to clear history: \(error.localizedDescription)")
        }
    }

    private func resetAppData() {
        do {
            let db = try DatabaseManager()
            try db.resetAllLocalData()
        } catch {
            Logger.database.error("Failed to reset local database content: \(error.localizedDescription)")
        }

        AppResetService.resetUserDefaults()
        AppResetService.removeDownloadedModels()
        NSApplication.shared.terminate(nil)
    }
}
