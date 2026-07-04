// CodexSettingsCard.swift
// Orttaai

import SwiftUI

/// Account, model, and usage controls for the ChatGPT (Codex) provider,
/// shown inside the Local LLM card when that provider is selected.
///
/// Drives four states from `CodexAccountService`: Codex not installed →
/// install guidance; outdated → update guidance; signed out / API-key-only →
/// "Sign in with ChatGPT"; signed in → account row, cloud model picker,
/// reasoning-effort picker, and the subscription usage meter.
struct CodexSettingsCard: View {
    @StateObject private var account = CodexAccountService()
    @AppStorage("codexModel") private var codexModel = "gpt-5.4-mini"
    @AppStorage(CodexClient.reasoningEffortKey) private var codexReasoningEffort = "medium"
    @AppStorage("codexConsentAcknowledged") private var codexConsentAcknowledged = false

    @State private var modelDetails: [CodexModelInfo] = []
    @State private var isLoadingModels = false

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            header

            switch account.state {
            case .unknown:
                HStack(spacing: Spacing.xs) {
                    ProgressView().controlSize(.small)
                    Text("Checking Codex installation and sign-in state...")
                        .font(.Orttaai.caption)
                        .foregroundStyle(Color.Orttaai.textSecondary)
                }
            case .codexNotInstalled:
                notInstalledSection
            case .codexOutdated(let found):
                outdatedSection(found: found)
            case .signedOut:
                signedOutSection(message: "Sign in with your ChatGPT account to use OpenAI models on your subscription.")
            case .apiKeyOnly:
                signedOutSection(message: "Codex is authenticated with an API key, which doesn't include a ChatGPT subscription. Sign in with ChatGPT instead.")
            case .signedIn(let email, let planType):
                signedInSection(email: email, planType: planType)
            }

            if let errorMessage = account.lastErrorMessage {
                HStack(spacing: Spacing.xs) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Color.Orttaai.error)
                    Text(errorMessage)
                        .font(.Orttaai.caption)
                        .foregroundStyle(Color.Orttaai.error)
                }
            }

            consentCaption
        }
        .task {
            await account.refresh()
            await loadModelsIfPossible()
        }
        .onChange(of: account.state) { _, _ in
            Task { await loadModelsIfPossible() }
        }
    }

    // MARK: - Sections

    private var header: some View {
        HStack(spacing: Spacing.sm) {
            Image(systemName: "sparkles")
                .foregroundStyle(Color.Orttaai.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text("ChatGPT Account")
                    .font(.Orttaai.bodyMedium)
                    .foregroundStyle(Color.Orttaai.textPrimary)
                Text("OpenAI models through your own ChatGPT subscription — no API key, billed to nobody but your existing plan.")
                    .font(.Orttaai.caption)
                    .foregroundStyle(Color.Orttaai.textSecondary)
            }
            Spacer()
            Button {
                Task {
                    await account.refresh()
                    await loadModelsIfPossible()
                }
            } label: {
                Label("Re-check", systemImage: "arrow.clockwise")
            }
            .buttonStyle(OrttaaiButtonStyle(.secondary))
            .disabled(account.isRefreshing || account.isSigningIn)
        }
    }

    private var notInstalledSection: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Label("Codex CLI not found", systemImage: "xmark.circle")
                .font(.Orttaai.bodyMedium)
                .foregroundStyle(Color.Orttaai.error)
            Text("This provider uses the Codex command-line tool that OpenAI ships for ChatGPT subscribers. Install it, then re-check:")
                .font(.Orttaai.caption)
                .foregroundStyle(Color.Orttaai.textSecondary)
            Text("brew install --cask codex")
                .font(.Orttaai.mono)
                .foregroundStyle(Color.Orttaai.textPrimary)
                .textSelection(.enabled)
            Text("Orttaai looks in /opt/homebrew/bin, /usr/local/bin, ~/.local/bin, and your PATH.")
                .font(.Orttaai.caption)
                .foregroundStyle(Color.Orttaai.textTertiary)
        }
    }

    private func outdatedSection(found: String) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Label("Codex CLI \(found) is too old", systemImage: "exclamationmark.triangle")
                .font(.Orttaai.bodyMedium)
                .foregroundStyle(Color.Orttaai.error)
            Text("Orttaai needs Codex \(CodexBinaryLocator.minimumVersion) or newer. Update it, then re-check:")
                .font(.Orttaai.caption)
                .foregroundStyle(Color.Orttaai.textSecondary)
            Text("codex update")
                .font(.Orttaai.mono)
                .foregroundStyle(Color.Orttaai.textPrimary)
                .textSelection(.enabled)
        }
    }

    private func signedOutSection(message: String) -> some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text(message)
                .font(.Orttaai.caption)
                .foregroundStyle(Color.Orttaai.textSecondary)
            HStack(spacing: Spacing.sm) {
                Button {
                    codexConsentAcknowledged = true
                    account.signIn()
                } label: {
                    if account.isSigningIn {
                        Label("Waiting for browser sign-in...", systemImage: "person.crop.circle.badge.clock")
                    } else {
                        Label("Sign in with ChatGPT", systemImage: "person.crop.circle.badge.checkmark")
                    }
                }
                .buttonStyle(OrttaaiButtonStyle(.primary))
                .disabled(account.isSigningIn)

                if account.isSigningIn {
                    Button("Cancel") { account.cancelSignIn() }
                        .buttonStyle(OrttaaiButtonStyle(.secondary))
                }
            }
            if account.isSigningIn {
                Text("Complete the sign-in in your browser; this page updates automatically.")
                    .font(.Orttaai.caption)
                    .foregroundStyle(Color.Orttaai.textTertiary)
            }
        }
    }

    private func signedInSection(email: String?, planType: String?) -> some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            HStack(spacing: Spacing.sm) {
                Image(systemName: "checkmark.seal.fill")
                    .foregroundStyle(Color.Orttaai.success)
                VStack(alignment: .leading, spacing: 2) {
                    Text(email?.isEmpty == false ? email! : "Signed in with ChatGPT")
                        .font(.Orttaai.bodyMedium)
                        .foregroundStyle(Color.Orttaai.textPrimary)
                    if let planType, !planType.isEmpty {
                        Text("ChatGPT \(planType.capitalized) plan")
                            .font(.Orttaai.caption)
                            .foregroundStyle(Color.Orttaai.textSecondary)
                    }
                }
                Spacer()
                Button("Sign Out") {
                    Task { await account.signOut() }
                }
                .buttonStyle(OrttaaiButtonStyle(.secondary))
            }

            divider

            modelPicker
            effortPicker
            usageMeter

            Text("Chat, insights, and tone analysis use this model. Dictation polish and semantic embeddings stay on your local provider.")
                .font(.Orttaai.caption)
                .foregroundStyle(Color.Orttaai.textTertiary)
        }
    }

    private var modelPicker: some View {
        HStack(spacing: Spacing.sm) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Model")
                    .font(.Orttaai.bodyMedium)
                    .foregroundStyle(Color.Orttaai.textPrimary)
                if let selected = modelDetails.first(where: { $0.id == codexModel }), !selected.summary.isEmpty {
                    Text(selected.summary)
                        .font(.Orttaai.caption)
                        .foregroundStyle(Color.Orttaai.textSecondary)
                }
            }
            Spacer()
            if isLoadingModels {
                ProgressView().controlSize(.small)
            }
            OrttaaiDropdown(
                selection: $codexModel,
                options: modelOptions,
                width: 200
            )
        }
    }

    private var effortPicker: some View {
        HStack(spacing: Spacing.sm) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Reasoning Effort")
                    .font(.Orttaai.bodyMedium)
                    .foregroundStyle(Color.Orttaai.textPrimary)
                Text("Higher effort thinks longer — better insights, slower replies, more usage.")
                    .font(.Orttaai.caption)
                    .foregroundStyle(Color.Orttaai.textSecondary)
            }
            Spacer()
            OrttaaiDropdown(
                selection: $codexReasoningEffort,
                options: effortOptions,
                width: 140
            )
        }
    }

    @ViewBuilder
    private var usageMeter: some View {
        if let limits = account.rateLimits {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                if let primary = limits.primary {
                    usageRow(label: windowLabel(minutes: primary.windowDurationMins, fallback: "Short window"), window: primary)
                }
                if let secondary = limits.secondary {
                    usageRow(label: windowLabel(minutes: secondary.windowDurationMins, fallback: "Weekly window"), window: secondary)
                }
            }
        }
    }

    private func usageRow(label: String, window: CodexRateLimitSnapshot.Window) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label)
                    .font(.Orttaai.caption)
                    .foregroundStyle(Color.Orttaai.textSecondary)
                Spacer()
                Text(resetText(for: window))
                    .font(.Orttaai.caption)
                    .foregroundStyle(Color.Orttaai.textTertiary)
            }
            ProgressView(value: Double(min(100, max(0, window.usedPercent))), total: 100)
                .tint(window.usedPercent >= 90 ? Color.Orttaai.error : Color.Orttaai.accent)
        }
    }

    private var consentCaption: some View {
        HStack(alignment: .top, spacing: Spacing.xs) {
            Image(systemName: "lock.icloud")
                .foregroundStyle(Color.Orttaai.textTertiary)
            Text("When this provider is enabled, your transcripts and insight data are sent to OpenAI under your ChatGPT account and handled per OpenAI's data policies.")
                .font(.Orttaai.caption)
                .foregroundStyle(Color.Orttaai.textTertiary)
        }
    }

    private var divider: some View {
        Rectangle()
            .fill(Color.Orttaai.textTertiary.opacity(0.15))
            .frame(height: 1)
    }

    // MARK: - Data

    private var modelOptions: [OrttaaiDropdown<String>.Option] {
        var options = modelDetails.map { OrttaaiDropdown<String>.Option($0.id, $0.displayName) }
        if !codexModel.isEmpty, !modelDetails.contains(where: { $0.id == codexModel }) {
            options.insert(.init(codexModel, codexModel), at: 0)
        }
        return options
    }

    private var effortOptions: [OrttaaiDropdown<String>.Option] {
        let selected = modelDetails.first { $0.id == codexModel }
        let efforts = selected?.supportedReasoningEfforts.isEmpty == false
            ? selected!.supportedReasoningEfforts
            : ["low", "medium", "high"]
        var options = efforts.map { OrttaaiDropdown<String>.Option($0, $0.capitalized) }
        if !efforts.contains(codexReasoningEffort) {
            options.insert(.init(codexReasoningEffort, codexReasoningEffort.capitalized), at: 0)
        }
        return options
    }

    private func loadModelsIfPossible() async {
        guard account.state.isUsable, !isLoadingModels else { return }
        isLoadingModels = true
        defer { isLoadingModels = false }
        if let details = try? await LocalLLM.codexClient.fetchModelDetails() {
            modelDetails = details
            if codexModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               let fallback = details.first(where: { $0.isDefault }) ?? details.first {
                codexModel = fallback.id
            }
        }
        await account.refreshRateLimits()
    }

    private func windowLabel(minutes: Int?, fallback: String) -> String {
        guard let minutes, minutes > 0 else { return fallback }
        if minutes % (24 * 60 * 7) == 0 { return "\(minutes / (24 * 60 * 7))-week usage" }
        if minutes % (24 * 60) == 0 { return "\(minutes / (24 * 60))-day usage" }
        if minutes % 60 == 0 { return "\(minutes / 60)-hour usage" }
        return "\(minutes)-minute usage"
    }

    private func resetText(for window: CodexRateLimitSnapshot.Window) -> String {
        var parts = ["\(window.usedPercent)% used"]
        if let resetsAt = window.resetsAt {
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .abbreviated
            parts.append("resets \(formatter.localizedString(for: resetsAt, relativeTo: Date()))")
        }
        return parts.joined(separator: " · ")
    }
}
