// ExpressEngineCard.swift
// Orttaai

import SwiftUI

/// Settings > Model > Speech: the whole Express chain in one place, in the
/// order it runs: the engine, Word Boost, then Polish. Polish is the app-wide
/// text polish setting, not an Express copy of it. Shown only on macOS 15 and
/// later.
struct ExpressEngineCard: View {
    let controller: ExpressController
    /// Opens Model > AI Features, where the polish model is chosen.
    var onShowPolishSettings: (() -> Void)?

    @AppStorage("expressEngineEnabled") private var expressEngineEnabled = false
    @AppStorage("expressWordBoostEnabled") private var expressWordBoostEnabled = true
    @AppStorage("dictationLanguage") private var dictationLanguage = "en"
    @AppStorage("localLLMPolishEnabled") private var localLLMPolishEnabled = false
    @AppStorage("appleIntelligencePolishEnabled") private var appleIntelligencePolishEnabled = false
    // Read so the polish footnote redraws when the model or provider changes.
    @AppStorage("localLLMPolishModel") private var localLLMPolishModel = "gemma4:e2b"
    @AppStorage("localLLMProvider") private var localLLMProviderRaw = LocalLLMProviderKind.ollama.rawValue

    private static let downloadSizeText = ByteCountFormatter.string(
        fromByteCount: ExpressModelStore.totalBytes,
        countStyle: .file
    )

    var body: some View {
        SettingsCard(
            "Express Engine",
            info: "Fluid Speech Mini, a compact English speech model that runs on the Neural Engine. It finishes a dictation in tens of milliseconds. Your Whisper model stays selected and is used for other languages, or whenever Express can't load."
        ) {
            statusChip
        } content: {
            VStack(alignment: .leading, spacing: 0) {
                detailRow(
                    "Use Express for dictation",
                    detail: "English only. Downloads \(Self.downloadSizeText) once: the speech model and the Word Boost model."
                ) {
                    OrttaaiSwitch(title: "Use Express for dictation", isOn: enabledBinding)
                        .disabled(controller.isBusy)
                }

                SettingsDivider()

                detailRow(
                    "Word Boost",
                    info: "Checks the words in your Memory dictionary against the audio, so names and terms come out spelled your way. Ordinary words are only replaced when the audio clearly supports it.",
                    detail: wordBoostStatus
                ) {
                    OrttaaiSwitch(title: "Word Boost", isOn: wordBoostBinding)
                        .disabled(!expressEngineEnabled || controller.isBusy)
                }

                SettingsDivider()

                detailRow(
                    "Polish",
                    info: "Cleans up punctuation, grammar and filler words with a local language model before the text is inserted. This is the same switch as Text Polish in AI Features, so it applies to Whisper dictations too.",
                    detail: polishStatus,
                    detailAction: onShowPolishSettings.map { ("Choose Model…", $0) }
                ) {
                    OrttaaiSwitch(title: "Polish", isOn: $localLLMPolishEnabled)
                }

                VStack(alignment: .leading, spacing: Spacing.xs) {
                    progressView

                    if expressEngineEnabled, !ExpressEngine.supportsLanguage(dictationLanguage) {
                        SettingsNotice(
                            kind: .info,
                            message: "Express is English only, so dictation uses your Whisper model while the language isn't English."
                        )
                    }

                    if case .failed(let message) = controller.status {
                        SettingsNotice(kind: .error, message: "Express couldn't start: \(message)")
                    }

                    if let fallbackMessage = controller.fallbackMessage {
                        SettingsNotice(kind: .warning, message: fallbackMessage) {
                            controller.dismissFallbackMessage()
                        }
                    }

                    if canRemoveModel {
                        Button {
                            controller.removeModel()
                        } label: {
                            Label("Remove Express Model", systemImage: "trash")
                        }
                        .buttonStyle(OrttaaiButtonStyle(.secondary, size: .small))
                        .padding(.top, Spacing.xs)
                    }
                }

                SettingsFootnote("\(ExpressEngine.attribution) (CC BY 4.0), built on NVIDIA Parakeet TDT 0.6B v3. Word Boost uses NVIDIA Parakeet CTC 110M (CC BY 4.0).")
                    .padding(.top, Spacing.sm)
            }
        }
        .task {
            await controller.refresh()
        }
    }

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { expressEngineEnabled },
            set: { controller.setEnabled($0) }
        )
    }

    private var wordBoostBinding: Binding<Bool> {
        Binding(
            get: { expressWordBoostEnabled },
            set: { controller.setWordBoostEnabled($0) }
        )
    }

    /// A setting with its explanation directly under the title, so each line
    /// of help sits with the switch it describes.
    private func detailRow<Control: View>(
        _ title: String,
        info: String? = nil,
        detail: String?,
        detailAction: (String, () -> Void)? = nil,
        @ViewBuilder control: () -> Control
    ) -> some View {
        HStack(alignment: .center, spacing: Spacing.sm) {
            VStack(alignment: .leading, spacing: 2) {
                SettingsLabel(title: title, info: info)
                if let detail {
                    HStack(alignment: .firstTextBaseline, spacing: Spacing.xs) {
                        Text(detail)
                            .font(.Orttaai.caption)
                            .foregroundStyle(Color.Orttaai.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                        if let (label, action) = detailAction {
                            Button(label, action: action)
                                .buttonStyle(.plain)
                                .font(.Orttaai.caption)
                                .foregroundStyle(Color.Orttaai.accent)
                        }
                    }
                }
            }
            Spacer(minLength: Spacing.md)
            control()
        }
        .padding(.vertical, Spacing.sm)
    }

    private var wordBoostStatus: String? {
        guard expressEngineEnabled, expressWordBoostEnabled, case .active = controller.status else { return nil }
        switch controller.boostedWordCount {
        case 0: return "Add words in Memory > Dictionary and Word Boost will listen for them."
        case 1: return "Boosting 1 dictionary word."
        default: return "Boosting \(controller.boostedWordCount) dictionary words."
        }
    }

    private var polishStatus: String {
        let settings = AppSettings()
        let model = "\(settings.normalizedLocalLLMPolishModel) on \(settings.polishLLMProvider.displayName)"
        guard localLLMPolishEnabled else {
            return "Off. When on, polishes with \(model)."
        }
        if appleIntelligencePolishEnabled, AppleIntelligencePolishProcessor.isModelAvailable {
            return "Polishes with \(model), then Apple Intelligence."
        }
        return "Polishes with \(model)."
    }

    private var canRemoveModel: Bool {
        guard !expressEngineEnabled else { return false }
        if case .installed = controller.status { return true }
        return false
    }

    @ViewBuilder
    private var progressView: some View {
        switch controller.status {
        case .downloading(let progress):
            ProgressView(value: progress) {
                Text("Downloading \(ExpressEngine.displayName)… \(Int(progress * 100))%")
                    .font(.Orttaai.caption)
                    .foregroundStyle(Color.Orttaai.textSecondary)
            }
            .tint(Color.Orttaai.accent)
            .padding(.vertical, Spacing.xs)
        case .loading:
            HStack(spacing: Spacing.xs) {
                ProgressView().controlSize(.small)
                Text("Preparing for the Neural Engine. The first time takes about 10 seconds.")
                    .font(.Orttaai.caption)
                    .foregroundStyle(Color.Orttaai.textSecondary)
            }
            .padding(.vertical, Spacing.xs)
        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private var statusChip: some View {
        switch controller.status {
        case .active:
            StatusChip(title: "Active", systemImage: "bolt.fill", tint: Color.Orttaai.success)
        case .downloading, .loading, .checking:
            StatusChip(title: "Working", systemImage: "arrow.down.circle", tint: Color.Orttaai.accent)
        case .failed:
            StatusChip(title: "Unavailable", systemImage: "exclamationmark.triangle.fill", tint: Color.Orttaai.error)
        case .installed:
            StatusChip(title: "Downloaded", systemImage: "checkmark.circle", tint: Color.Orttaai.textSecondary)
        case .notInstalled, .unsupported:
            StatusChip(title: "Beta", systemImage: "sparkles", tint: Color.Orttaai.textSecondary)
        }
    }
}
