// GeneralSettingsView.swift
// Orttaai

import SwiftUI
import ServiceManagement
import os
import KeyboardShortcuts

struct GeneralSettingsView: View {
    @AppStorage("launchAtLogin") private var launchAtLogin = false
    @AppStorage("showProcessingEstimate") private var showProcessingEstimate = true
    @AppStorage("maxRecordingDuration") private var maxRecordingDuration = 45
    @State private var showClearConfirmation = false

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text("General")
                    .font(.Orttaai.heading)
                    .foregroundStyle(Color.Orttaai.textPrimary)

                Text("Core preferences and keyboard control.")
                    .font(.Orttaai.secondary)
                    .foregroundStyle(Color.Orttaai.textSecondary)
            }

            VStack(spacing: 0) {
                toggleRow(
                    title: "Launch at Login",
                    subtitle: "Automatically start Orttaai when you sign in.",
                    isOn: $launchAtLogin
                )
                .onChange(of: launchAtLogin) { _, newValue in
                    updateLoginItem(enabled: newValue)
                }

                divider

                toggleRow(
                    title: "Show Processing Estimate",
                    subtitle: "Display ETA while transcriptions are being processed.",
                    isOn: $showProcessingEstimate
                )
            }
            .padding(Spacing.lg)
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

                Text("How long a single recording can last before auto-stopping.")
                    .font(.Orttaai.secondary)
                    .foregroundStyle(Color.Orttaai.textSecondary)

                Text("Model tuning options are in Settings > Model.")
                    .font(.Orttaai.caption)
                    .foregroundStyle(Color.Orttaai.textTertiary)
            }
            .padding(Spacing.lg)
            .dashboardCard()

            VStack(alignment: .leading, spacing: Spacing.md) {
                Text("Shortcuts")
                    .font(.Orttaai.subheading)
                    .foregroundStyle(Color.Orttaai.textPrimary)

                VStack(spacing: 0) {
                    shortcutRow(
                        name: .pushToTalk,
                        title: "Push to Talk",
                        subtitle: "Hold to start and release to transcribe."
                    )

                    divider

                    shortcutRow(
                        name: .pasteLastTranscript,
                        title: "Paste Last Transcript",
                        subtitle: "Insert your most recent dictation instantly."
                    )
                }
            }
            .padding(Spacing.lg)
            .dashboardCard()

            VStack(alignment: .leading, spacing: Spacing.sm) {
                Text("Danger Zone")
                    .font(.Orttaai.subheading)
                    .foregroundStyle(Color.Orttaai.error)

                Text("Clear all local transcriptions from this Mac.")
                    .font(.Orttaai.secondary)
                    .foregroundStyle(Color.Orttaai.textSecondary)

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
            }
            .padding(Spacing.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.Orttaai.errorSubtle.opacity(0.45))
            .clipShape(RoundedRectangle(cornerRadius: CornerRadius.card, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: CornerRadius.card, style: .continuous)
                    .stroke(Color.Orttaai.error.opacity(0.35), lineWidth: BorderWidth.standard)
            )
        }
        .padding(Spacing.xxl)
        .frame(maxWidth: .infinity, alignment: .leading)
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

    private var divider: some View {
        Divider()
            .background(Color.Orttaai.border.opacity(0.75))
            .padding(.vertical, Spacing.md)
    }

    private func toggleRow(title: String, subtitle: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text(title)
                    .font(.Orttaai.bodyMedium)
                    .foregroundStyle(Color.Orttaai.textPrimary)

                Text(subtitle)
                    .font(.Orttaai.secondary)
                    .foregroundStyle(Color.Orttaai.textSecondary)
            }
        }
        .toggleStyle(OrttaaiToggleStyle())
    }

    private func shortcutRow(
        name: KeyboardShortcuts.Name,
        title: String,
        subtitle: String
    ) -> some View {
        HStack(alignment: .center, spacing: Spacing.md) {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text(title)
                    .font(.Orttaai.bodyMedium)
                    .foregroundStyle(Color.Orttaai.textPrimary)

                Text(subtitle)
                    .font(.Orttaai.secondary)
                    .foregroundStyle(Color.Orttaai.textSecondary)
            }

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
