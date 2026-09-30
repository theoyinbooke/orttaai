// CodexSettingsCard.swift
// Orttaai

import AppKit
import SwiftUI

/// ChatGPT (Codex) rows under the AI Provider line. Model choice and the
/// connection check live on that line; this adds the account (sign in or
/// out), reasoning effort, and install guidance when Codex is missing.
struct CodexProviderRows: View {
    let onRecheck: () -> Void
    @StateObject private var account = CodexAccountService()
    @AppStorage("codexModel") private var codexModel = "gpt-5.4-mini"
    @AppStorage(CodexClient.reasoningEffortKey) private var codexReasoningEffort = "medium"
    @AppStorage("codexConsentAcknowledged") private var codexConsentAcknowledged = false

    @State private var modelDetails: [CodexModelInfo] = []
    @State private var isLoadingModels = false

    private static let disclosure = "ChatGPT sends transcripts and insight data to OpenAI."

    var body: some View {
        Group {
            switch account.state {
            case .unknown:
                EmptyView()
            case .codexNotInstalled:
                SettingsNotice(
                    kind: .error,
                    message: "Codex CLI not found. Install it with \u{201C}brew install --cask codex\u{201D} or \u{201C}npm install -g @openai/codex\u{201D}, then check again."
                )
                locateRow
            case .codexOutdated(let found):
                SettingsNotice(
                    kind: .error,
                    message: "Codex CLI \(found) is too old. Run \u{201C}codex update\u{201D} to get \(CodexBinaryLocator.minimumVersion) or newer."
                )
            case .signedOut:
                signInRow(info: "Sign in with your ChatGPT account to use OpenAI models on your subscription. \(Self.disclosure)")
            case .apiKeyOnly:
                signInRow(info: "Codex is signed in with an API key, which doesn't include a ChatGPT subscription. Sign in with ChatGPT instead. \(Self.disclosure)")
            case .signedIn(let email, let planType):
                signedInRows(email: email, planType: planType)
            }

            if let errorMessage = account.lastErrorMessage {
                SettingsNotice(kind: .error, message: errorMessage)
            }
        }
        .task {
            await account.refresh()
            await loadModelsIfPossible()
        }
        .onChange(of: account.state) { _, _ in
            Task { await loadModelsIfPossible() }
            onRecheck()
        }
        .onChange(of: codexModel) { _, _ in
            normalizeReasoningEffort()
        }
    }

    // MARK: - Rows

    private var locateRow: some View {
        SettingsRow(
            title: "Codex CLI",
            info: "If Codex is installed somewhere Orttaai can't find it, choose the codex executable."
        ) {
            Button("Locate Codex…") {
                chooseCodexExecutable()
            }
            .buttonStyle(OrttaaiButtonStyle(.secondary, size: .small))
        }
    }

    private func signInRow(info: String) -> some View {
        SettingsRow(title: "ChatGPT Account", info: info) {
            HStack(spacing: Spacing.sm) {
                if account.isSigningIn {
                    Text("Finish in your browser")
                        .font(.Orttaai.caption)
                        .foregroundStyle(Color.Orttaai.textTertiary)

                    Button("Cancel") { account.cancelSignIn() }
                        .buttonStyle(OrttaaiButtonStyle(.secondary, size: .small))
                }

                Button(account.isSigningIn ? "Signing In…" : "Sign In") {
                    codexConsentAcknowledged = true
                    account.signIn()
                }
                .buttonStyle(OrttaaiButtonStyle(.primary, size: .small))
                .disabled(account.isSigningIn)
            }
        }
    }

    @ViewBuilder
    private func signedInRows(email: String?, planType: String?) -> some View {
        SettingsRow(
            title: "ChatGPT Account",
            info: accountSummary(email: email, planType: planType)
        ) {
            Button("Sign Out") {
                Task { await account.signOut() }
            }
            .buttonStyle(OrttaaiButtonStyle(.secondary, size: .small))
        }

        SettingsDivider()

        SettingsRow(
            title: "Reasoning Effort",
            info: "Higher effort can improve results but takes longer."
        ) {
            HStack(spacing: Spacing.sm) {
                if isLoadingModels {
                    ProgressView().controlSize(.small)
                }
                OrttaaiDropdown(
                    selection: $codexReasoningEffort,
                    options: effortOptions,
                    width: SettingsLayout.controlWidth
                )
            }
        }
    }

    /// Account, plan, and usage for the info popover instead of on screen.
    private func accountSummary(email: String?, planType: String?) -> String {
        var lines: [String] = []
        if let email, !email.isEmpty {
            lines.append("Signed in as \(email).")
        } else {
            lines.append("Signed in with ChatGPT.")
        }
        if let planType, !planType.isEmpty {
            lines.append("ChatGPT \(planType.capitalized) plan.")
        }
        if let limits = account.rateLimits {
            if let primary = limits.primary {
                lines.append("\(windowLabel(minutes: primary.windowDurationMins, fallback: "Short-window usage")): \(resetText(for: primary)).")
            }
            if let secondary = limits.secondary {
                lines.append("\(windowLabel(minutes: secondary.windowDurationMins, fallback: "Weekly usage")): \(resetText(for: secondary)).")
            }
        }
        lines.append(Self.disclosure)
        return lines.joined(separator: "\n")
    }

    private func chooseCodexExecutable() {
        let panel = NSOpenPanel()
        panel.title = "Locate the Codex CLI"
        panel.message = "Choose the codex executable installed on this Mac."
        panel.prompt = "Use Codex"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.resolvesAliases = true

        guard panel.runModal() == .OK, let url = panel.url else { return }
        UserDefaults.standard.set(url.path, forKey: CodexBinaryLocator.overridePathKey)
        Task {
            await account.refresh()
            await loadModelsIfPossible()
        }
    }

    // MARK: - Data

    private var effortOptions: [OrttaaiDropdown<String>.Option] {
        let selected = modelDetails.first { $0.id == codexModel }
        let efforts = selected?.supportedReasoningEfforts.isEmpty == false
            ? selected!.supportedReasoningEfforts
            : ["low", "medium", "high"]
        var options = efforts.map { OrttaaiDropdown<String>.Option($0, $0.capitalized) }
        if selected == nil, !efforts.contains(codexReasoningEffort) {
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
            normalizeReasoningEffort()
        }
        await account.refreshRateLimits()
    }

    private func normalizeReasoningEffort() {
        guard let selected = modelDetails.first(where: { $0.id == codexModel }),
              let compatible = CodexClient.compatibleReasoningEffort(
                requested: codexReasoningEffort,
                model: selected
              ),
              compatible != codexReasoningEffort else { return }
        codexReasoningEffort = compatible
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
