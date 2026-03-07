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
    @AppStorage("localLLMEndpoint") private var localLLMEndpoint = "http://127.0.0.1:11434"
    @AppStorage("localLLMPolishModel") private var localLLMPolishModel = "gemma3:1b"
    @AppStorage("localLLMPolishTimeoutMs") private var localLLMPolishTimeoutMs = 650
    @AppStorage("localLLMPolishMaxChars") private var localLLMPolishMaxChars = 280
    @AppStorage("localLLMInsightsEnabled") private var localLLMInsightsEnabled = false
    @AppStorage("localLLMInsightsModel") private var localLLMInsightsModel = "qwen3.5:0.8b"
    @AppStorage("localLLMInsightsTimeoutMs") private var localLLMInsightsTimeoutMs = 7000
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
    @State private var downloadableOllamaModels: [OllamaCatalogModel] = []
    @State private var isLoadingOllamaCatalog: Bool = false
    @State private var ollamaCatalogMessage: String = "Check endpoint to load download options."
    @State private var selectedPolishDownloadModel: String = ""
    @State private var selectedInsightsDownloadModel: String = ""

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
            .padding(Spacing.xxl)
        }
        .onAppear {
            loadInitialModels()
            normalizeAdvancedDecodingValues()
            normalizeLocalLLMSettings()
            if localLLMPolishEnabled || localLLMInsightsEnabled {
                Task { await checkOllamaAvailability() }
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

    private var normalizedSelectedPolishDownloadModel: String {
        selectedPolishDownloadModel.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var normalizedSelectedInsightsDownloadModel: String {
        selectedInsightsDownloadModel.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canInstallPolishModel: Bool {
        !normalizedSelectedPolishDownloadModel.isEmpty
    }

    private var canInstallInsightsModel: Bool {
        !normalizedSelectedInsightsDownloadModel.isEmpty
    }

    private var modelSortMode: ModelSortMode {
        ModelSortMode(rawValue: modelSortModeRaw) ?? .size
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
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text("Model Parameters")
                    .font(.Orttaai.subheading)
                    .foregroundStyle(Color.Orttaai.textPrimary)

                Text("Tune speed and recognition behavior for your current model.")
                    .font(.Orttaai.secondary)
                    .foregroundStyle(Color.Orttaai.textSecondary)

                Text("Changes apply to the next dictation.")
                    .font(.Orttaai.caption)
                    .foregroundStyle(Color.Orttaai.textTertiary)
            }

            VStack(spacing: 0) {
                Toggle(isOn: $lowLatencyModeEnabled) {
                    VStack(alignment: .leading, spacing: Spacing.xs) {
                        Text("Low Latency Mode")
                            .font(.Orttaai.bodyMedium)
                            .foregroundStyle(Color.Orttaai.textPrimary)

                        Text("Prioritizes faster response with lighter decode behavior.")
                            .font(.Orttaai.secondary)
                            .foregroundStyle(Color.Orttaai.textSecondary)
                    }
                }
                .toggleStyle(OrttaaiToggleStyle())
                .help("Optimize for lower latency. Accuracy may be slightly reduced in difficult audio.")

                divider

                HStack(alignment: .center, spacing: Spacing.md) {
                    VStack(alignment: .leading, spacing: Spacing.xs) {
                        Text("Dictation Language")
                            .font(.Orttaai.bodyMedium)
                            .foregroundStyle(Color.Orttaai.textPrimary)

                        Text("Picking a language is usually faster than Auto-detect.")
                            .font(.Orttaai.secondary)
                            .foregroundStyle(Color.Orttaai.textSecondary)
                    }

                    Spacer(minLength: Spacing.lg)

                    Picker("", selection: $dictationLanguage) {
                        ForEach(supportedLanguages, id: \.code) { language in
                            Text(language.name).tag(language.code)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(width: 180)
                    .help("Sets decode language. Auto-detect can be slower.")
                }

                divider

                HStack(alignment: .center, spacing: Spacing.md) {
                    VStack(alignment: .leading, spacing: Spacing.xs) {
                        Text("Compute Mode")
                            .font(.Orttaai.bodyMedium)
                            .foregroundStyle(Color.Orttaai.textPrimary)

                        Text("CPU + Neural Engine is usually fastest on Apple Silicon.")
                            .font(.Orttaai.secondary)
                            .foregroundStyle(Color.Orttaai.textSecondary)

                        Text("Applied when the model reloads.")
                            .font(.Orttaai.caption)
                            .foregroundStyle(Color.Orttaai.textTertiary)
                    }

                    Spacer(minLength: Spacing.lg)

                    Picker("", selection: $computeMode) {
                        Text("CPU + Neural Engine").tag("cpuAndNeuralEngine")
                        Text("CPU + GPU").tag("cpuAndGPU")
                        Text("CPU Only").tag("cpuOnly")
                    }
                    .pickerStyle(.menu)
                    .frame(width: 220)
                    .help("Changes take effect after model reload (switch model or restart app).")
                }

                divider

                VStack(alignment: .leading, spacing: Spacing.sm) {
                    Text("Decoding Profile")
                        .font(.Orttaai.bodyMedium)
                        .foregroundStyle(Color.Orttaai.textPrimary)

                    Picker(
                        "Decoding Profile",
                        selection: Binding(
                            get: { decodingPresetRaw },
                            set: { decodingPresetRaw = $0 }
                        )
                    ) {
                        ForEach(DecodingPreset.allCases, id: \.rawValue) { preset in
                            Text(preset.title).tag(preset.rawValue)
                        }
                    }
                    .pickerStyle(.segmented)
                    .tint(Color.Orttaai.accent)
                    .help("Choose a default speed/quality profile.")

                    Text(decodingPreset.summary)
                        .font(.Orttaai.secondary)
                        .foregroundStyle(Color.Orttaai.textSecondary)
                }

                divider

                Toggle(isOn: $advancedDecodingEnabled) {
                    VStack(alignment: .leading, spacing: Spacing.xs) {
                        Text("Expert Overrides")
                            .font(.Orttaai.bodyMedium)
                            .foregroundStyle(Color.Orttaai.textPrimary)

                        Text("Manually override profile defaults for A/B tests.")
                            .font(.Orttaai.secondary)
                            .foregroundStyle(Color.Orttaai.textSecondary)
                    }
                }
                .toggleStyle(OrttaaiToggleStyle())
                .help("Advanced controls for power users. Defaults are safer for stable performance.")

                if advancedDecodingEnabled {
                    divider

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

                        Text("Use expert overrides only for A/B testing. Default profile is safer for stable speed.")
                            .font(.Orttaai.caption)
                            .foregroundStyle(Color.Orttaai.textTertiary)
                    }
                }
            }
            .padding(Spacing.lg)
            .dashboardCard()
        }
    }

    private var localLLMCard: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text("Local LLM (Ollama)")
                    .font(.Orttaai.subheading)
                    .foregroundStyle(Color.Orttaai.textPrimary)

                Text("Use a small local model to polish punctuation/spelling and generate deeper speaking insights.")
                    .font(.Orttaai.secondary)
                    .foregroundStyle(Color.Orttaai.textSecondary)
            }

            VStack(spacing: 0) {
                Toggle(isOn: $localLLMPolishEnabled) {
                    VStack(alignment: .leading, spacing: Spacing.xs) {
                        Text("Enable Local Text Polish")
                            .font(.Orttaai.bodyMedium)
                            .foregroundStyle(Color.Orttaai.textPrimary)

                        Text("Runs a fast local post-pass after transcription with strict timeout fallback.")
                            .font(.Orttaai.secondary)
                            .foregroundStyle(Color.Orttaai.textSecondary)
                    }
                }
                .toggleStyle(OrttaaiToggleStyle())

                divider

                VStack(alignment: .leading, spacing: Spacing.sm) {
                    Text("Ollama Endpoint")
                        .font(.Orttaai.bodyMedium)
                        .foregroundStyle(Color.Orttaai.textPrimary)

                    HStack(alignment: .center, spacing: Spacing.sm) {
                        OrttaaiTextField(placeholder: "http://127.0.0.1:11434", text: $localLLMEndpoint)

                        Button {
                            Task { await checkOllamaAvailability() }
                        } label: {
                            Label("Check", systemImage: "bolt.horizontal.circle")
                        }
                        .buttonStyle(OrttaaiButtonStyle(.secondary))
                        .disabled(isCheckingOllama || isInstallingOllamaModel || isLoadingOllamaCatalog)
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

                    VStack(alignment: .leading, spacing: Spacing.xs) {
                        Text("Curated Lightweight Downloads (<= 5B)")
                            .font(.Orttaai.bodyMedium)
                            .foregroundStyle(Color.Orttaai.textPrimary)

                        if isLoadingOllamaCatalog {
                            HStack(spacing: Spacing.xs) {
                                ProgressView().controlSize(.small)
                                Text("Loading curated lightweight models...")
                                    .font(.Orttaai.caption)
                                    .foregroundStyle(Color.Orttaai.textSecondary)
                            }
                        } else if !downloadableOllamaModels.isEmpty {
                            HStack(spacing: Spacing.sm) {
                                Picker("Polish Download", selection: $selectedPolishDownloadModel) {
                                    ForEach(downloadableOllamaModels) { model in
                                        Text(ollamaCatalogLabel(for: model)).tag(model.name)
                                    }
                                }
                                .pickerStyle(.menu)
                                .frame(width: 320)

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
                                Picker("Insights Download", selection: $selectedInsightsDownloadModel) {
                                    ForEach(downloadableOllamaModels) { model in
                                        Text(ollamaCatalogLabel(for: model)).tag(model.name)
                                    }
                                }
                                .pickerStyle(.menu)
                                .frame(width: 320)

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
                    }
                }

                divider

                VStack(alignment: .leading, spacing: Spacing.sm) {
                    Text("Polish Model")
                        .font(.Orttaai.bodyMedium)
                        .foregroundStyle(Color.Orttaai.textPrimary)
                    if !installedOllamaModels.isEmpty {
                        Picker(
                            "Use Installed Model",
                            selection: Binding(
                                get: { installedPickerSelection(for: normalizedPolishOllamaModel) },
                                set: { newValue in
                                    guard newValue != "__custom__" else { return }
                                    localLLMPolishModel = newValue
                                }
                            )
                        ) {
                            Text("Custom").tag("__custom__")
                            ForEach(installedOllamaModels, id: \.self) { name in
                                Text(name).tag(name)
                            }
                        }
                        .pickerStyle(.menu)
                        .frame(width: 280)
                    }
                    OrttaaiTextField(placeholder: "gemma3:1b", text: $localLLMPolishModel)

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
                }

                divider

                Toggle(isOn: $localLLMInsightsEnabled) {
                    VStack(alignment: .leading, spacing: Spacing.xs) {
                        Text("Use Ollama for Writing Insights")
                            .font(.Orttaai.bodyMedium)
                            .foregroundStyle(Color.Orttaai.textPrimary)
                        Text("Uses local LLM analysis to surface speaking and writing patterns.")
                            .font(.Orttaai.secondary)
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
                        if !installedOllamaModels.isEmpty {
                            Picker(
                                "Use Installed Model",
                                selection: Binding(
                                    get: { installedPickerSelection(for: normalizedInsightsOllamaModel) },
                                    set: { newValue in
                                        guard newValue != "__custom__" else { return }
                                        localLLMInsightsModel = newValue
                                    }
                                )
                            ) {
                                Text("Custom").tag("__custom__")
                                ForEach(installedOllamaModels, id: \.self) { name in
                                    Text(name).tag(name)
                                }
                            }
                            .pickerStyle(.menu)
                            .frame(width: 280)
                        }
                        OrttaaiTextField(placeholder: "qwen3.5:0.8b", text: $localLLMInsightsModel)

                        Stepper(value: $localLLMInsightsTimeoutMs, in: 1_500...30_000, step: 500) {
                            rowValueLabel("Insights Timeout", value: "\(localLLMInsightsTimeoutMs) ms")
                        }
                        .help("Longer timeout is useful for deeper analysis batches.")
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

        // Migrate old default (220ms) which is usually too short for local polish.
        if localLLMPolishTimeoutMs == 220 {
            localLLMPolishTimeoutMs = 650
        }
        localLLMPolishTimeoutMs = max(80, min(1_500, localLLMPolishTimeoutMs))
        localLLMPolishMaxChars = max(80, min(2_000, localLLMPolishMaxChars))
        localLLMInsightsTimeoutMs = max(1_500, min(30_000, localLLMInsightsTimeoutMs))
    }

    private func checkOllamaAvailability() async {
        isCheckingOllama = true
        defer { isCheckingOllama = false }

        let health = await OllamaClient().checkHealth(
            baseURLString: localLLMEndpoint,
            timeoutMs: 1_500
        )
        await MainActor.run {
            ollamaStatusReachable = health.isReachable
            ollamaStatusMessage = health.message
            installedOllamaModels = health.installedModels
        }

        guard health.isReachable else {
            await MainActor.run {
                downloadableOllamaModels = []
                ollamaCatalogMessage = "Ollama must be reachable before loading downloadable models."
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
            let catalog = try await OllamaClient().fetchLibraryModels(limit: 80)
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
    }

    private func installedPickerSelection(for currentValue: String) -> String {
        let canonicalCurrent = canonicalOllamaModelName(currentValue)
        if installedOllamaModels.contains(where: { canonicalOllamaModelName($0) == canonicalCurrent }) {
            if let matched = installedOllamaModels.first(where: { canonicalOllamaModelName($0) == canonicalCurrent }) {
                return matched
            }
        }
        return "__custom__"
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
            try await OllamaClient().pullModel(
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
