// GeneralSettingsView.swift
// Orttaai

import SwiftUI
import AppKit
import ServiceManagement
import os
import KeyboardShortcuts

struct GeneralSettingsView: View {
    @AppStorage("launchAtLogin") private var launchAtLogin = false
    @AppStorage("showProcessingEstimate") private var showProcessingEstimate = true
    @AppStorage("spokenFormattingEnabled") private var spokenFormattingEnabled = true
    @AppStorage("fuzzyDictionaryEnabled") private var fuzzyDictionaryEnabled = true
    @AppStorage("disfluencyCleanupEnabled") private var disfluencyCleanupEnabled = true
    @AppStorage("maxRecordingDuration") private var maxRecordingDuration = 90
    @AppStorage("handsFreeModeEnabled") private var handsFreeModeEnabled = true
    @AppStorage("handsFreeSilenceStopEnabled") private var handsFreeSilenceStopEnabled = true
    @AppStorage("handsFreeSilenceStopSeconds") private var handsFreeSilenceStopSeconds = 2.0
    @AppStorage("handsFreeMaxRecordingDuration") private var handsFreeMaxRecordingDuration = 600
    @AppStorage("editCommandsEnabled") private var editCommandsEnabled = true
    @State private var showClearConfirmation = false
    @State private var showResetConfirmation = false

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            VStack(spacing: 0) {
                toggleRow(
                    title: "Launch at Login",
                    isOn: $launchAtLogin
                )
                .onChange(of: launchAtLogin) { _, newValue in
                    updateLoginItem(enabled: newValue)
                }

                divider

                toggleRow(
                    title: "Show Processing Estimate",
                    isOn: $showProcessingEstimate
                )

                divider

                toggleRow(
                    title: "Spoken Formatting",
                    isOn: $spokenFormattingEnabled
                )
                .help("Formats spoken line, paragraph, and list commands")

                divider

                toggleRow(
                    title: "Fuzzy Dictionary Matching",
                    isOn: $fuzzyDictionaryEnabled
                )
                .help("Corrects near-miss spellings of your dictionary words, like Tematope for Temitope")

                divider

                toggleRow(
                    title: "Remove Fillers and Stutters",
                    isOn: $disfluencyCleanupEnabled
                )
                .help("Removes um and uh, collapses repeated words like the the, and capitalizes a lowercase i (English only)")

            }
            .padding(Spacing.md)
            .dashboardCard()

            VStack(alignment: .leading, spacing: Spacing.sm) {
                HStack {
                    Text("Max Recording Duration")
                        .font(.Orttaai.bodyMedium)
                        .foregroundStyle(Color.Orttaai.textPrimary)

                    Spacer()

                    Text("\(maxRecordingDuration)s")
                        .font(.Orttaai.mono)
                        .foregroundStyle(Color.Orttaai.accent)
                }

                Slider(
                    value: Binding(
                        get: { Double(maxRecordingDuration) },
                        set: { maxRecordingDuration = Int($0) }
                    ),
                    in: 10...120,
                    step: 5
                )
                .tint(Color.Orttaai.accent)

            }
            .padding(Spacing.md)
            .dashboardCard()

            handsFreeCard

            editCommandsCard

            CloudSyncSettingsView()

            VStack(alignment: .leading, spacing: Spacing.md) {
                Text("Shortcuts")
                    .font(.Orttaai.subheading)
                    .foregroundStyle(Color.Orttaai.textPrimary)

                VStack(spacing: 0) {
                    shortcutRow(
                        name: .pushToTalk,
                        title: "Push to Talk"
                    )

                    if editCommandsEnabled {
                        divider

                        shortcutRow(
                            name: .editCommand,
                            title: "Edit Selection with Voice"
                        )
                    }
                }
            }
            .padding(Spacing.md)
            .dashboardCard()

            VStack(alignment: .leading, spacing: Spacing.sm) {
                Text("Danger Zone")
                    .font(.Orttaai.subheading)
                    .foregroundStyle(Color.Orttaai.error)

                Button("Clear History") {
                    showClearConfirmation = true
                }
                .buttonStyle(OrttaaiButtonStyle(.secondary, destructive: true))
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

                Button("Reset App Data") {
                    showResetConfirmation = true
                }
                .buttonStyle(OrttaaiButtonStyle(.secondary, destructive: true))
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
            .padding(Spacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.Orttaai.errorSubtle.opacity(0.45))
            .clipShape(RoundedRectangle(cornerRadius: CornerRadius.card, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: CornerRadius.card, style: .continuous)
                    .stroke(Color.Orttaai.error.opacity(0.35), lineWidth: BorderWidth.standard)
            )
        }
        .padding(Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Hands-free (tap-to-toggle) dictation: enable/disable, silence
    /// auto-stop window, and the hands-free duration cap.
    private var handsFreeCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            toggleRow(
                title: "Hands-Free Dictation",
                isOn: $handsFreeModeEnabled
            )
            .help("Tap to start or stop. Hold for push to talk")

            if handsFreeModeEnabled {
                divider

                toggleRow(
                    title: "Stop After Silence",
                    isOn: $handsFreeSilenceStopEnabled
                )

                if handsFreeSilenceStopEnabled {
                    VStack(alignment: .leading, spacing: Spacing.sm) {
                        HStack {
                            Text("Silence Before Stopping")
                                .font(.Orttaai.bodyMedium)
                                .foregroundStyle(Color.Orttaai.textPrimary)

                            Spacer()

                            Text(String(format: "%.1fs", handsFreeSilenceStopSeconds))
                                .font(.Orttaai.mono)
                                .foregroundStyle(Color.Orttaai.accent)
                        }

                        Slider(value: $handsFreeSilenceStopSeconds, in: 1...5, step: 0.5)
                            .tint(Color.Orttaai.accent)
                    }
                    .padding(.top, Spacing.md)
                }

                divider

                VStack(alignment: .leading, spacing: Spacing.sm) {
                    HStack {
                        Text("Hands-Free Max Duration")
                            .font(.Orttaai.bodyMedium)
                            .foregroundStyle(Color.Orttaai.textPrimary)

                        Spacer()

                        Text("\(handsFreeMaxRecordingDuration / 60) min")
                            .font(.Orttaai.mono)
                            .foregroundStyle(Color.Orttaai.accent)
                    }

                    Slider(
                        value: Binding(
                            get: { Double(handsFreeMaxRecordingDuration) },
                            set: { handsFreeMaxRecordingDuration = Int($0) }
                        ),
                        in: 120...1800,
                        step: 60
                    )
                    .tint(Color.Orttaai.accent)

                }
            }
        }
        .padding(Spacing.md)
        .dashboardCard()
    }

    /// Voice edit commands: select text, speak an instruction, the selection
    /// is transformed in place through the local polish model.
    private var editCommandsCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            toggleRow(
                title: "Edit Selection with Voice",
                isOn: $editCommandsEnabled
            )
            .help("Select text, press the shortcut, and speak an edit")
        }
        .padding(Spacing.md)
        .dashboardCard()
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

    private var divider: some View {
        Divider()
            .background(Color.Orttaai.border.opacity(0.75))
            .padding(.vertical, Spacing.sm)
    }

    private func toggleRow(title: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            Text(title)
                .font(.Orttaai.bodyMedium)
                .foregroundStyle(Color.Orttaai.textPrimary)
        }
        .toggleStyle(OrttaaiToggleStyle())
    }

    private func shortcutRow(
        name: KeyboardShortcuts.Name,
        title: String
    ) -> some View {
        HStack(alignment: .center, spacing: Spacing.md) {
            Text(title)
                .font(.Orttaai.bodyMedium)
                .foregroundStyle(Color.Orttaai.textPrimary)

            Spacer(minLength: Spacing.lg)

            KeyboardShortcuts.Recorder(for: name)
                .padding(.horizontal, Spacing.sm)
                .padding(.vertical, Spacing.xs)
                .background(Color.Orttaai.bgPrimary.opacity(0.45))
                .clipShape(RoundedRectangle(cornerRadius: CornerRadius.input))
                .overlay(
                    RoundedRectangle(cornerRadius: CornerRadius.input)
                        .stroke(Color.Orttaai.border, lineWidth: BorderWidth.standard)
                )
        }
    }
}
