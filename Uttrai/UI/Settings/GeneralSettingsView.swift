// GeneralSettingsView.swift
// Uttrai

import SwiftUI
import ServiceManagement
import KeyboardShortcuts

struct GeneralSettingsView: View {
    @AppStorage("launchAtLogin") private var launchAtLogin = false
    @AppStorage("showProcessingEstimate") private var showProcessingEstimate = true
    @State private var showClearConfirmation = false

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xl) {
            Text("General")
                .font(.Uttrai.heading)
                .foregroundStyle(Color.Uttrai.textPrimary)

            Toggle("Launch at Login", isOn: $launchAtLogin)
                .toggleStyle(UttraiToggleStyle())
                .onChange(of: launchAtLogin) { _, newValue in
                    updateLoginItem(enabled: newValue)
                }

            Divider()
                .background(Color.Uttrai.border)

            ShortcutRecorderView(name: .pushToTalk, label: "Push to Talk")

            ShortcutRecorderView(name: .pasteLastTranscript, label: "Paste Last Transcript")

            Divider()
                .background(Color.Uttrai.border)

            Toggle("Show Processing Estimate", isOn: $showProcessingEstimate)
                .toggleStyle(UttraiToggleStyle())

            Divider()
                .background(Color.Uttrai.border)

            Button("Clear History") {
                showClearConfirmation = true
            }
            .buttonStyle(UttraiButtonStyle(.secondary, destructive: true))
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

            Spacer()
        }
        .padding(Spacing.xxl)
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
}
