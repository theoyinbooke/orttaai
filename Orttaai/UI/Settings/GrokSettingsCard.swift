// GrokSettingsCard.swift
// Orttaai

import AppKit
import SwiftUI

/// Grok rows under the AI Provider line. Model choice and the connection
/// check live on that line; this adds only the consent switch and, when the
/// CLI isn't reachable, how to fix it.
struct GrokProviderRows: View {
    /// The provider line's last health check: nil until it has run.
    let isReady: Bool?
    let statusMessage: String
    let onRecheck: () -> Void
    @AppStorage("grokConsentAcknowledged") private var consentAcknowledged = false

    var body: some View {
        if isReady == false {
            SettingsNotice(
                kind: .error,
                message: "\(statusMessage) Install it with: curl -fsSL https://x.ai/cli/install.sh | bash"
            )

            SettingsRow(
                title: "Grok CLI",
                info: "If Grok is installed somewhere Orttaai can't find it, choose the grok executable."
            ) {
                Button("Locate Grok…") {
                    chooseGrokExecutable()
                }
                .buttonStyle(OrttaaiButtonStyle(.secondary, size: .small))
            }

            SettingsDivider()
        }

        SettingsToggleRow(
            title: "Send Text to Grok",
            info: "Chat AI, writing insights, tone profile and graph summaries send your text to Grok through your CLI account. Dictation polish and voice edits always stay on this Mac. Grok stays off until this is on.",
            isOn: $consentAcknowledged
        )
    }

    private func chooseGrokExecutable() {
        let panel = NSOpenPanel()
        panel.title = "Locate the Grok CLI"
        panel.message = "Choose the grok executable installed on this Mac."
        panel.prompt = "Use Grok"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.resolvesAliases = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        UserDefaults.standard.set(url.path, forKey: GrokBinaryLocator.overridePathKey)
        onRecheck()
    }
}
