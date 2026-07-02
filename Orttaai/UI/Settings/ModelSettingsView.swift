// ModelSettingsView.swift
// Orttaai

import SwiftUI
import Foundation

private enum ModelSortMode: String, CaseIterable {
    case size
    case recommended

    var title: String {
        switch self {
        case .size:
            return "Size"
        case .recommended:
            return "Recommended"
        }
    }
}

struct ModelSettingsView: View {
    @AppStorage("selectedModelId") private var selectedModelId = "openai_whisper-small"
    @AppStorage("modelSortMode") private var modelSortModeRaw: String = ModelSortMode.size.rawValue
    @AppStorage("lowLatencyModeEnabled") private var lowLatencyModeEnabled = false
    @AppStorage("dictationLanguage") private var dictationLanguage = "en"
    @AppStorage("computeMode") private var computeMode = "cpuAndNeuralEngine"
    @AppStorage("decodingPreset") private var decodingPresetRaw: String = DecodingPreset.fast.rawValue
    @AppStorage("advancedDecodingEnabled") private var advancedDecodingEnabled = false
    @AppStorage("decodingTemperature") private var decodingTemperature = DecodingPreferences.defaultTemperature
    @AppStorage("decodingTopK") private var decodingTopK = DecodingPreferences.defaultTopK
    @AppStorage("decodingFallbackCount") private var decodingFallbackCount = DecodingPreferences.defaultFallbackCount
    @AppStorage("decodingCompressionRatioThreshold") private var decodingCompressionRatioThreshold = DecodingPreferences.defaultCompressionRatioThreshold
    @AppStorage("decodingLogProbThreshold") private var decodingLogProbThreshold = DecodingPreferences.defaultLogProbThreshold
    @AppStorage("decodingNoSpeechThreshold") private var decodingNoSpeechThreshold = DecodingPreferences.defaultNoSpeechThreshold
    @AppStorage("decodingWorkerCount") private var decodingWorkerCount = DecodingPreferences.defaultWorkerCount
    @AppStorage("localLLMPolishEnabled") private var localLLMPolishEnabled = false
    @AppStorage("localLLMProvider") private var localLLMProviderRaw = LocalLLMProviderKind.ollama.rawValue
    @AppStorage("localLLMEndpoint") private var localLLMEndpoint = "http://127.0.0.1:11434"
    @AppStorage("lmStudioEndpoint") private var lmStudioEndpoint = "http://127.0.0.1:1234"
    @AppStorage("localLLMPolishModel") private var localLLMPolishModel = "gemma3:1b"
    @AppStorage("localLLMPolishTimeoutMs") private var localLLMPolishTimeoutMs = 650
    @AppStorage("localLLMPolishMaxChars") private var localLLMPolishMaxChars = 280
    @AppStorage("localLLMInsightsEnabled") private var localLLMInsightsEnabled = false
    @AppStorage("localLLMInsightsModel") private var localLLMInsightsModel = "qwen3.5:0.8b"
    @AppStorage("localLLMInsightsContextTokens") private var localLLMInsightsContextTokens = 16_384
    @AppStorage("localLLMInsightsThinkingEnabled") private var localLLMInsightsThinkingEnabled = false
    @AppStorage("semanticMemoryEnabled") private var semanticMemoryEnabled = true
    @AppStorage("semanticMemoryAutoIndexEnabled") private var semanticMemoryAutoIndexEnabled = true
    @AppStorage("semanticEmbeddingFallbackEnabled") private var semanticEmbeddingFallbackEnabled = true
    @AppStorage("semanticEmbeddingModel") private var semanticEmbeddingModel = "all-minilm"
    @AppStorage("semanticActiveIndexModelID") private var semanticActiveIndexModelID = ""
    @State private var diskUsage: String = "Checking downloaded models..."
    @State private var downloadedModelIDs: Set<String> = []
    @State private var models: [ModelInfo] = []
    @State private var isFetching: Bool = false
    @State private var isPickerExpanded: Bool = false
    @State private var isSwitching: Bool = false
    @State private var switchingModelId: String?
    @State private var switchError: String?
    @State private var deleteError: String?
    @State private var pendingDeleteModel: ModelInfo?
    @State private var isDeletingModel: Bool = false
    @State private var ollamaStatusMessage: String = "Check connection to validate local model availability."
    @State private var ollamaStatusReachable: Bool?
    @State private var installedOllamaModels: [String] = []
    @State private var isCheckingOllama: Bool = false
    @State private var isInstallingOllamaModel: Bool = false
    @State private var installingOllamaModelName: String?
    @State private var ollamaInstallStatusMessage: String?
    @State private var ollamaInstallProgress: Double?
    @State private var ollamaInstallError: String?
    @State private var ollamaInstallSuccessMessage: String?
    @State private var isWarmingOllamaModels: Bool = false
    @State private var ollamaWarmStatusMessage: String?
    @State private var ollamaWarmError: String?
    @State private var ollamaWarmSuccessMessage: String?
    @State private var downloadableOllamaModels: [OllamaCatalogModel] = []
    @State private var isLoadingOllamaCatalog: Bool = false
    @State private var ollamaCatalogMessage: String = "Check endpoint to load download options."
    @State private var selectedPolishDownloadModel: String = ""
    @State private var selectedInsightsDownloadModel: String = ""
    @State private var selectedSemanticDownloadModel: String = ""

    private let supportedLanguages: [(code: String, name: String)] = [
        ("en", "English"),
        ("es", "Spanish"),
        ("fr", "French"),
        ("de", "German"),
        ("ja", "Japanese"),
        ("zh", "Chinese"),
        ("ko", "Korean"),
        ("pt", "Portuguese"),
        ("it", "Italian"),
        ("nl", "Dutch"),
        ("ru", "Russian"),
        ("ar", "Arabic"),
        ("hi", "Hindi"),
        ("auto", "Auto-detect"),
    ]

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: Spacing.lg) {
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text("Model")
                        .font(.Orttaai.heading)
                        .foregroundStyle(Color.Orttaai.textPrimary)

                    Text("Choose a WhisperKit model for transcription.")
                        .font(.Orttaai.secondary)
                        .foregroundStyle(Color.Orttaai.textSecondary)
                }

                modelSelectorCard
                modelParametersCard
                localLLMCard

                if let switchError {
                    HStack(spacing: Spacing.sm) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(Color.Orttaai.error)
                        Text("Failed to switch model: \(switchError)")
                            .font(.Orttaai.secondary)
                            .foregroundStyle(Color.Orttaai.error)
                    }
                    .padding(Spacing.md)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.Orttaai.errorSubtle.opacity(0.45))
                    .clipShape(RoundedRectangle(cornerRadius: CornerRadius.card, style: .continuous))
                }

                if let deleteError {
                    HStack(spacing: Spacing.sm) {
                        Image(systemName: "trash.fill")
                            .foregroundStyle(Color.Orttaai.error)
                        Text("Failed to delete model: \(deleteError)")
                            .font(.Orttaai.secondary)
                            .foregroundStyle(Color.Orttaai.error)
                    }
                    .padding(Spacing.md)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.Orttaai.errorSubtle.opacity(0.45))
                    .clipShape(RoundedRectangle(cornerRadius: CornerRadius.card, style: .continuous))
                }

                if models.isEmpty && !isFetching {
                    Text("Loading models...")
                        .font(.Orttaai.secondary)
                        .foregroundStyle(Color.Orttaai.textTertiary)
                        .padding(Spacing.lg)
                }
            }
            .padding(WorkspaceLayout.contentInsets)
        }
        .onAppear {
            loadInitialModels()
            normalizeAdvancedDecodingValues()
            normalizeLocalLLMSettings()
            if localLLMPolishEnabled || localLLMInsightsEnabled {
                Task {
                    await checkOllamaAvailability()
                    await warmEnabledOllamaModelsIfNeeded(silent: true)
                }
            }
        }
        .onChange(of: modelSortModeRaw) { _, _ in
            models = sortedModelsForCurrentMode(models)
        }
        .onChange(of: lowLatencyModeEnabled) { _, enabled in
            applyLowLatencyDefaults(enabled: enabled)
        }
        .onChange(of: dictationLanguage) { _, newValue in
            guard lowLatencyModeEnabled, newValue == "auto" else { return }
            dictationLanguage = "en"
        }
        .onChange(of: localLLMPolishEnabled) { _, enabled in
            guard enabled else { return }
            Task {
                if ollamaStatusReachable != true {
                    await checkOllamaAvailability()
                }
                await warmEnabledOllamaModelsIfNeeded(silent: true)
            }
        }
        .onChange(of: localLLMInsightsEnabled) { _, enabled in
            guard enabled else { return }
            Task {
                if ollamaStatusReachable != true {
                    await checkOllamaAvailability()
                }
                await warmEnabledOllamaModelsIfNeeded(silent: true)
            }
        }
        .confirmationDialog(
            "Remove Downloaded Model?",
            isPresented: Binding(
                get: { pendingDeleteModel != nil },
                set: { isPresented in
                    if !isPresented { pendingDeleteModel = nil }
                }
            ),
            titleVisibility: .visible
        ) {
            Button("Remove Downloaded Files", role: .destructive) {
                guard let model = pendingDeleteModel else { return }
                pendingDeleteModel = nil
                deleteDownloadedModel(model)
            }
            Button("Cancel", role: .cancel) {
                pendingDeleteModel = nil
            }
        } message: {
            Text("This removes local model files to free storage. You can download the model again anytime.")
        }
    }

    private var selectedModel: ModelInfo? {
        let canonicalSelection = ModelManager.canonicalModelListID(selectedModelId)
        return models.first(where: { ModelManager.canonicalModelListID($0.id) == canonicalSelection })
    }

    private var displayNameForCurrentModel: String {
        selectedModel?.name ?? selectedModelId
    }

    private var switchingProgressMessage: String? {
        guard isSwitching, let switchingModelId else { return nil }
        let displayName = models.first(where: { $0.id == switchingModelId })?.name ?? switchingModelId
        return "Preparing \(displayName): loading and warming up now so first dictation stays fast."
    }

    private var ollamaStatusIconName: String {
        if ollamaStatusReachable == nil {
            return "questionmark.circle"
        }
        return ollamaStatusReachable == true ? "checkmark.circle.fill" : "exclamationmark.circle.fill"
    }

    private var ollamaStatusTint: Color {
        if ollamaStatusReachable == nil {
            return Color.Orttaai.textTertiary
        }
        return ollamaStatusReachable == true ? Color.Orttaai.success : Color.Orttaai.warning
    }

    private var normalizedPolishOllamaModel: String {
        localLLMPolishModel.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var normalizedInsightsOllamaModel: String {
        localLLMInsightsModel.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var normalizedSemanticEmbeddingModel: String {
        semanticEmbeddingModel.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var normalizedSelectedPolishDownloadModel: String {
        selectedPolishDownloadModel.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var normalizedSelectedInsightsDownloadModel: String {
        selectedInsightsDownloadModel.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var normalizedSelectedSemanticDownloadModel: String {
        selectedSemanticDownloadModel.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canInstallPolishModel: Bool {
        !normalizedSelectedPolishDownloadModel.isEmpty
    }

    private var canInstallInsightsModel: Bool {
        !normalizedSelectedInsightsDownloadModel.isEmpty
    }

    private var canInstallSemanticModel: Bool {
        !normalizedSelectedSemanticDownloadModel.isEmpty
    }

    private var modelSortMode: ModelSortMode {
        ModelSortMode(rawValue: modelSortModeRaw) ?? .size
    }

    private var recommendedPolishTimeoutMs: Int {
        let lower = normalizedPolishOllamaModel.lowercased()
        if lower.contains("qwen3.5:0.8b") { return 1_300 }
        if lower.contains("qwen3.5:2b") { return 1_400 }
        if lower.contains("qwen3.5:4b") { return 1_500 }
        return 600
    }

    private var polishRecommendationMessage: String {
        let lower = normalizedPolishOllamaModel.lowercased()
        if lower.contains(":4b") {
            return "This model is usually too heavy for fast polish. `gemma3:1b` is the safer default."
        }
        if localLLMPolishTimeoutMs < recommendedPolishTimeoutMs {
            return "Current timeout is aggressive for this model. Expect cold-start fallbacks until it is warmed."
        }
        return "Warm the model once after launch to keep polish inside the timeout budget."
    }

    private var insightsRecommendationMessage: String {
        let lower = normalizedInsightsOllamaModel.lowercased()
        if localLLMInsightsThinkingEnabled {
            return "Thinking is enabled for deeper analysis and can use more tokens."
        }
        if lower.contains("qwen3.5:4b") {
            return "This model can take longer for deeper on-device insights."
        }
        return "Thinking is off by default to keep insight runs lean."
    }

    private var formattedInsightsContextTokens: String {
        if localLLMInsightsContextTokens >= 1_024 {
            return "\(localLLMInsightsContextTokens / 1_024)K"
        }
        return "\(localLLMInsightsContextTokens)"
    }

    private var decodingPreset: DecodingPreset {
        DecodingPreset(rawValue: decodingPresetRaw) ?? .fast
    }

    private var modelSelectorCard: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text("Available Models")
                        .font(.Orttaai.subheading)
                        .foregroundStyle(Color.Orttaai.textPrimary)

                    Text("One-click switch with recommendation labels for your Mac.")
                        .font(.Orttaai.secondary)
                        .foregroundStyle(Color.Orttaai.textSecondary)
                }

                Spacer()

                if isFetching {
                    ProgressView()
                        .controlSize(.small)
                }

                Button {
                    Task { await fetchModels() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .buttonStyle(OrttaaiButtonStyle(.secondary))
                .disabled(isFetching)
            }

            Picker("Sort models", selection: $modelSortModeRaw) {
                ForEach(ModelSortMode.allCases, id: \.rawValue) { mode in
                    Text(mode.title).tag(mode.rawValue)
                }
            }
            .pickerStyle(.segmented)
            .tint(Color.Orttaai.accent)

            Button {
                withAnimation(.easeInOut(duration: 0.18)) {
                    isPickerExpanded.toggle()
                }
            } label: {
                selectorTrigger
            }
            .buttonStyle(.plain)

            if isPickerExpanded {
                Divider()
                    .overlay(Color.Orttaai.border)

                ScrollView(showsIndicators: false) {
                    LazyVStack(spacing: Spacing.sm) {
                        ForEach(models) { model in
                            compactModelRow(model)
                        }
                    }
                    .padding(.vertical, Spacing.xs)
                }
                .frame(maxHeight: 280)
            }

            if let switchingProgressMessage {
                HStack(spacing: Spacing.sm) {
                    ProgressView()
                        .controlSize(.small)
                    Text(switchingProgressMessage)
                        .lineLimit(2)
                }
                .font(.Orttaai.caption)
                .foregroundStyle(Color.Orttaai.accent)
            }

            HStack(spacing: Spacing.sm) {
                Image(systemName: "internaldrive")
                Text(diskUsage)
                    .lineLimit(1)
            }
            .font(.Orttaai.caption)
            .foregroundStyle(Color.Orttaai.textTertiary)
        }
        .padding(Spacing.lg)
        .dashboardCard()
    }

    private var modelParametersCard: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            HStack(alignment: .top, spacing: Spacing.md) {
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text("Compute & Decoding")
                        .font(.Orttaai.subheading)
                        .foregroundStyle(Color.Orttaai.textPrimary)

                    Text("Choose how transcription balances latency, hardware, and accuracy.")
                        .font(.Orttaai.secondary)
                        .foregroundStyle(Color.Orttaai.textSecondary)
                }

                Spacer(minLength: Spacing.md)

                Label("Next dictation", systemImage: "arrow.forward.circle")
                    .font(.Orttaai.caption)
                    .foregroundStyle(Color.Orttaai.textSecondary)
                    .padding(.horizontal, Spacing.sm)
                    .padding(.vertical, Spacing.xs)
                    .background(Color.Orttaai.bgTertiary.opacity(0.62))
                    .clipShape(Capsule())
            }

            VStack(alignment: .leading, spacing: Spacing.md) {
                Toggle(isOn: $lowLatencyModeEnabled) {
                    VStack(alignment: .leading, spacing: Spacing.xs) {
                        Text("Low Latency Mode")
                            .font(.Orttaai.bodyMedium)
                            .foregroundStyle(Color.Orttaai.textPrimary)

                        Text("Keeps startup and decode behavior lean for quick capture.")
                            .font(.Orttaai.secondary)
                            .foregroundStyle(Color.Orttaai.textSecondary)
                    }
                }
                .toggleStyle(OrttaaiToggleStyle())
                .padding(.vertical, Spacing.sm)
                .padding(.horizontal, Spacing.md)
                .background(Color.Orttaai.bgPrimary.opacity(0.42))
                .clipShape(RoundedRectangle(cornerRadius: CornerRadius.card, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: CornerRadius.card, style: .continuous)
                        .stroke(Color.Orttaai.border.opacity(0.72), lineWidth: BorderWidth.standard)
                )
                .help("Optimize for lower latency. Accuracy may be slightly reduced in difficult audio.")

                LazyVGrid(columns: computeControlColumns, spacing: Spacing.md) {
                    computeControlPanel(
                        title: "Dictation Language",
                        subtitle: "Avoid Auto-detect when speed matters.",
                        systemImage: "textformat"
                    ) {
                        OrttaaiDropdown(
                            selection: $dictationLanguage,
                            options: supportedLanguages.map { .init($0.code, $0.name) },
                            width: 180
                        )
                        .help("Sets decode language. Auto-detect can be slower.")
                    }

                    computeControlPanel(
                        title: "Compute Mode",
                        subtitle: computeModeSubtitle,
                        systemImage: "cpu"
                    ) {
                        OrttaaiDropdown(
                            selection: $computeMode,
                            options: [
                                .init("cpuAndNeuralEngine", "CPU + Neural Engine"),
                                .init("cpuAndGPU", "CPU + GPU"),
                                .init("cpuOnly", "CPU Only")
                            ],
                            width: 220
                        )
                        .help("Changes take effect after model reload.")
                    }
                }

                VStack(alignment: .leading, spacing: Spacing.sm) {
                    HStack(alignment: .firstTextBaseline, spacing: Spacing.sm) {
                        Label("Decoding Profile", systemImage: "dial.low")
                            .font(.Orttaai.bodyMedium)
                            .foregroundStyle(Color.Orttaai.textPrimary)

                        Spacer()

                        Text(decodingPreset.summary)
                            .font(.Orttaai.caption)
                            .foregroundStyle(Color.Orttaai.textTertiary)
                            .lineLimit(1)
                    }

                    LazyVGrid(columns: decodingProfileColumns, spacing: Spacing.sm) {
                        ForEach(DecodingPreset.allCases, id: \.rawValue) { preset in
                            decodingProfileTile(preset)
                        }
                    }
                }

                expertOverridesSection
            }
            .padding(Spacing.lg)
            .dashboardCard()
        }
    }

    private var computeControlColumns: [GridItem] {
        [GridItem(.adaptive(minimum: 420), spacing: Spacing.md)]
    }

    private var decodingProfileColumns: [GridItem] {
        // Three equal, flexible columns so each card grows and shrinks with the
        // window instead of locking to a fixed minimum width (which forced the
        // middle card's description to wrap at every size).
        Array(
            repeating: GridItem(.flexible(), spacing: Spacing.sm, alignment: .top),
            count: 3
        )
    }

    private var computeModeSubtitle: String {
        switch computeMode {
        case "cpuAndGPU":
            return "GPU acceleration can help on some Mac configurations."
        case "cpuOnly":
            return "CPU only is most predictable, but usually slower."
        default:
            return "Fastest default for Apple Silicon."
        }
    }

    private func computeControlPanel<Control: View>(
        title: String,
        subtitle: String,
        systemImage: String,
        @ViewBuilder control: () -> Control
    ) -> some View {
        HStack(alignment: .center, spacing: Spacing.md) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.Orttaai.accent)
                .frame(width: 30, height: 30)
                .background(Color.Orttaai.accentSubtle)
                .clipShape(RoundedRectangle(cornerRadius: CornerRadius.input, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.Orttaai.bodyMedium)
                    .foregroundStyle(Color.Orttaai.textPrimary)

                Text(subtitle)
                    .font(.Orttaai.caption)
                    .foregroundStyle(Color.Orttaai.textSecondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: Spacing.md)

            control()
                .labelsHidden()
        }
        .padding(.vertical, Spacing.sm)
        .padding(.horizontal, Spacing.md)
        .frame(maxWidth: .infinity, minHeight: 56, alignment: .center)
        .background(Color.Orttaai.bgPrimary.opacity(0.42))
        .clipShape(RoundedRectangle(cornerRadius: CornerRadius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: CornerRadius.card, style: .continuous)
                .stroke(Color.Orttaai.border.opacity(0.72), lineWidth: BorderWidth.standard)
        )
    }

    /// Bordered sub-panel matching the Compute & Decoding design language.
    private func llmGroupBox<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            content()
        }
        .padding(.vertical, Spacing.sm + 2)
        .padding(.horizontal, Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.Orttaai.bgPrimary.opacity(0.42))
        .clipShape(RoundedRectangle(cornerRadius: CornerRadius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: CornerRadius.card, style: .continuous)
                .stroke(Color.Orttaai.border.opacity(0.72), lineWidth: BorderWidth.standard)
        )
    }

    private func llmGroupHeader(icon: String, title: String, subtitle: String? = nil) -> some View {
        HStack(alignment: .center, spacing: Spacing.sm) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.Orttaai.accent)
                .frame(width: 28, height: 28)
                .background(Color.Orttaai.accentSubtle)
                .clipShape(RoundedRectangle(cornerRadius: CornerRadius.input, style: .continuous))

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.Orttaai.bodyMedium)
                    .foregroundStyle(Color.Orttaai.textPrimary)
                if let subtitle {
                    Text(subtitle)
                        .font(.Orttaai.caption)
                        .foregroundStyle(Color.Orttaai.textSecondary)
                }
            }

            Spacer(minLength: 0)
        }
    }

    private func decodingProfileTile(_ preset: DecodingPreset) -> some View {
        let isSelected = decodingPreset == preset

        return Button {
            withAnimation(.easeInOut(duration: 0.16)) {
                decodingPresetRaw = preset.rawValue
            }
        } label: {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                HStack(alignment: .center, spacing: Spacing.sm) {
                    Image(systemName: decodingProfileIcon(for: preset))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(isSelected ? Color.Orttaai.bgPrimary : Color.Orttaai.accent)
                        .frame(width: 24, height: 24)
                        .background(isSelected ? Color.Orttaai.accent : Color.Orttaai.accentSubtle)
                        .clipShape(RoundedRectangle(cornerRadius: CornerRadius.input, style: .continuous))

                    Text(preset.title)
                        .font(.Orttaai.bodyMedium)
                        .foregroundStyle(Color.Orttaai.textPrimary)
                        .lineLimit(1)

                    Spacer(minLength: 0)

                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Color.Orttaai.accent)
                    }
                }

                Text(preset.summary)
                    .font(.Orttaai.caption)
                    .foregroundStyle(Color.Orttaai.textSecondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: Spacing.xs) {
                    ForEach(decodingProfileTraits(for: preset), id: \.self) { trait in
                        Text(trait)
                            .font(.Orttaai.caption)
                            .foregroundStyle(isSelected ? Color.Orttaai.accent : Color.Orttaai.textTertiary)
                            .padding(.horizontal, Spacing.xs)
                            .padding(.vertical, 2)
                            .background(
                                (isSelected ? Color.Orttaai.accentSubtle : Color.Orttaai.bgTertiary.opacity(0.56))
                                    .clipShape(Capsule())
                            )
                    }
                }
            }
            .padding(Spacing.sm + 2)
            .frame(maxWidth: .infinity, minHeight: 92, alignment: .topLeading)
            .background(isSelected ? Color.Orttaai.accentSubtle : Color.Orttaai.bgPrimary.opacity(0.42))
            .clipShape(RoundedRectangle(cornerRadius: CornerRadius.card, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: CornerRadius.card, style: .continuous)
                    .stroke(
                        isSelected ? Color.Orttaai.accent.opacity(0.48) : Color.Orttaai.border.opacity(0.72),
                        lineWidth: BorderWidth.standard
                    )
            )
        }
        .buttonStyle(.plain)
        .help(preset.summary)
    }

    private var expertOverridesSection: some View {
        VStack(alignment: .leading, spacing: advancedDecodingEnabled ? Spacing.md : 0) {
            Toggle(isOn: $advancedDecodingEnabled) {
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text("Expert Overrides")
                        .font(.Orttaai.bodyMedium)
                        .foregroundStyle(Color.Orttaai.textPrimary)

                    Text("Manual decode values for testing only.")
                        .font(.Orttaai.caption)
                        .foregroundStyle(Color.Orttaai.textSecondary)
                }
            }
            .toggleStyle(OrttaaiToggleStyle())
            .padding(Spacing.md)
            .background(Color.Orttaai.bgPrimary.opacity(0.42))
            .clipShape(RoundedRectangle(cornerRadius: CornerRadius.card, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: CornerRadius.card, style: .continuous)
                    .stroke(Color.Orttaai.border.opacity(0.72), lineWidth: BorderWidth.standard)
            )
            .help("Advanced controls for power users. Defaults are safer for stable performance.")

            if advancedDecodingEnabled {
                advancedDecodingControls
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(.easeInOut(duration: 0.18), value: advancedDecodingEnabled)
    }

    private var advancedDecodingControls: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            HStack {
                Text("Temperature")
                    .font(.Orttaai.secondary)
                    .foregroundStyle(Color.Orttaai.textSecondary)
                Spacer()
                Text(String(format: "%.2f", decodingTemperature))
                    .font(.Orttaai.mono)
                    .foregroundStyle(Color.Orttaai.textPrimary)
            }
            Slider(value: $decodingTemperature, in: 0...1, step: 0.05)
                .tint(Color.Orttaai.accent)
                .help("Higher values increase randomness. Lower is more deterministic.")

            Stepper(value: $decodingTopK, in: 1...20) {
                rowValueLabel("Top-K", value: "\(decodingTopK)")
            }
            .help("Limits candidate tokens considered at each decode step.")

            Stepper(value: $decodingFallbackCount, in: 0...10) {
                rowValueLabel("Fallback Count", value: "\(decodingFallbackCount)")
            }
            .help("Number of retry attempts if decode confidence is low.")

            HStack {
                Text("No-Speech Threshold")
                    .font(.Orttaai.secondary)
                    .foregroundStyle(Color.Orttaai.textSecondary)
                Spacer()
                Text(String(format: "%.2f", decodingNoSpeechThreshold))
                    .font(.Orttaai.mono)
                    .foregroundStyle(Color.Orttaai.textPrimary)
            }
            Slider(value: $decodingNoSpeechThreshold, in: 0...1, step: 0.05)
                .tint(Color.Orttaai.accent)
                .help("Higher values make silence detection stricter.")

            HStack {
                Text("Log-Prob Threshold")
                    .font(.Orttaai.secondary)
                    .foregroundStyle(Color.Orttaai.textSecondary)
                Spacer()
                Text(String(format: "%.1f", decodingLogProbThreshold))
                    .font(.Orttaai.mono)
                    .foregroundStyle(Color.Orttaai.textPrimary)
            }
            Slider(value: $decodingLogProbThreshold, in: -3.0...0.0, step: 0.1)
                .tint(Color.Orttaai.accent)
                .help("Minimum token confidence before fallback triggers.")

            HStack {
                Text("Compression Threshold")
                    .font(.Orttaai.secondary)
                    .foregroundStyle(Color.Orttaai.textSecondary)
                Spacer()
                Text(String(format: "%.1f", decodingCompressionRatioThreshold))
                    .font(.Orttaai.mono)
                    .foregroundStyle(Color.Orttaai.textPrimary)
            }
            Slider(value: $decodingCompressionRatioThreshold, in: 1.5...4.0, step: 0.1)
                .tint(Color.Orttaai.accent)
                .help("Detects repetitive output. Lower values can trigger more fallbacks.")

            Stepper(value: $decodingWorkerCount, in: 0...8) {
                rowValueLabel(
                    "Worker Count",
                    value: decodingWorkerCount == 0 ? "Auto" : "\(decodingWorkerCount)"
                )
            }
            .help("Parallel decode workers. Auto uses model-aware defaults.")
        }
        .padding(Spacing.md)
        .background(Color.Orttaai.bgPrimary.opacity(0.42))
        .clipShape(RoundedRectangle(cornerRadius: CornerRadius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: CornerRadius.card, style: .continuous)
                .stroke(Color.Orttaai.border.opacity(0.72), lineWidth: BorderWidth.standard)
        )
    }

    private func decodingProfileIcon(for preset: DecodingPreset) -> String {
        switch preset {
        case .fast:
            return "bolt.fill"
        case .balanced:
            return "slider.horizontal.3"
        case .accuracy:
            return "scope"
        }
    }

    private func decodingProfileTraits(for preset: DecodingPreset) -> [String] {
        switch preset {
        case .fast:
            return ["Lowest delay", "Lean"]
        case .balanced:
            return ["Steady", "Default"]
        case .accuracy:
            return ["Difficult audio", "Resilient"]
        }
    }

    private var localLLMCard: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text("Local LLM")
                    .font(.Orttaai.subheading)
                    .foregroundStyle(Color.Orttaai.textPrimary)

                Text("Use a small local model to polish punctuation/spelling and generate deeper speaking insights.")
                    .font(.Orttaai.secondary)
                    .foregroundStyle(Color.Orttaai.textSecondary)
            }

            VStack(alignment: .leading, spacing: Spacing.md) {
                llmGroupBox {
                    Toggle(isOn: $localLLMPolishEnabled) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Enable Local Text Polish")
                                .font(.Orttaai.bodyMedium)
                                .foregroundStyle(Color.Orttaai.textPrimary)

                            Text("Runs a fast local post-pass after transcription with strict timeout fallback.")
                                .font(.Orttaai.caption)
                                .foregroundStyle(Color.Orttaai.textSecondary)
                        }
                    }
                    .toggleStyle(OrttaaiToggleStyle())
                }

                llmGroupBox {
                    HStack(alignment: .center, spacing: Spacing.sm) {
                        llmGroupHeader(
                            icon: "server.rack",
                            title: "\(providerKind.displayName) Connection",
                            subtitle: "Provider and endpoint shared by polish, insights, chat, and semantic memory."
                        )

                        OrttaaiDropdown(
                            selection: Binding(
                                get: { providerKind },
                                set: { newKind in
                                    localLLMProviderRaw = newKind.rawValue
                                    ollamaStatusReachable = nil
                                    ollamaStatusMessage = "Check connection to validate local model availability."
                                    installedOllamaModels = []
                                    Task { await checkOllamaAvailability() }
                                }
                            ),
                            options: LocalLLMProviderKind.allCases.map { .init($0, $0.displayName) },
                            width: 140
                        )
                    }

                    HStack(alignment: .center, spacing: Spacing.sm) {
                        OrttaaiTextField(
                            placeholder: providerKind.defaultEndpoint,
                            text: activeLLMEndpointBinding
                        )
                        .id(providerKind)

                        Button {
                            Task { await checkOllamaAvailability() }
                        } label: {
                            Label("Check", systemImage: "bolt.horizontal.circle")
                        }
                        .buttonStyle(OrttaaiButtonStyle(.secondary))
                        .disabled(isCheckingOllama || isInstallingOllamaModel || isLoadingOllamaCatalog)
                    }

                    if providerKind == .lmStudio {
                        Text("Model downloads are managed inside the LM Studio app. Models you download or load there appear here automatically.")
                            .font(.Orttaai.caption)
                            .foregroundStyle(Color.Orttaai.textTertiary)
                    }

                    HStack(spacing: Spacing.sm) {
                        Button {
                            Task {
                                if ollamaStatusReachable != true {
                                    await checkOllamaAvailability()
                                }
                                await warmEnabledOllamaModelsIfNeeded(silent: false)
                            }
                        } label: {
                            if isWarmingOllamaModels {
                                Label("Warming Models...", systemImage: "bolt.badge.clock")
                            } else {
                                Label("Warm Enabled Models", systemImage: "bolt.fill")
                            }
                        }
                        .buttonStyle(OrttaaiButtonStyle(.secondary))
                        .disabled(
                            isCheckingOllama ||
                            isInstallingOllamaModel ||
                            isLoadingOllamaCatalog ||
                            isWarmingOllamaModels
                        )

                        if let ollamaWarmStatusMessage {
                            HStack(spacing: Spacing.xs) {
                                if isWarmingOllamaModels {
                                    ProgressView().controlSize(.small)
                                }
                                Text(ollamaWarmStatusMessage)
                                    .font(.Orttaai.caption)
                                    .foregroundStyle(Color.Orttaai.textSecondary)
                            }
                        }
                    }

                    HStack(spacing: Spacing.xs) {
                        if isCheckingOllama {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: ollamaStatusIconName)
                                .foregroundStyle(ollamaStatusTint)
                        }
                        Text(ollamaStatusMessage)
                            .font(.Orttaai.caption)
                            .foregroundStyle(Color.Orttaai.textSecondary)
                    }

                    if !installedOllamaModels.isEmpty {
                        Text("Available on this Mac: \(installedOllamaModels.prefix(6).joined(separator: ", "))")
                            .font(.Orttaai.caption)
                            .foregroundStyle(Color.Orttaai.textTertiary)
                            .lineLimit(2)
                    }

                }

                if providerKind.supportsModelInstall {
                llmGroupBox {
                    llmGroupHeader(
                        icon: "arrow.down.circle",
                        title: "Curated Downloads",
                        subtitle: "Lightweight models (5B or smaller) for polish, insights, and semantic memory."
                    )

                    VStack(alignment: .leading, spacing: Spacing.xs) {
                        if isLoadingOllamaCatalog {
                            HStack(spacing: Spacing.xs) {
                                ProgressView().controlSize(.small)
                                Text("Loading curated lightweight models...")
                                    .font(.Orttaai.caption)
                                    .foregroundStyle(Color.Orttaai.textSecondary)
                            }
                        } else if !downloadableOllamaModels.isEmpty {
                            HStack(spacing: Spacing.sm) {
                                Text("Polish")
                                    .font(.Orttaai.secondary)
                                    .foregroundStyle(Color.Orttaai.textSecondary)
                                    .frame(width: 76, alignment: .leading)
                                OrttaaiDropdown(
                                    selection: $selectedPolishDownloadModel,
                                    options: downloadableOllamaModels.map { .init($0.name, ollamaCatalogLabel(for: $0)) },
                                    width: 300
                                )

                                Button {
                                    let model = normalizedSelectedPolishDownloadModel
                                    Task {
                                        await installOllamaModel(named: model)
                                        await MainActor.run { localLLMPolishModel = model }
                                    }
                                } label: {
                                    if isInstallingOllamaModel && installingOllamaModelName == normalizedSelectedPolishDownloadModel {
                                        Label("Installing Polish...", systemImage: "arrow.down.circle")
                                    } else if isOllamaModelInstalled(normalizedSelectedPolishDownloadModel) {
                                        Label("Polish Installed", systemImage: "checkmark.circle")
                                    } else {
                                        Label("Install Polish", systemImage: "arrow.down.circle")
                                    }
                                }
                                .buttonStyle(OrttaaiButtonStyle(.secondary))
                                .disabled(
                                    !canInstallPolishModel ||
                                        isCheckingOllama ||
                                        isLoadingOllamaCatalog ||
                                        isInstallingOllamaModel ||
                                        isOllamaModelInstalled(normalizedSelectedPolishDownloadModel)
                                )
                            }

                            HStack(spacing: Spacing.sm) {
                                Text("Insights")
                                    .font(.Orttaai.secondary)
                                    .foregroundStyle(Color.Orttaai.textSecondary)
                                    .frame(width: 76, alignment: .leading)
                                OrttaaiDropdown(
                                    selection: $selectedInsightsDownloadModel,
                                    options: downloadableOllamaModels.map { .init($0.name, ollamaCatalogLabel(for: $0)) },
                                    width: 300
                                )

                                Button {
                                    let model = normalizedSelectedInsightsDownloadModel
                                    Task {
                                        await installOllamaModel(named: model)
                                        await MainActor.run { localLLMInsightsModel = model }
                                    }
                                } label: {
                                    if isInstallingOllamaModel && installingOllamaModelName == normalizedSelectedInsightsDownloadModel {
                                        Label("Installing Insights...", systemImage: "arrow.down.circle")
                                    } else if isOllamaModelInstalled(normalizedSelectedInsightsDownloadModel) {
                                        Label("Insights Installed", systemImage: "checkmark.circle")
                                    } else {
                                        Label("Install Insights", systemImage: "arrow.down.circle")
                                    }
                                }
                                .buttonStyle(OrttaaiButtonStyle(.secondary))
                                .disabled(
                                    !canInstallInsightsModel ||
                                    isCheckingOllama ||
                                        isLoadingOllamaCatalog ||
                                        isInstallingOllamaModel ||
                                    isOllamaModelInstalled(normalizedSelectedInsightsDownloadModel)
                                )
                            }

                            HStack(spacing: Spacing.sm) {
                                Text("Semantic")
                                    .font(.Orttaai.secondary)
                                    .foregroundStyle(Color.Orttaai.textSecondary)
                                    .frame(width: 76, alignment: .leading)
                                OrttaaiDropdown(
                                    selection: $selectedSemanticDownloadModel,
                                    options: downloadableOllamaModels.map { .init($0.name, ollamaCatalogLabel(for: $0)) },
                                    width: 300
                                )

                                Button {
                                    let model = normalizedSelectedSemanticDownloadModel
                                    Task {
                                        await installOllamaModel(named: model)
                                        await MainActor.run {
                                            semanticEmbeddingModel = model
                                            semanticActiveIndexModelID = ""
                                        }
                                    }
                                } label: {
                                    if isInstallingOllamaModel && installingOllamaModelName == normalizedSelectedSemanticDownloadModel {
                                        Label("Installing Semantic...", systemImage: "arrow.down.circle")
                                    } else if isOllamaModelInstalled(normalizedSelectedSemanticDownloadModel) {
                                        Label("Semantic Installed", systemImage: "checkmark.circle")
                                    } else {
                                        Label("Install Semantic", systemImage: "arrow.down.circle")
                                    }
                                }
                                .buttonStyle(OrttaaiButtonStyle(.secondary))
                                .disabled(
                                    !canInstallSemanticModel ||
                                    isCheckingOllama ||
                                    isLoadingOllamaCatalog ||
                                    isInstallingOllamaModel ||
                                    isOllamaModelInstalled(normalizedSelectedSemanticDownloadModel)
                                )
                            }
                        } else {
                            Text(ollamaCatalogMessage)
                                .font(.Orttaai.caption)
                                .foregroundStyle(Color.Orttaai.textSecondary)
                        }

                        if let ollamaInstallStatusMessage {
                            if let ollamaInstallProgress {
                                ProgressView(value: ollamaInstallProgress) {
                                    Text(ollamaInstallStatusMessage)
                                        .font(.Orttaai.caption)
                                        .foregroundStyle(Color.Orttaai.textSecondary)
                                }
                                .tint(Color.Orttaai.accent)
                            } else {
                                HStack(spacing: Spacing.xs) {
                                    if isInstallingOllamaModel {
                                        ProgressView().controlSize(.small)
                                    }
                                    Text(ollamaInstallStatusMessage)
                                        .font(.Orttaai.caption)
                                        .foregroundStyle(Color.Orttaai.textSecondary)
                                }
                            }
                        }

                        if let ollamaInstallSuccessMessage {
                            HStack(spacing: Spacing.xs) {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(Color.Orttaai.success)
                                Text(ollamaInstallSuccessMessage)
                                    .font(.Orttaai.caption)
                                    .foregroundStyle(Color.Orttaai.success)
                            }
                        }

                        if let ollamaInstallError {
                            HStack(spacing: Spacing.xs) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(Color.Orttaai.error)
                                Text(ollamaInstallError)
                                    .font(.Orttaai.caption)
                                    .foregroundStyle(Color.Orttaai.error)
                            }
                        }

                        if let ollamaWarmSuccessMessage {
                            HStack(spacing: Spacing.xs) {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(Color.Orttaai.success)
                                Text(ollamaWarmSuccessMessage)
                                    .font(.Orttaai.caption)
                                    .foregroundStyle(Color.Orttaai.success)
                            }
                        }

                        if let ollamaWarmError {
                            HStack(spacing: Spacing.xs) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(Color.Orttaai.error)
                                Text(ollamaWarmError)
                                    .font(.Orttaai.caption)
                                    .foregroundStyle(Color.Orttaai.error)
                            }
                        }
                    }
                }
                }

                llmGroupBox {
                    llmGroupHeader(
                        icon: "wand.and.stars",
                        title: "Polish Model",
                        subtitle: "Model and time budget for the post-transcription cleanup pass."
                    )
                    OrttaaiDropdown(
                        selection: Binding(
                            get: { resolvedModelSelection(for: normalizedPolishOllamaModel) },
                            set: { localLLMPolishModel = $0 }
                        ),
                        options: modelDropdownOptions(current: normalizedPolishOllamaModel),
                        width: 280
                    )

                    HStack {
                        Text("Polish Timeout")
                            .font(.Orttaai.secondary)
                            .foregroundStyle(Color.Orttaai.textSecondary)
                        Spacer()
                        Text("\(localLLMPolishTimeoutMs) ms")
                            .font(.Orttaai.mono)
                            .foregroundStyle(Color.Orttaai.textPrimary)
                    }
                    Slider(
                        value: Binding(
                            get: { Double(localLLMPolishTimeoutMs) },
                            set: { localLLMPolishTimeoutMs = Int($0) }
                        ),
                        in: 80...1_500,
                        step: 10
                    )
                    .tint(Color.Orttaai.accent)

                    Stepper(value: $localLLMPolishMaxChars, in: 80...2_000, step: 20) {
                        rowValueLabel("Max Characters", value: "\(localLLMPolishMaxChars)")
                    }
                    .help("Long transcripts skip local polish to protect responsiveness.")

                    Text(polishRecommendationMessage)
                        .font(.Orttaai.caption)
                        .foregroundStyle(Color.Orttaai.textTertiary)
                }

                llmGroupBox {
                    Toggle(isOn: $localLLMInsightsEnabled) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Use Ollama for Writing Insights")
                                .font(.Orttaai.bodyMedium)
                                .foregroundStyle(Color.Orttaai.textPrimary)
                            Text("Uses local LLM analysis to surface speaking and writing patterns.")
                                .font(.Orttaai.caption)
                                .foregroundStyle(Color.Orttaai.textSecondary)
                        }
                    }
                    .toggleStyle(OrttaaiToggleStyle())

                    if localLLMInsightsEnabled {
                        divider

                        VStack(alignment: .leading, spacing: Spacing.sm) {
                        Text("Insights Model")
                            .font(.Orttaai.bodyMedium)
                            .foregroundStyle(Color.Orttaai.textPrimary)
                        OrttaaiDropdown(
                            selection: Binding(
                                get: { resolvedModelSelection(for: normalizedInsightsOllamaModel) },
                                set: { localLLMInsightsModel = $0 }
                            ),
                            options: modelDropdownOptions(current: normalizedInsightsOllamaModel),
                            width: 280
                        )

                        Stepper(value: $localLLMInsightsContextTokens, in: 8_192...262_144, step: 8_192) {
                            rowValueLabel("Context Window", value: "\(formattedInsightsContextTokens) tokens")
                        }

                        Toggle(isOn: $localLLMInsightsThinkingEnabled) {
                            VStack(alignment: .leading, spacing: Spacing.xs) {
                                Text("Enable Thinking")
                                    .font(.Orttaai.bodyMedium)
                                    .foregroundStyle(Color.Orttaai.textPrimary)
                                Text("Allows thinking-model reasoning during insight runs.")
                                    .font(.Orttaai.secondary)
                                    .foregroundStyle(Color.Orttaai.textSecondary)
                            }
                        }
                        .toggleStyle(OrttaaiToggleStyle())

                        Text(insightsRecommendationMessage)
                            .font(.Orttaai.caption)
                            .foregroundStyle(Color.Orttaai.textTertiary)
                        }
                    }
                }

                llmGroupBox {
                    Toggle(isOn: $semanticMemoryEnabled) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Enable Semantic Memory")
                                .font(.Orttaai.bodyMedium)
                                .foregroundStyle(Color.Orttaai.textPrimary)
                            Text("Indexes dictation history locally for graph view and semantic ChatAI context.")
                                .font(.Orttaai.caption)
                                .foregroundStyle(Color.Orttaai.textSecondary)
                        }
                    }
                    .toggleStyle(OrttaaiToggleStyle())

                    if semanticMemoryEnabled {
                        divider

                        VStack(alignment: .leading, spacing: Spacing.sm) {
                        Text("Semantic Embedding Model")
                            .font(.Orttaai.bodyMedium)
                            .foregroundStyle(Color.Orttaai.textPrimary)
                        OrttaaiDropdown(
                            selection: Binding(
                                get: { resolvedModelSelection(for: normalizedSemanticEmbeddingModel) },
                                set: { newValue in
                                    semanticEmbeddingModel = newValue
                                    semanticActiveIndexModelID = ""
                                }
                            ),
                            options: modelDropdownOptions(current: normalizedSemanticEmbeddingModel),
                            width: 280
                        )

                        Toggle(isOn: $semanticMemoryAutoIndexEnabled) {
                            VStack(alignment: .leading, spacing: Spacing.xs) {
                                Text("Auto-index for ChatAI")
                                    .font(.Orttaai.bodyMedium)
                                    .foregroundStyle(Color.Orttaai.textPrimary)
                                Text("Refreshes the local semantic index before semantic retrieval.")
                                    .font(.Orttaai.secondary)
                                    .foregroundStyle(Color.Orttaai.textSecondary)
                            }
                        }
                        .toggleStyle(OrttaaiToggleStyle())

                        Toggle(isOn: $semanticEmbeddingFallbackEnabled) {
                            VStack(alignment: .leading, spacing: Spacing.xs) {
                                Text("Use Lexical Fallback")
                                    .font(.Orttaai.bodyMedium)
                                    .foregroundStyle(Color.Orttaai.textPrimary)
                                Text("Builds a basic private graph if the selected embedding model is unavailable.")
                                    .font(.Orttaai.secondary)
                                    .foregroundStyle(Color.Orttaai.textSecondary)
                            }
                        }
                        .toggleStyle(OrttaaiToggleStyle())

                        Text("Recommended: install `all-minilm` for a tiny indexer, or `embeddinggemma` for stronger local semantic retrieval.")
                            .font(.Orttaai.caption)
                            .foregroundStyle(Color.Orttaai.textTertiary)
                        }
                    }
                }
            }
            .padding(Spacing.lg)
            .dashboardCard()
        }
    }

    private var selectorTrigger: some View {
        HStack(spacing: Spacing.md) {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                HStack(spacing: Spacing.sm) {
                    Text(displayNameForCurrentModel)
                        .font(.Orttaai.bodyMedium)
                        .foregroundStyle(Color.Orttaai.textPrimary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.86)

                    if let selectedModel {
                        modelBadgeCluster(for: selectedModel)
                    }
                }

                Text(metaLine(for: selectedModel))
                    .font(.Orttaai.secondary)
                    .foregroundStyle(Color.Orttaai.textSecondary)
                    .lineLimit(1)
            }

            Spacer()

            Image(systemName: isPickerExpanded ? "chevron.up" : "chevron.down")
                .font(.Orttaai.caption.weight(.semibold))
                .foregroundStyle(Color.Orttaai.textSecondary)
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: CornerRadius.input, style: .continuous)
                .fill(Color.Orttaai.bgPrimary.opacity(0.48))
        )
        .overlay(
            RoundedRectangle(cornerRadius: CornerRadius.input, style: .continuous)
                .stroke(Color.Orttaai.border, lineWidth: BorderWidth.standard)
        )
    }

    private func metaLine(for model: ModelInfo?) -> String {
        guard let model else { return "No model selected" }
        return "\(model.downloadSizeMB)MB • \(model.speedLabel.rawValue) • \(model.accuracyLabel.rawValue) accuracy"
    }

    // MARK: - Model Row

    private func compactModelRow(_ model: ModelInfo) -> some View {
        let modelID = ModelManager.canonicalModelListID(model.id)
        let selectedID = ModelManager.canonicalModelListID(selectedModelId)
        let downloadedCanonicalIDs = Set(downloadedModelIDs.map(ModelManager.canonicalModelListID))
        let isSelected = modelID == selectedID
        let isDownloaded = downloadedCanonicalIDs.contains(modelID)
        let isUnsupported = !model.isDeviceSupported
        let isThisSwitching = switchingModelId == model.id && isSwitching
        let switchingStatusText = isDownloaded ? "Loading + warm-up..." : "Downloading + warm-up..."

        return HStack(spacing: Spacing.sm) {
            Button {
                guard !isUnsupported, !isSwitching, !isDeletingModel else { return }
                switchToModel(model)
            } label: {
                HStack(spacing: Spacing.sm) {
                    if isThisSwitching {
                        ProgressView()
                            .controlSize(.small)
                            .frame(width: 13, height: 13)
                    } else {
                        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(isSelected ? Color.Orttaai.accent : Color.Orttaai.textTertiary)
                    }

                    Text(model.name)
                        .font(.Orttaai.bodyMedium)
                        .foregroundStyle(isUnsupported ? Color.Orttaai.textTertiary : Color.Orttaai.textPrimary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.86)

                    Text("\(model.downloadSizeMB)MB")
                        .font(.Orttaai.secondary)
                        .foregroundStyle(Color.Orttaai.textSecondary)
                        .lineLimit(1)

                    modelBadgeCluster(for: model)

                    Spacer(minLength: Spacing.sm)

                    if isThisSwitching {
                        Text(switchingStatusText)
                            .font(.Orttaai.caption)
                            .foregroundStyle(Color.Orttaai.accent)
                    } else if isSelected {
                        Text("Current")
                            .font(.Orttaai.caption)
                            .foregroundStyle(Color.Orttaai.accent)
                    } else if isDownloaded {
                        Text("Downloaded")
                            .font(.Orttaai.caption)
                            .foregroundStyle(Color.Orttaai.textSecondary)
                    }
                }
                .padding(.horizontal, Spacing.sm)
                .padding(.vertical, 7)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: CornerRadius.input, style: .continuous)
                        .fill(isSelected ? Color.Orttaai.accentSubtle : Color.Orttaai.bgPrimary.opacity(0.36))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: CornerRadius.input, style: .continuous)
                        .stroke(isSelected ? Color.Orttaai.accent.opacity(0.35) : Color.Orttaai.border, lineWidth: BorderWidth.standard)
                )
                .opacity(isUnsupported ? 0.62 : 1.0)
            }
            .buttonStyle(.plain)
            .disabled(isUnsupported || isSwitching || isDeletingModel)

            if isDownloaded && !isSelected {
                Button {
                    deleteError = nil
                    pendingDeleteModel = model
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.Orttaai.textSecondary)
                        .padding(.horizontal, Spacing.sm)
                        .padding(.vertical, 7)
                        .background(Color.Orttaai.bgPrimary.opacity(0.6))
                        .clipShape(RoundedRectangle(cornerRadius: CornerRadius.input, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: CornerRadius.input, style: .continuous)
                                .stroke(Color.Orttaai.border, lineWidth: BorderWidth.standard)
                        )
                }
                .buttonStyle(.plain)
                .help("Remove this model's downloaded files")
                .disabled(isSwitching || isDeletingModel)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func switchToModel(_ model: ModelInfo) {
        guard let manager = ModelManager.shared else {
            // ModelManager not initialized yet — fall back to just setting the preference
            selectedModelId = model.id
            return
        }

        switchError = nil
        isSwitching = true
        switchingModelId = model.id

        Task {
            do {
                try await manager.switchModel(to: model)
                selectedModelId = model.id
                withAnimation(.easeInOut(duration: 0.15)) {
                    isPickerExpanded = false
                }
                await refreshDownloadedMetrics()
            } catch {
                switchError = error.localizedDescription
            }
            isSwitching = false
            switchingModelId = nil
        }
    }

    private func deleteDownloadedModel(_ model: ModelInfo) {
        guard let manager = ModelManager.shared else {
            deleteError = "Model manager unavailable."
            return
        }

        let normalizedModelID = ModelManager.normalizedModelID(model.id)
        guard ModelManager.normalizedModelID(selectedModelId) != normalizedModelID else {
            deleteError = "Can't remove the current model. Switch models first."
            return
        }

        isDeletingModel = true
        Task {
            defer { isDeletingModel = false }
            do {
                try manager.deleteModel(named: model.id)
                await refreshDownloadedMetrics()
            } catch {
                deleteError = error.localizedDescription
            }
        }
    }

    @ViewBuilder
    private func modelBadgeCluster(for model: ModelInfo) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Spacing.xs) {
                compatibilityBadge(for: model)
                if model.isEnglishOnly {
                    badge("English", color: Color.Orttaai.textTertiary)
                }
            }

            HStack(spacing: Spacing.xs) {
                compatibilityBadge(for: model, compact: true)
                if model.isEnglishOnly {
                    badge("EN", color: Color.Orttaai.textTertiary, compact: true)
                }
            }

            compatibilityDot(for: model)
        }
    }

    @ViewBuilder
    private func compatibilityBadge(for model: ModelInfo, compact: Bool = false) -> some View {
        if model.isDeviceRecommended {
            badge(compact ? "Rec" : "Recommended", color: Color.Orttaai.accent, compact: compact)
        } else if model.isDeviceSupported {
            badge(compact ? "OK" : "Supported", color: Color.Orttaai.textSecondary, compact: compact)
        } else {
            badge("Heavy", color: Color.Orttaai.warning, compact: compact)
        }
    }

    private func compatibilityDot(for model: ModelInfo) -> some View {
        Circle()
            .fill(compatibilityColor(for: model))
            .frame(width: 8, height: 8)
            .overlay(
                Circle()
                    .stroke(Color.black.opacity(0.25), lineWidth: 0.5)
            )
            .accessibilityLabel(compatibilityText(for: model))
    }

    private func compatibilityColor(for model: ModelInfo) -> Color {
        if model.isDeviceRecommended { return Color.Orttaai.accent }
        if model.isDeviceSupported { return Color.Orttaai.textSecondary }
        return Color.Orttaai.warning
    }

    private func compatibilityText(for model: ModelInfo) -> String {
        if model.isDeviceRecommended { return "Recommended for this Mac" }
        if model.isDeviceSupported { return "Supported on this Mac" }
        return "May be heavy for this Mac"
    }

    private func badge(_ text: String, color: Color, compact: Bool = false) -> some View {
        Text(text)
            .font(.Orttaai.caption)
            .foregroundStyle(color)
            .padding(.horizontal, compact ? 6 : Spacing.sm)
            .padding(.vertical, compact ? 1 : 2)
            .background(color.opacity(0.12))
            .clipShape(Capsule())
            .lineLimit(1)
    }

    private var divider: some View {
        Divider()
            .background(Color.Orttaai.border.opacity(0.75))
            .padding(.vertical, Spacing.md)
    }

    private func applyLowLatencyDefaults(enabled: Bool) {
        guard enabled else { return }

        if dictationLanguage == "auto" {
            dictationLanguage = "en"
        }

        if computeMode == "cpuOnly" {
            computeMode = "cpuAndNeuralEngine"
        }
    }

    private func normalizeAdvancedDecodingValues() {
        let normalized = DecodingPreferences(
            preset: decodingPreset,
            expertOverridesEnabled: advancedDecodingEnabled,
            temperature: decodingTemperature,
            topK: decodingTopK,
            fallbackCount: decodingFallbackCount,
            compressionRatioThreshold: decodingCompressionRatioThreshold,
            logProbThreshold: decodingLogProbThreshold,
            noSpeechThreshold: decodingNoSpeechThreshold,
            workerCount: decodingWorkerCount
        ).clamped()

        decodingPresetRaw = normalized.preset.rawValue
        advancedDecodingEnabled = normalized.expertOverridesEnabled
        decodingTemperature = normalized.temperature
        decodingTopK = normalized.topK
        decodingFallbackCount = normalized.fallbackCount
        decodingCompressionRatioThreshold = normalized.compressionRatioThreshold
        decodingLogProbThreshold = normalized.logProbThreshold
        decodingNoSpeechThreshold = normalized.noSpeechThreshold
        decodingWorkerCount = normalized.workerCount
    }

    private func normalizeLocalLLMSettings() {
        localLLMEndpoint = localLLMEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        if localLLMEndpoint.isEmpty {
            localLLMEndpoint = "http://127.0.0.1:11434"
        }

        localLLMPolishModel = sanitizeLocalLLMModel(localLLMPolishModel, fallback: "gemma3:1b")
        localLLMInsightsModel = sanitizeLocalLLMModel(localLLMInsightsModel, fallback: "qwen3.5:0.8b")
        semanticEmbeddingModel = semanticEmbeddingModel.trimmingCharacters(in: .whitespacesAndNewlines)
        if semanticEmbeddingModel.isEmpty {
            semanticEmbeddingModel = "all-minilm"
        }
        semanticActiveIndexModelID = semanticActiveIndexModelID.trimmingCharacters(in: .whitespacesAndNewlines)

        // Migrate old default (220ms) which is usually too short for local polish.
        if localLLMPolishTimeoutMs == 220 {
            localLLMPolishTimeoutMs = 650
        }
        localLLMPolishTimeoutMs = max(80, min(1_500, localLLMPolishTimeoutMs))
        localLLMPolishMaxChars = max(80, min(2_000, localLLMPolishMaxChars))
        if localLLMInsightsContextTokens == 65_536 {
            localLLMInsightsContextTokens = 16_384
        } else {
            localLLMInsightsContextTokens = max(8_192, min(262_144, localLLMInsightsContextTokens))
        }
    }

    private var providerKind: LocalLLMProviderKind {
        LocalLLMProviderKind(rawValue: localLLMProviderRaw) ?? .ollama
    }

    private var activeLLMClient: any LocalLLMServing {
        LocalLLM.client(for: providerKind)
    }

    private var activeLLMEndpoint: String {
        providerKind == .ollama ? localLLMEndpoint : lmStudioEndpoint
    }

    private var activeLLMEndpointBinding: Binding<String> {
        providerKind == .ollama ? $localLLMEndpoint : $lmStudioEndpoint
    }

    private func checkOllamaAvailability() async {
        isCheckingOllama = true
        defer { isCheckingOllama = false }

        let providerName = providerKind.displayName
        let health = await activeLLMClient.checkHealth(
            baseURLString: activeLLMEndpoint,
            timeoutMs: 1_500
        )
        await MainActor.run {
            ollamaStatusReachable = health.isReachable
            ollamaStatusMessage = health.message
            installedOllamaModels = health.installedModels
        }

        // Curated one-click downloads only exist for Ollama; LM Studio manages
        // its own downloads.
        guard providerKind.supportsModelInstall else {
            await MainActor.run {
                downloadableOllamaModels = []
                ollamaCatalogMessage = ""
            }
            return
        }

        guard health.isReachable else {
            await MainActor.run {
                downloadableOllamaModels = []
                ollamaCatalogMessage = "\(providerName) must be reachable before loading downloadable models."
            }
            return
        }

        await fetchOllamaLibraryModels()
    }

    private func fetchOllamaLibraryModels() async {
        await MainActor.run {
            isLoadingOllamaCatalog = true
            ollamaCatalogMessage = "Loading curated lightweight models..."
        }

        do {
            let catalog = try await LocalLLM.ollamaClient.fetchLibraryModels(limit: 80)
            await MainActor.run {
                downloadableOllamaModels = catalog
                if catalog.isEmpty {
                    ollamaCatalogMessage = "No curated lightweight models configured."
                } else {
                    ollamaCatalogMessage = "Loaded \(catalog.count) curated models (all <= 5B)."
                    syncDownloadSelectionsFromCatalog()
                }
            }
        } catch {
            await MainActor.run {
                downloadableOllamaModels = []
                ollamaCatalogMessage = "Could not load Ollama library models: \(error.localizedDescription)"
            }
        }

        await MainActor.run {
            isLoadingOllamaCatalog = false
        }
    }

    private func syncDownloadSelectionsFromCatalog() {
        let names = downloadableOllamaModels.map(\.name)
        if !names.contains(selectedPolishDownloadModel) {
            selectedPolishDownloadModel = names.first(where: {
                canonicalOllamaModelName($0) == canonicalOllamaModelName(localLLMPolishModel)
            }) ?? names.first ?? ""
        }
        if !names.contains(selectedInsightsDownloadModel) {
            selectedInsightsDownloadModel = names.first(where: {
                canonicalOllamaModelName($0) == canonicalOllamaModelName(localLLMInsightsModel)
            }) ?? names.first ?? ""
        }
        if !names.contains(selectedSemanticDownloadModel) {
            selectedSemanticDownloadModel = names.first(where: {
                canonicalOllamaModelName($0) == canonicalOllamaModelName(semanticEmbeddingModel)
            }) ?? names.first(where: { $0.lowercased().contains("embed") || $0.lowercased().contains("minilm") }) ?? names.first ?? ""
        }
    }

    /// The installed model matching the stored value, or the stored value
    /// itself when the current provider doesn't have it.
    private func resolvedModelSelection(for currentValue: String) -> String {
        let canonicalCurrent = canonicalOllamaModelName(currentValue)
        return installedOllamaModels.first { canonicalOllamaModelName($0) == canonicalCurrent } ?? currentValue
    }

    /// Installed models, with the stored value injected at the top (flagged as
    /// not installed) when the current provider doesn't have it — so the
    /// dropdown always displays the active model without a separate text field.
    private func modelDropdownOptions(current: String) -> [OrttaaiDropdown<String>.Option] {
        var options = installedOllamaModels.map { OrttaaiDropdown<String>.Option($0, $0) }
        let canonicalCurrent = canonicalOllamaModelName(current)
        let isInstalled = installedOllamaModels.contains { canonicalOllamaModelName($0) == canonicalCurrent }
        if !isInstalled, !current.isEmpty {
            options.insert(.init(current, "\(current) (not installed)"), at: 0)
        }
        return options
    }

    private func ollamaCatalogLabel(for model: OllamaCatalogModel) -> String {
        if let size = model.sizeBytes, size > 0 {
            return "\(model.name) (\(formattedByteCount(size)))"
        }
        return model.name
    }

    private func formattedByteCount(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    private func sanitizeLocalLLMModel(_ value: String, fallback: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return fallback
        }
        if trimmed.lowercased().contains("llama") {
            return fallback
        }
        return trimmed
    }

    private func enabledOllamaModelsToWarm() -> [String] {
        var models: [String] = []
        if localLLMPolishEnabled {
            models.append(normalizedPolishOllamaModel)
        }
        if localLLMInsightsEnabled {
            models.append(normalizedInsightsOllamaModel)
        }

        return Array(Set(models.filter { !$0.isEmpty })).sorted()
    }

    private func warmEnabledOllamaModelsIfNeeded(silent: Bool) async {
        guard ollamaStatusReachable == true else {
            if !silent {
                await MainActor.run {
                    ollamaWarmError = "Ollama must be reachable before models can be warmed."
                    ollamaWarmSuccessMessage = nil
                }
            }
            return
        }

        let models = enabledOllamaModelsToWarm()
        guard !models.isEmpty else {
            if !silent {
                await MainActor.run {
                    ollamaWarmError = "Enable local polish or local insights to warm a model."
                    ollamaWarmSuccessMessage = nil
                }
            }
            return
        }

        await MainActor.run {
            isWarmingOllamaModels = true
            ollamaWarmStatusMessage = "Priming \(models.joined(separator: ", "))..."
            ollamaWarmError = nil
            ollamaWarmSuccessMessage = nil
        }

        let client = activeLLMClient
        let endpoint = activeLLMEndpoint
        var warmed: [(name: String, elapsedMs: Int)] = []

        do {
            for model in models {
                let elapsedMs = try await client.warmModel(
                    baseURLString: endpoint,
                    model: model,
                    timeoutMs: 40_000,
                    keepAlive: "5m"
                )
                warmed.append((name: model, elapsedMs: elapsedMs))
                await MainActor.run {
                    ollamaWarmStatusMessage = "Warmed \(model) in \(elapsedMs) ms."
                }
            }

            let summary = warmed
                .map { "\($0.name) (\($0.elapsedMs) ms)" }
                .joined(separator: ", ")
            await MainActor.run {
                ollamaWarmStatusMessage = nil
                ollamaWarmSuccessMessage = "Warm-up complete: \(summary)"
            }
        } catch {
            await MainActor.run {
                ollamaWarmError = "Warm-up failed: \(error.localizedDescription)"
            }
        }

        await MainActor.run {
            isWarmingOllamaModels = false
            if ollamaWarmError != nil {
                ollamaWarmStatusMessage = nil
            }
        }
    }

    private func installOllamaModel(named modelName: String) async {
        let normalizedModel = modelName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedModel.isEmpty else {
            ollamaInstallError = "Enter a model name before install (for example: gemma3:1b)."
            return
        }

        await MainActor.run {
            normalizeLocalLLMSettings()
            isInstallingOllamaModel = true
            installingOllamaModelName = normalizedModel
            ollamaInstallStatusMessage = "Starting download for \(normalizedModel)..."
            ollamaInstallProgress = nil
            ollamaInstallError = nil
            ollamaInstallSuccessMessage = nil
        }

        do {
            // Installs are Ollama-only; the button is hidden for LM Studio.
            try await LocalLLM.ollamaClient.pullModel(
                baseURLString: localLLMEndpoint,
                model: normalizedModel
            ) { progress in
                let message = formattedInstallMessage(progress)
                Task { @MainActor in
                    ollamaInstallStatusMessage = message
                    ollamaInstallProgress = progress.fractionCompleted
                }
            }

            await MainActor.run {
                ollamaInstallStatusMessage = nil
                ollamaInstallProgress = nil
                ollamaInstallSuccessMessage = "Installed \(normalizedModel)."
            }
            await checkOllamaAvailability()
        } catch {
            await MainActor.run {
                ollamaInstallProgress = nil
                ollamaInstallError = "Install failed for \(normalizedModel): \(error.localizedDescription)"
            }
        }

        await MainActor.run {
            isInstallingOllamaModel = false
            installingOllamaModelName = nil
        }
    }

    private func formattedInstallMessage(_ progress: OllamaPullProgress) -> String {
        let status = progress.status.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanStatus = status.isEmpty ? "Downloading \(progress.model)..." : status
        guard let completedBytes = progress.completedBytes, let totalBytes = progress.totalBytes, totalBytes > 0 else {
            return cleanStatus
        }

        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB]
        formatter.countStyle = .file
        let completed = formatter.string(fromByteCount: completedBytes)
        let total = formatter.string(fromByteCount: totalBytes)
        let percent = Int((Double(completedBytes) / Double(totalBytes)) * 100)
        return "\(cleanStatus) (\(percent)% • \(completed)/\(total))"
    }

    private func isOllamaModelInstalled(_ modelName: String) -> Bool {
        let canonical = canonicalOllamaModelName(modelName)
        guard !canonical.isEmpty else { return false }
        return installedOllamaModels.contains { canonicalOllamaModelName($0) == canonical }
    }

    private func canonicalOllamaModelName(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return "" }
        if trimmed.contains(":") {
            return trimmed
        }
        return "\(trimmed):latest"
    }

    private func rowValueLabel(_ title: String, value: String) -> some View {
        HStack {
            Text(title)
                .font(.Orttaai.secondary)
                .foregroundStyle(Color.Orttaai.textSecondary)
            Spacer()
            Text(value)
                .font(.Orttaai.mono)
                .foregroundStyle(Color.Orttaai.textPrimary)
        }
    }

    private func loadInitialModels() {
        // Start with hardcoded fallback, then fetch dynamically
        models = sortedModelsForCurrentMode(hardcodedFallbackModels())
        Task { await refreshDownloadedMetrics() }
        Task { await fetchModels() }
    }

    private func fetchModels() async {
        isFetching = true
        defer { isFetching = false }

        // Use ModelManager.shared to fetch the real model list from WhisperKit
        if let manager = ModelManager.shared {
            await manager.fetchModels()
            if !manager.availableModels.isEmpty {
                models = sortedModelsForCurrentMode(manager.availableModels)
                await refreshDownloadedMetrics()
                return
            }
        }

        // Fallback: build list from hardcoded model IDs
        let fetched = hardcodedModelIds().compactMap { name -> ModelInfo? in
            guard !name.contains("test") else { return nil }

            return ModelInfo(
                id: name,
                name: formatDisplayName(name),
                downloadSizeMB: estimateSize(name),
                description: descriptionFor(name),
                minimumTier: tierFor(name),
                speedLabel: speedLabelFor(name),
                accuracyLabel: accuracyLabelFor(name),
                isDeviceRecommended: isRecommended(name),
                isDeviceSupported: isSupported(name),
                isEnglishOnly: isEnglishOnlyModel(name)
            )
        }

        models = sortedModelsForCurrentMode(fetched)
        await refreshDownloadedMetrics()
    }

    // MARK: - Disk Usage

    private func refreshDownloadedMetrics() async {
        let metrics = await Task.detached(priority: .utility) {
            ModelManager.detectDownloadedModelMetrics()
        }.value

        let summary: String
        if metrics.downloadedModelIDs.isEmpty {
            summary = "No models downloaded"
        } else {
            let formatter = ByteCountFormatter()
            formatter.allowedUnits = [.useMB, .useGB]
            formatter.countStyle = .file
            let modelCount = metrics.downloadedModelIDs.count
            let sizeText = formatter.string(fromByteCount: metrics.totalBytes)
            summary = "\(modelCount) model\(modelCount == 1 ? "" : "s") downloaded • \(sizeText)"
        }

        await MainActor.run {
            downloadedModelIDs = metrics.downloadedModelIDs
            diskUsage = summary
        }
    }

    private func sortedModelsForCurrentMode(_ models: [ModelInfo]) -> [ModelInfo] {
        switch modelSortMode {
        case .size:
            return ModelManager.sortModelsBySize(models)
        case .recommended:
            return ModelManager.sortModelsByRecommendation(models)
        }
    }

    // MARK: - Model Metadata Helpers (fallback when ModelManager.shared is nil)

    private func hardcodedModelIds() -> [String] {
        [
            "openai_whisper-tiny",
            "openai_whisper-tiny.en",
            "openai_whisper-base",
            "openai_whisper-base.en",
            "openai_whisper-small",
            "openai_whisper-small.en",
            "openai_whisper-medium",
            "openai_whisper-medium.en",
            "openai_whisper-large-v3_turbo",
            "openai_whisper-large-v3",
        ]
    }

    private func hardcodedFallbackModels() -> [ModelInfo] {
        hardcodedModelIds().map { name in
            ModelInfo(
                id: name,
                name: formatDisplayName(name),
                downloadSizeMB: estimateSize(name),
                description: descriptionFor(name),
                minimumTier: tierFor(name),
                speedLabel: speedLabelFor(name),
                accuracyLabel: accuracyLabelFor(name),
                isDeviceRecommended: isRecommended(name),
                isDeviceSupported: isSupported(name),
                isEnglishOnly: isEnglishOnlyModel(name)
            )
        }
    }

    private func formatDisplayName(_ id: String) -> String {
        var name = id
            .replacingOccurrences(of: "openai_whisper-", with: "Whisper ")
            .replacingOccurrences(of: "openai_whisper_", with: "Whisper ")
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")

        name = name.split(separator: " ")
            .map { word in
                let w = String(word)
                if w.hasPrefix("v") && w.count <= 3 { return w.uppercased() }
                if w == "en" || w == ".en" { return "(English)" }
                return w.prefix(1).uppercased() + w.dropFirst()
            }
            .joined(separator: " ")

        // Handle ".en" suffix
        name = name.replacingOccurrences(of: ".(English)", with: " (English)")

        return name
    }

    private func estimateSize(_ id: String) -> Int {
        let lowered = id.lowercased()
        if lowered.contains("tiny") { return 70 }
        if lowered.contains("base") { return 140 }
        if lowered.contains("small") { return 300 }
        if lowered.contains("medium") { return 770 }
        if lowered.contains("large") && lowered.contains("turbo") { return 950 }
        if lowered.contains("large") { return 1500 }
        return 500
    }

    private func descriptionFor(_ id: String) -> String {
        let lowered = id.lowercased()
        if lowered.contains("tiny") { return "Quick notes, commands" }
        if lowered.contains("base") { return "Short dictation" }
        if lowered.contains("small") { return "General dictation" }
        if lowered.contains("medium") { return "Longer dictation" }
        if lowered.contains("large") && lowered.contains("turbo") { return "Maximum accuracy, optimized speed" }
        if lowered.contains("large") { return "Highest accuracy, slowest" }
        return "WhisperKit model"
    }

    private func tierFor(_ id: String) -> HardwareTier {
        let lowered = id.lowercased()
        if lowered.contains("tiny") || lowered.contains("base") || lowered.contains("small") {
            return .m1_8gb
        }
        if lowered.contains("medium") || (lowered.contains("large") && lowered.contains("turbo")) {
            return .m1_16gb
        }
        return .m3_16gb
    }

    private func speedLabelFor(_ id: String) -> SpeedLabel {
        let lowered = id.lowercased()
        if lowered.contains("tiny") { return .fastest }
        if lowered.contains("base") || lowered.contains("small") { return .fast }
        if lowered.contains("medium") || (lowered.contains("large") && lowered.contains("turbo")) { return .moderate }
        return .slow
    }

    private func accuracyLabelFor(_ id: String) -> AccuracyLabel {
        let lowered = id.lowercased()
        if lowered.contains("tiny") { return .basic }
        if lowered.contains("base") { return .good }
        if lowered.contains("small") || lowered.contains("medium") { return .great }
        return .best
    }

    private func isEnglishOnlyModel(_ id: String) -> Bool {
        let lowered = id.lowercased()
        return lowered.hasSuffix(".en") || lowered.hasSuffix("-en") || lowered.hasSuffix("_en")
    }

    private func isRecommended(_ id: String) -> Bool {
        let hardware = HardwareDetector.detect()
        return id == hardware.recommendedModel
    }

    private func isSupported(_ id: String) -> Bool {
        let hardware = HardwareDetector.detect()
        let tier = tierFor(id)
        switch (tier, hardware.tier) {
        case (.m1_8gb, _): return true
        case (.m1_16gb, .m1_16gb), (.m1_16gb, .m3_16gb): return true
        case (.m3_16gb, .m3_16gb): return true
        default: return hardware.tier != .intel_unsupported
        }
    }
}
