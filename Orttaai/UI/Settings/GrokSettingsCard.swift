// GrokSettingsCard.swift
// Orttaai

import AppKit
import SwiftUI

struct GrokSettingsCard: View {
    @AppStorage("grokModel") private var grokModel = GrokClient.defaultModel
    @AppStorage("grokConsentAcknowledged") private var consentAcknowledged = false
    @State private var health: OllamaHealthStatus?
    @State private var models: [String] = []
    @State private var isChecking = false

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            HStack(spacing: Spacing.sm) {
                Image(systemName: "bolt.horizontal.circle")
                    .foregroundStyle(Color.Orttaai.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Grok Account")
                        .font(.Orttaai.bodyMedium)
                        .foregroundStyle(Color.Orttaai.textPrimary)
                    Text("Uses the Grok CLI and the account already authenticated on this Mac.")
                        .font(.Orttaai.caption)
                        .foregroundStyle(Color.Orttaai.textSecondary)
                }
                Spacer()
                Button {
                    Task { await refresh() }
                } label: {
                    Label("Re-check", systemImage: "arrow.clockwise")
                }
                .buttonStyle(OrttaaiButtonStyle(.secondary))
                .disabled(isChecking)
            }

            if let health, health.isReachable {
                Label(health.message, systemImage: "checkmark.seal.fill")
                    .font(.Orttaai.caption)
                    .foregroundStyle(Color.Orttaai.success)
                Picker("Model", selection: $grokModel) {
                    ForEach(models.isEmpty ? [grokModel] : models, id: \.self) { model in
                        Text(model).tag(model)
                    }
                }
                .pickerStyle(.menu)
            } else {
                Label(health?.message ?? "Checking Grok CLI...", systemImage: "exclamationmark.triangle.fill")
                    .font(.Orttaai.caption)
                    .foregroundStyle(Color.Orttaai.error)
                Text("Install:  curl -fsSL https://x.ai/cli/install.sh | bash")
                    .font(.Orttaai.mono)
                    .foregroundStyle(Color.Orttaai.textPrimary)
                    .textSelection(.enabled)
                HStack(spacing: Spacing.sm) {
                    Button {
                        chooseGrokExecutable()
                    } label: {
                        Label("Locate Grok...", systemImage: "folder")
                    }
                    .buttonStyle(OrttaaiButtonStyle(.secondary))
                    Text("Orttaai checks ~/.grok/bin plus Homebrew, npm, pnpm, Bun, NVM, fnm, Volta, asdf, mise, Nix, MacPorts, user-local, and PATH locations.")
                        .font(.Orttaai.caption)
                        .foregroundStyle(Color.Orttaai.textTertiary)
                }
            }

            Toggle("I understand that selected text is sent to Grok through my CLI account.", isOn: $consentAcknowledged)
                .toggleStyle(OrttaaiToggleStyle())
                .font(.Orttaai.caption)
        }
        .task { await refresh() }
    }

    private func refresh() async {
        isChecking = true
        let client = LocalLLM.grokClient
        let status = await client.checkHealth(baseURLString: "", timeoutMs: 15_000)
        let discoveredModels = status.isReachable
            ? ((try? await client.fetchModelNames(baseURLString: "", timeoutMs: 15_000)) ?? [])
            : []
        await MainActor.run {
            health = status
            models = discoveredModels
            if models.isEmpty == false, models.contains(grokModel) == false {
                grokModel = models[0]
            }
            isChecking = false
        }
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
        Task { await refresh() }
    }
}
