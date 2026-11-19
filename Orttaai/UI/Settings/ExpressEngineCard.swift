// ExpressEngineCard.swift
// Orttaai

import SwiftUI

/// Settings > Model > Speech: the whole Express chain in one place, in the
/// order it runs: the engine and its model (Express or Express Pro), Word
/// Boost, then Polish. Polish is the app-wide
/// text polish setting, not an Express copy of it. Shown only on macOS 15 and
/// later.
struct ExpressEngineCard: View {
    let controller: ExpressController
    /// Opens Model > AI Features, where the polish model is chosen.
    var onShowPolishSettings: (() -> Void)?

    @AppStorage("expressEngineEnabled") private var expressEngineEnabled = false
    @AppStorage("expressModel") private var expressModelRaw = ExpressModel.mini.rawValue
    @AppStorage("expressWordBoostEnabled") private var expressWordBoostEnabled = true
    @AppStorage("expressLiveSegmentsEnabled") private var expressLiveSegmentsEnabled = false
    @AppStorage("dictationLanguage") private var dictationLanguage = "en"
    @AppStorage("localLLMPolishEnabled") private var localLLMPolishEnabled = false
    // Read so the polish footnote redraws when the model or provider changes.
    @AppStorage("localLLMPolishModel") private var localLLMPolishModel = "gemma4:e2b"
    @AppStorage("localLLMProvider") private var localLLMProviderRaw = LocalLLMProviderKind.ollama.rawValue
    @AppStorage("polishEngine") private var polishEngine = "s1Mini"

    private static func downloadSizeText(_ model: ExpressModel) -> String {
        ByteCountFormatter.string(fromByteCount: ExpressModelStore.totalBytes(for: model), countStyle: .file)
    }

    /// The chosen model, or the one a switch is downloading.
    private var expressModel: ExpressModel {
        controller.pendingModel ?? ExpressModel(rawValue: expressModelRaw) ?? .mini
    }

    var body: some View {
        SettingsCard(
            "Express Engine",
            info: "Fluid Speech models that run on the Neural Engine and finish a dictation in tens of milliseconds. Your Whisper model stays selected and is used for languages Express doesn't cover, or whenever Express can't load."
        ) {
            statusChip
        } content: {
            VStack(alignment: .leading, spacing: 0) {
                detailRow(
                    "Use Express for dictation",
                    detail: "\(languageSummary). Downloads \(Self.downloadSizeText(expressModel)) once: the speech model and the Word Boost model."
                ) {
                    OrttaaiSwitch(title: "Use Express for dictation", isOn: enabledBinding)
                        .disabled(controller.isBusy)
                }

                SettingsDivider()

                detailRow(
                    "Model",
                    info: "Express uses Fluid Speech Mini, a compact English model. Express Pro uses Fluid Speech Pro: a larger download that makes a few fewer mistakes and also dictates in Bulgarian, Croatian, Czech, Danish, Dutch, Estonian, Finnish, French, German, Greek, Hungarian, Italian, Latvian, Lithuanian, Maltese, Polish, Portuguese, Romanian, Russian, Slovak, Slovenian, Spanish, Swedish and Ukrainian. Both are equally fast. Switching downloads the other model once, and the current one keeps dictating until it's ready. Both stay on this Mac until you remove them.",
                    detail: modelDetail
                ) {
                    OrttaaiSegmentedControl(
                        title: "Express model",
                        selection: modelBinding,
                        options: ExpressModel.allCases.map { .init($0, $0.productName) }
                    )
                    .fixedSize()
                    .disabled(controller.status == .loading)
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
                    "Decode while I speak",
                    info: "Each stretch of speech is decoded at your pauses while you're still talking, so a long dictation finishes about as fast as a short one. While Word Boost has dictionary words to check, dictation decodes the whole recording at the end instead, so no dictionary word is missed. Off by default while it's being tested.",
                    detail: "Long dictations finish sooner."
                ) {
                    OrttaaiSwitch(title: "Decode while I speak", isOn: $expressLiveSegmentsEnabled)
                        .disabled(!expressEngineEnabled)
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

                    if expressEngineEnabled, !expressModel.supportsLanguage(dictationLanguage) {
                        SettingsNotice(kind: .info, message: languageNotice)
                    }

                    if let switchError = controller.switchError {
                        SettingsNotice(kind: .warning, message: switchError) {
                            controller.dismissSwitchError()
                        }
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
                            Label("Remove Express Models", systemImage: "trash")
                        }
                        .buttonStyle(OrttaaiButtonStyle(.secondary, size: .small))
                        .padding(.top, Spacing.xs)
                    }
                }

                SettingsFootnote("\(expressModel.attribution) (CC BY 4.0), built on NVIDIA Parakeet TDT 0.6B v3 and Moondream Parakeet Ultra. Word Boost uses NVIDIA Parakeet CTC 110M (CC BY 4.0).")
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

    private var modelBinding: Binding<ExpressModel> {
        Binding(
            get: { expressModel },
            set: { controller.setModel($0) }
        )
    }

    private var languageSummary: String {
        switch expressModel {
        case .mini: return "English only"
        case .pro: return "English and 24 more European languages"
        }
    }

    private var modelDetail: String {
        switch expressModel {
        case .mini: return "Fluid Speech Mini. Compact, English."
        case .pro: return "Fluid Speech Pro. More accurate, 25 languages."
        }
    }

    private var languageNotice: String {
        switch expressModel {
        case .mini:
            return "Express is English only, so dictation uses your Whisper model while the language isn't English."
        case .pro where dictationLanguage == "auto":
            return "Express Pro needs a chosen language, so dictation uses your Whisper model while the language is set to Auto Detect."
        case .pro:
            return "Express Pro doesn't cover this language, so dictation uses your Whisper model."
        }
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
        if expressEngineEnabled, expressWordBoostEnabled,
           !ExpressEngine.usesEnglishPostProcessing(language: dictationLanguage) {
            return "Works on English dictation only."
        }
        guard expressEngineEnabled, expressWordBoostEnabled, case .active = controller.status else { return nil }
        switch controller.boostedWordCount {
        case 0: return "Add words in Memory > Dictionary and Word Boost will listen for them."
        case 1: return "Boosting 1 dictionary word."
        default: return "Boosting \(controller.boostedWordCount) dictionary words."
        }
    }

    private var polishStatus: String {
        let settings = AppSettings()
        let model: String
        switch settings.polishEngineChoice {
        case .s1Mini: model = "S1-mini on this Mac"
        case .localLLM: model = "\(settings.normalizedLocalLLMPolishModel) on \(settings.polishLLMProvider.displayName)"
        case .appleIntelligence: model = "Apple Intelligence"
        }
        guard localLLMPolishEnabled else {
            return "Off. When on, polishes with \(model)."
        }
        return "Polishes with \(model)."
    }

    /// With Express off and any Express model on disk. Removes them all.
    private var canRemoveModel: Bool {
        guard !expressEngineEnabled, controller.hasDownloadedModels else { return false }
        switch controller.status {
        case .installed, .notInstalled: return true
        default: return false
        }
    }

    @ViewBuilder
    private var progressView: some View {
        switch controller.status {
        case .downloading(let progress):
            ProgressView(value: progress) {
                Text("Downloading \(expressModel.displayName)… \(Int(progress * 100))%")
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
            StatusChip(title: "Not downloaded", systemImage: "arrow.down.circle", tint: Color.Orttaai.textSecondary)
        }
    }
}
