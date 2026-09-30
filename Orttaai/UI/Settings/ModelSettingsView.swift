// ModelSettingsView.swift
// Orttaai

import SwiftUI
import Foundation
import AppKit

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

enum ModelPageSection: String, CaseIterable, Identifiable {
    case speech
    case ai

    var id: String { rawValue }

    var title: String {
        switch self {
        case .speech: return "Speech"
        case .ai: return "AI Features"
        }
    }

    var icon: String {
        switch self {
        case .speech: return "waveform"
        case .ai: return "brain"
        }
    }
}

struct ModelSettingsView: View {
    @AppStorage("selectedModelId") private var selectedModelId = "openai_whisper-small"
    @AppStorage("activeModelId") private var activeModelId = ""
    @AppStorage("quantizedMigrationDismissedFamilies") private var dismissedMigrationFamiliesRaw = ""
    @AppStorage("modelSortMode") private var modelSortModeRaw: String = ModelSortMode.size.rawValue
    @AppStorage("lowLatencyModeEnabled") private var lowLatencyModeEnabled = false
    @AppStorage("dictationLanguage") private var dictationLanguage = "en"
    @AppStorage("computeMode") private var computeMode = "cpuAndNeuralEngine"
    @AppStorage("decodingPreset") private var decodingPresetRaw: String = DecodingPreset.balanced.rawValue
    @AppStorage("advancedDecodingEnabled") private var advancedDecodingEnabled = false
    @AppStorage("decodingTemperature") private var decodingTemperature = DecodingPreferences.defaultTemperature
    @AppStorage("decodingTopK") private var decodingTopK = DecodingPreferences.defaultTopK
    @AppStorage("decodingFallbackCount") private var decodingFallbackCount = DecodingPreferences.defaultFallbackCount
    @AppStorage("decodingCompressionRatioThreshold") private var decodingCompressionRatioThreshold = DecodingPreferences.defaultCompressionRatioThreshold
    @AppStorage("decodingLogProbThreshold") private var decodingLogProbThreshold = DecodingPreferences.defaultLogProbThreshold
    @AppStorage("decodingNoSpeechThreshold") private var decodingNoSpeechThreshold = DecodingPreferences.defaultNoSpeechThreshold
    @AppStorage("decodingWorkerCount") private var decodingWorkerCount = DecodingPreferences.defaultWorkerCount
    @AppStorage("localLLMPolishEnabled") private var localLLMPolishEnabled = false
    @AppStorage("appleIntelligencePolishEnabled") private var appleIntelligencePolishEnabled = false
    @AppStorage("localLLMProvider") private var localLLMProviderRaw = LocalLLMProviderKind.ollama.rawValue
    @AppStorage("lastLocalLLMProvider") private var lastLocalLLMProviderRaw = LocalLLMProviderKind.ollama.rawValue
    @AppStorage("codexModel") private var codexModel = "gpt-5.4-mini"
    @AppStorage("grokModel") private var grokModel = GrokClient.defaultModel
    @AppStorage("localLLMEndpoint") private var localLLMEndpoint = "http://127.0.0.1:11434"
    @AppStorage("lmStudioEndpoint") private var lmStudioEndpoint = "http://127.0.0.1:1234"
    @AppStorage("localLLMPolishModel") private var localLLMPolishModel = "gemma4:e2b"
    @AppStorage("localLLMPolishTimeoutMs") private var localLLMPolishTimeoutMs = 3_000
    @AppStorage("localLLMPolishMaxChars") private var localLLMPolishMaxChars = 400
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
    @State private var downloadedVariants: [DownloadedVariantRecord] = []
    @State private var migratingFamilyID: String?
    @State private var migrationError: String?
    @State private var migrationSuccessMessage: String?
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
    @State private var modelStorage = ModelStorageLocation.placeholderSnapshot()
    @State private var modelStorageError: String?
    @State private var section: ModelPageSection

    init(initialSection: ModelPageSection = .speech) {
        _section = State(initialValue: initialSection)
    }

    var body: some View {
        TabbedWorkspacePage(
            title: "Model",
            tabs: ModelPageSection.allCases,
            selection: $section,
            tabTitle: \.title,
            tabIcon: \.icon
        ) { section in
            switch section {
            case .speech:
                VStack(alignment: .leading, spacing: Spacing.md) {
                    modelSelectorCard
                    modelStorageCard
                    performanceCard
                }
            case .ai:
                VStack(alignment: .leading, spacing: Spacing.md) {
                    providerCard
                    polishCard
                    insightsCard
                    semanticMemoryCard
                    if providerKind.supportsModelInstall {
                        modelDownloadsCard
                    }
                }
            }
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
            if lowLatencyModeEnabled, newValue == "auto" {
                dictationLanguage = "en"
                return
            }
            switchToLanguageOptimizedSmallModelIfNeeded()
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
        .onReceive(NotificationCenter.default.publisher(for: ModelStorageLocation.didChangeNotification)) { _ in
            refreshModelStorage()
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
            Text("Removes the model from this shared folder. You can download it again.")
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
        return "Preparing \(displayName)..."
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
        if lower.contains("gemma4:e2b") { return 2_500 }
        if lower.contains("gemma4:e4b") { return 3_000 }
        return 600
    }

    private var polishRecommendationMessage: String {
        let lower = normalizedPolishOllamaModel.lowercased()
        if lower.contains(":4b") {
            return "This model is usually too heavy for fast polish. `gemma4:e2b` is the eval-proven default."
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

    private var decodingPreset: DecodingPreset {
        DecodingPreset(rawValue: decodingPresetRaw) ?? .balanced
    }

    // MARK: - Speech tab

    private var modelSelectorCard: some View {
        SettingsCard(
            "Transcription Model",
            info: "The speech-recognition model that turns your voice into text. Larger models are more accurate but slower and use more memory."
        ) {
            HStack(spacing: Spacing.sm) {
                if isFetching {
                    ProgressView()
                        .controlSize(.small)
                }

                OrttaaiSegmentedControl(
                    title: "Sort models",
                    selection: $modelSortModeRaw,
                    options: ModelSortMode.allCases.map { .init($0.rawValue, $0.title) }
                )

                Button {
                    Task { await fetchModels() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(OrttaaiButtonStyle(.secondary, size: .small))
                .disabled(isFetching)
                .help("Refresh the model list")
                .accessibilityLabel("Refresh model list")
            }
        } content: {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        isPickerExpanded.toggle()
                    }
                } label: {
                    selectorTrigger
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Current model: \(displayNameForCurrentModel)")
                .accessibilityHint(isPickerExpanded ? "Hides the model list" : "Shows the model list")

                if isPickerExpanded {
                    ScrollView(showsIndicators: false) {
                        LazyVStack(spacing: Spacing.xs) {
                            ForEach(models) { model in
                                compactModelRow(model)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    .frame(maxHeight: 280)
                }

                if models.isEmpty && !isFetching {
                    SettingsFootnote("Loading models…")
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

                // Results appear here, next to the list that triggered them.
                if let switchError {
                    SettingsNotice(kind: .error, message: "Couldn't switch models: \(switchError)") {
                        self.switchError = nil
                    }
                }

                if let deleteError {
                    SettingsNotice(kind: .error, message: "Couldn't remove the model: \(deleteError)") {
                        self.deleteError = nil
                    }
                }

                if let migrationError {
                    SettingsNotice(kind: .error, message: "Quantized migration failed: \(migrationError)") {
                        self.migrationError = nil
                    }
                }

                if let migrationSuccessMessage {
                    SettingsNotice(kind: .success, message: migrationSuccessMessage) {
                        self.migrationSuccessMessage = nil
                    }
                }
            }
            .padding(.bottom, Spacing.xs)
        }
    }

    private var modelStorageCard: some View {
        SettingsCard(
            "Model Storage",
            info: "Where downloaded models are kept. Choose a folder on an external drive to save space on your Mac."
        ) {
            modelStorageStatusLabel
        } content: {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                HStack(spacing: Spacing.sm) {
                    Image(systemName: modelStorage.isCustom ? "externaldrive" : "internaldrive")
                        .foregroundStyle(modelStorage.isAvailable ? Color.Orttaai.accent : Color.Orttaai.error)
                        .accessibilityHidden(true)

                    Text(modelStorage.url.path)
                        .font(.Orttaai.mono)
                        .foregroundStyle(Color.Orttaai.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)

                    Spacer(minLength: 0)
                }

                Text(diskUsage)
                    .font(.Orttaai.caption)
                    .foregroundStyle(Color.Orttaai.textTertiary)

                if !modelStorage.isAvailable {
                    SettingsNotice(kind: .error, message: "Folder unavailable. Reconnect the drive or choose another folder.")
                } else if !modelStorage.isWritable {
                    SettingsNotice(kind: .warning, message: "Choose a writable folder for downloads.")
                }

                if let modelStorageError {
                    SettingsNotice(kind: .error, message: modelStorageError) {
                        self.modelStorageError = nil
                    }
                }

                HStack(spacing: Spacing.sm) {
                    Button {
                        chooseModelStorageLocation()
                    } label: {
                        Label("Choose Folder…", systemImage: "folder.badge.plus")
                    }
                    .buttonStyle(OrttaaiButtonStyle(.secondary, size: .small))

                    Button {
                        revealModelStorageLocation()
                    } label: {
                        Label("Show in Finder", systemImage: "folder")
                    }
                    .buttonStyle(OrttaaiButtonStyle(.secondary, size: .small))
                    .disabled(!modelStorage.isAvailable)

                    if modelStorage.isCustom {
                        Button("Use Default") {
                            ModelStorageLocation.resetToDefault()
                        }
                        .buttonStyle(OrttaaiButtonStyle(.secondary, size: .small))
                    }

                    Spacer()

                    Button {
                        refreshModelStorage()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(OrttaaiButtonStyle(.secondary, size: .small))
                    .help("Refresh model storage status")
                    .accessibilityLabel("Refresh model storage status")
                }
            }
            .padding(.bottom, Spacing.xs)
        }
    }

    private var modelStorageStatusLabel: some View {
        let tint = modelStorage.isAvailable && modelStorage.isWritable
            ? Color.Orttaai.success
            : (modelStorage.isAvailable ? Color.Orttaai.warning : Color.Orttaai.error)

        return StatusChip(
            title: modelStorage.isCustom ? "Custom folder" : "Default folder",
            systemImage: modelStorage.isAvailable ? "checkmark.circle.fill" : "exclamationmark.triangle.fill",
            tint: tint
        )
    }

    private func chooseModelStorageLocation() {
        guard let url = ModelStorageFolderPicker.chooseFolder(
            startingAt: modelStorage.isAvailable ? modelStorage.url : nil
        ) else { return }

        do {
            try ModelStorageLocation.setCustomLocation(url)
            modelStorageError = nil
            refreshModelStorage()
        } catch {
            modelStorageError = error.localizedDescription
        }
    }

    private func revealModelStorageLocation() {
        Task {
            do {
                let access = try await ModelDirectoryLocator.shared.beginAccess(
                    createIfNeeded: true,
                    requiresWrite: false
                )
                NSWorkspace.shared.activateFileViewerSelecting([access.url])
            } catch {
                modelStorageError = error.localizedDescription
            }
        }
    }

    private func refreshModelStorage() {
        modelStorageError = nil
        Task {
            modelStorage = await ModelDirectoryLocator.shared.storageSnapshot()
            await refreshDownloadedMetrics()
        }
    }

    private var performanceCard: some View {
        SettingsCard("Performance", info: "Changes apply from your next dictation.") {
            SettingsToggleRow(
                title: "Low Latency Mode",
                info: "Optimizes for the fastest result. Accuracy may drop slightly on difficult audio, and the dictation language can't be Auto-detect.",
                isOn: $lowLatencyModeEnabled
            )

            SettingsDivider()

            SettingsRow(
                title: "Compute Mode",
                info: "Which chips run the speech model. CPU + Neural Engine is usually fastest on Apple silicon. Applies after the model reloads."
            ) {
                OrttaaiDropdown(
                    selection: $computeMode,
                    options: [
                        .init("cpuAndNeuralEngine", "CPU + Neural Engine"),
                        .init("cpuAndGPU", "CPU + GPU"),
                        .init("cpuOnly", "CPU Only")
                    ],
                    width: SettingsLayout.controlWidth
                )
            }

            SettingsDivider()

            SettingsRow(
                title: "Decoding Profile",
                info: DecodingPreset.allCases
                    .map { "\($0.title): \($0.summary)" }
                    .joined(separator: "\n")
            ) {
                OrttaaiSegmentedControl(
                    title: "Decoding Profile",
                    selection: $decodingPresetRaw,
                    options: DecodingPreset.allCases.map { .init($0.rawValue, $0.title) }
                )
            }

            SettingsDivider()

            SettingsToggleRow(
                title: "Advanced Decoding",
                info: "Replaces the decoding profile with manual Whisper settings. Leave it off unless you are tuning accuracy.",
                isOn: $advancedDecodingEnabled
            )
            .accessibilityIdentifier("advancedDecodingToggle")

            if advancedDecodingEnabled {
                SettingsFootnote("\(decodingPreset.title) stays selected, but its values are paused while Advanced Decoding is on.")
                advancedDecodingControls
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(.easeInOut(duration: 0.18), value: advancedDecodingEnabled)
    }

    private var advancedDecodingControls: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSliderRow(
                title: "Temperature",
                info: "Higher values increase randomness. Lower is more deterministic.",
                value: $decodingTemperature,
                range: 0...1,
                step: 0.05,
                valueText: String(format: "%.2f", decodingTemperature)
            )

            SettingsStepperRow(
                title: "Top-K",
                info: "Limits the candidate tokens considered at each decode step.",
                value: $decodingTopK,
                range: 1...20
            )

            SettingsStepperRow(
                title: "Fallback Count",
                info: "Retry attempts when decode confidence is low.",
                value: $decodingFallbackCount,
                range: 0...10
            )

            SettingsSliderRow(
                title: "No-Speech Threshold",
                info: "Higher values make silence detection stricter.",
                value: $decodingNoSpeechThreshold,
                range: 0...1,
                step: 0.05,
                valueText: String(format: "%.2f", decodingNoSpeechThreshold)
            )

            SettingsSliderRow(
                title: "Log-Prob Threshold",
                info: "Minimum token confidence before a fallback triggers.",
                value: $decodingLogProbThreshold,
                range: -3.0...0.0,
                step: 0.1,
                valueText: String(format: "%.1f", decodingLogProbThreshold)
            )

            SettingsSliderRow(
                title: "Compression Threshold",
                info: "Detects repetitive output. Lower values can trigger more fallbacks.",
                value: $decodingCompressionRatioThreshold,
                range: 1.5...4.0,
                step: 0.1,
                valueText: String(format: "%.1f", decodingCompressionRatioThreshold)
            )

            SettingsStepperRow(
                title: "Worker Count",
                info: "Parallel decode workers. Auto uses model-aware defaults.",
                value: $decodingWorkerCount,
                range: 0...8,
                format: { $0 == 0 ? "Auto" : "\($0)" }
            )
        }
        .padding(.leading, Spacing.md)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(Color.Orttaai.border)
                .frame(width: 1)
        }
        .padding(.bottom, Spacing.xs)
    }

    // MARK: - AI Features tab

    private var providerBinding: Binding<LocalLLMProviderKind> {
        Binding(
            get: { providerKind },
            set: { newKind in
                localLLMProviderRaw = newKind.rawValue
                if newKind.isLocal {
                    // Remembered so on-device features (polish, embeddings)
                    // keep a local provider while a cloud one is active.
                    lastLocalLLMProviderRaw = newKind.rawValue
                }
                ollamaStatusReachable = nil
                ollamaStatusMessage = newKind.isLocal
                    ? "Check connection to validate local model availability."
                    : "Check connection to validate CLI sign-in and cloud models."
                installedOllamaModels = []
                Task { await checkOllamaAvailability() }
            }
        )
    }

    /// One line: provider, its model (or the local server address), and a
    /// connection check that turns green when ready. Rows below appear only
    /// when the provider needs something: consent, sign-in, or a fix.
    private var providerCard: some View {
        SettingsCard(
            "AI Provider",
            info: "Where AI features run. Ollama and LM Studio run models on this Mac; LM Studio manages its own downloads. ChatGPT and Grok use your signed-in account in the cloud."
        ) {
            HStack(spacing: Spacing.sm) {
                OrttaaiDropdown(
                    selection: providerBinding,
                    options: LocalLLMProviderKind.allCases.map { .init($0, $0.displayName) },
                    width: 150
                )

                providerDetailControl

                ConnectionCheckButton(
                    isChecking: isCheckingOllama,
                    isReady: ollamaStatusReachable,
                    message: ollamaStatusMessage
                ) {
                    Task { await checkOllamaAvailability() }
                }
                .disabled(isInstallingOllamaModel || isLoadingOllamaCatalog)
            }
        } content: {
            switch providerKind {
            case .codex:
                CodexProviderRows {
                    Task { await checkOllamaAvailability() }
                }
            case .grok:
                GrokProviderRows(
                    isReady: ollamaStatusReachable,
                    statusMessage: ollamaStatusMessage
                ) {
                    Task { await checkOllamaAvailability() }
                }
            default:
                localProviderRows
            }
        }
        .onChange(of: installedOllamaModels) { _, _ in
            normalizeCloudModelSelection()
        }
    }

    /// The model for a cloud provider, or the server address for a local one
    /// (local models are chosen per feature in the cards below).
    @ViewBuilder
    private var providerDetailControl: some View {
        switch providerKind {
        case .codex:
            OrttaaiDropdown(
                selection: $codexModel,
                options: cloudModelOptions(current: codexModel),
                width: 190
            )
        case .grok:
            OrttaaiDropdown(
                selection: $grokModel,
                options: cloudModelOptions(current: grokModel),
                width: 190
            )
        default:
            OrttaaiTextField(
                placeholder: providerKind.defaultEndpoint,
                text: activeLLMEndpointBinding
            )
            .frame(width: 190)
            .id(providerKind)
            .help("\(providerKind.displayName) server address")
        }
    }

    private func cloudModelOptions(current: String) -> [OrttaaiDropdown<String>.Option] {
        var names = installedOllamaModels
        if !current.isEmpty, !names.contains(current) {
            names.insert(current, at: 0)
        }
        return names.map { .init($0, $0) }
    }

    /// Keeps a cloud model selection on a model the account actually offers.
    private func normalizeCloudModelSelection() {
        guard let first = installedOllamaModels.first else { return }
        switch providerKind {
        case .grok where !installedOllamaModels.contains(grokModel):
            grokModel = first
        case .codex where codexModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty:
            codexModel = first
        default:
            break
        }
    }

    @ViewBuilder
    private var localProviderRows: some View {
        if ollamaStatusReachable == false {
            SettingsNotice(kind: .error, message: ollamaStatusMessage)
        }

        SettingsRow(
            title: "Warm Models",
            info: "Loads the enabled models into memory so the first polish after launch is fast."
        ) {
            HStack(spacing: Spacing.sm) {
                if let ollamaWarmStatusMessage, isWarmingOllamaModels {
                    ProgressView().controlSize(.small)
                    Text(ollamaWarmStatusMessage)
                        .font(.Orttaai.caption)
                        .foregroundStyle(Color.Orttaai.textSecondary)
                        .lineLimit(1)
                }

                Button {
                    Task {
                        if ollamaStatusReachable != true {
                            await checkOllamaAvailability()
                        }
                        await warmEnabledOllamaModelsIfNeeded(silent: false)
                    }
                } label: {
                    Label(isWarmingOllamaModels ? "Warming…" : "Warm Now", systemImage: "bolt.fill")
                }
                .buttonStyle(OrttaaiButtonStyle(.secondary, size: .small))
                .disabled(
                    isCheckingOllama ||
                    isInstallingOllamaModel ||
                    isLoadingOllamaCatalog ||
                    isWarmingOllamaModels
                )
            }
        }

        if let ollamaWarmSuccessMessage {
            SettingsNotice(kind: .success, message: ollamaWarmSuccessMessage) {
                self.ollamaWarmSuccessMessage = nil
            }
        }

        if let ollamaWarmError {
            SettingsNotice(kind: .error, message: ollamaWarmError) {
                self.ollamaWarmError = nil
            }
        }
    }

    private var polishCard: some View {
        SettingsCard(
            "Text Polish",
            info: "Fixes grammar and punctuation in each dictation with a language model before it's inserted. Voice editing uses the same model."
        ) {
            if AppleIntelligencePolishProcessor.isModelAvailable {
                SettingsToggleRow(
                    title: "Apple Intelligence Polish",
                    info: "Polishes with Apple's on-device model.",
                    isOn: $appleIntelligencePolishEnabled
                )

                SettingsDivider()
            }

            SettingsToggleRow(
                title: "Local Text Polish",
                info: "Polishes each dictation with the model below. If it doesn't answer within the timeout, the unpolished text is inserted.",
                isOn: $localLLMPolishEnabled
            )

            SettingsDivider()

            if providerKind.isLocal {
                SettingsRow(title: "Polish Model") {
                    OrttaaiDropdown(
                        selection: Binding(
                            get: { resolvedModelSelection(for: normalizedPolishOllamaModel) },
                            set: { localLLMPolishModel = $0 }
                        ),
                        options: modelDropdownOptions(current: normalizedPolishOllamaModel),
                        width: SettingsLayout.controlWidth
                    )
                }
            } else {
                SettingsRow(
                    title: "Polish Model",
                    info: "Polish always runs locally, on \(localFallbackProviderKind.displayName), even while a cloud provider is selected."
                ) {
                    Text(normalizedPolishOllamaModel)
                        .font(.Orttaai.mono)
                        .foregroundStyle(Color.Orttaai.textSecondary)
                }
            }

            SettingsDivider()

            SettingsSliderRow(
                title: "Polish Timeout",
                info: "How long to wait for polish before inserting the unpolished text.",
                value: Binding(
                    get: { Double(localLLMPolishTimeoutMs) },
                    set: { localLLMPolishTimeoutMs = Int($0) }
                ),
                range: 80...4_000,
                step: 10,
                valueText: "\(localLLMPolishTimeoutMs) ms"
            )

            SettingsDivider()

            SettingsStepperRow(
                title: "Max Characters",
                info: "Longer dictations skip polish to stay responsive.",
                value: $localLLMPolishMaxChars,
                range: 80...2_000,
                step: 20
            )

            SettingsFootnote(polishRecommendationMessage)
        }
    }

    private var insightsCard: some View {
        SettingsCard(
            "Writing Insights",
            info: providerKind.isLocal
                ? "Uses local LLM analysis to surface speaking and writing patterns."
                : "Uses your signed-in \(providerKind.displayName) account to surface speaking and writing patterns."
        ) {
            OrttaaiSwitch(title: "Writing Insights", isOn: $localLLMInsightsEnabled)
        } content: {
            if localLLMInsightsEnabled {
                if providerKind.isLocal {
                    SettingsRow(title: "Insights Model") {
                        OrttaaiDropdown(
                            selection: Binding(
                                get: { resolvedModelSelection(for: normalizedInsightsOllamaModel) },
                                set: { localLLMInsightsModel = $0 }
                            ),
                            options: modelDropdownOptions(current: normalizedInsightsOllamaModel),
                            width: SettingsLayout.controlWidth
                        )
                    }

                    SettingsDivider()

                    SettingsStepperRow(
                        title: "Context Window",
                        info: "How much of your history the model reads at once. Larger windows need more memory.",
                        value: $localLLMInsightsContextTokens,
                        range: 8_192...262_144,
                        step: 8_192,
                        format: { "\($0 / 1_024)K tokens" }
                    )

                    SettingsDivider()

                    SettingsToggleRow(
                        title: "Thinking",
                        info: "Lets the model reason step by step for deeper analysis. Slower, and uses more tokens.",
                        isOn: $localLLMInsightsThinkingEnabled
                    )

                    SettingsFootnote(insightsRecommendationMessage)
                } else {
                    SettingsFootnote(
                        providerKind == .codex
                            ? "Writing insights and graph interpretation use \u{201C}\(codexModel)\u{201D} through your ChatGPT subscription. Change the model and reasoning effort under AI Provider."
                            : "Writing insights and graph interpretation use \u{201C}\(grokModel)\u{201D} through your Grok CLI account. Change the model under AI Provider."
                    )
                }
            }
        }
    }

    private var semanticMemoryCard: some View {
        SettingsCard(
            "Semantic Memory",
            info: "Indexes your dictations by meaning so ChatAI and Memory can find related notes, not only exact words."
        ) {
            OrttaaiSwitch(title: "Semantic Memory", isOn: $semanticMemoryEnabled)
        } content: {
            if semanticMemoryEnabled {
                if providerKind.supportsEmbeddings {
                    SettingsRow(
                        title: "Embedding Model",
                        info: "Changing the model rebuilds the index."
                    ) {
                        OrttaaiDropdown(
                            selection: Binding(
                                get: { resolvedModelSelection(for: normalizedSemanticEmbeddingModel) },
                                set: { newValue in
                                    semanticEmbeddingModel = newValue
                                    semanticActiveIndexModelID = ""
                                }
                            ),
                            options: modelDropdownOptions(current: normalizedSemanticEmbeddingModel),
                            width: SettingsLayout.controlWidth
                        )
                    }
                } else {
                    SettingsRow(
                        title: "Embedding Model",
                        info: "Embeddings always run locally, on \(localFallbackProviderKind.displayName), even while a cloud provider is selected."
                    ) {
                        Text(normalizedSemanticEmbeddingModel)
                            .font(.Orttaai.mono)
                            .foregroundStyle(Color.Orttaai.textSecondary)
                    }
                }

                SettingsDivider()

                SettingsToggleRow(
                    title: "Auto-index for ChatAI",
                    info: "Indexes new dictations in the background so ChatAI can use them right away.",
                    isOn: $semanticMemoryAutoIndexEnabled
                )

                SettingsDivider()

                SettingsToggleRow(
                    title: "Keyword Fallback",
                    info: "Falls back to keyword search when the embedding model isn't available.",
                    isOn: $semanticEmbeddingFallbackEnabled
                )
            }
        }
    }

    private var modelDownloadsCard: some View {
        SettingsCard(
            "Model Downloads",
            info: "Curated lightweight models from \(providerKind.displayName). Installing one also selects it for that feature."
        ) {
            if isLoadingOllamaCatalog {
                HStack(spacing: Spacing.xs) {
                    ProgressView().controlSize(.small)
                    Text("Loading curated models…")
                        .font(.Orttaai.caption)
                        .foregroundStyle(Color.Orttaai.textSecondary)
                }
                .padding(.bottom, Spacing.xs)
            } else if !downloadableOllamaModels.isEmpty {
                downloadRow(
                    title: "Polish",
                    selection: $selectedPolishDownloadModel,
                    model: normalizedSelectedPolishDownloadModel,
                    canInstall: canInstallPolishModel
                ) { model in
                    localLLMPolishModel = model
                }

                SettingsDivider()

                downloadRow(
                    title: "Insights",
                    selection: $selectedInsightsDownloadModel,
                    model: normalizedSelectedInsightsDownloadModel,
                    canInstall: canInstallInsightsModel
                ) { model in
                    localLLMInsightsModel = model
                }

                SettingsDivider()

                downloadRow(
                    title: "Semantic",
                    selection: $selectedSemanticDownloadModel,
                    model: normalizedSelectedSemanticDownloadModel,
                    canInstall: canInstallSemanticModel
                ) { model in
                    semanticEmbeddingModel = model
                    semanticActiveIndexModelID = ""
                }
            } else {
                SettingsFootnote(ollamaCatalogMessage)
            }

            if let ollamaInstallStatusMessage {
                if let ollamaInstallProgress {
                    ProgressView(value: ollamaInstallProgress) {
                        Text(ollamaInstallStatusMessage)
                            .font(.Orttaai.caption)
                            .foregroundStyle(Color.Orttaai.textSecondary)
                    }
                    .tint(Color.Orttaai.accent)
                    .padding(.vertical, Spacing.xs)
                } else {
                    HStack(spacing: Spacing.xs) {
                        if isInstallingOllamaModel {
                            ProgressView().controlSize(.small)
                        }
                        Text(ollamaInstallStatusMessage)
                            .font(.Orttaai.caption)
                            .foregroundStyle(Color.Orttaai.textSecondary)
                    }
                    .padding(.vertical, Spacing.xs)
                }
            }

            if let ollamaInstallSuccessMessage {
                SettingsNotice(kind: .success, message: ollamaInstallSuccessMessage) {
                    self.ollamaInstallSuccessMessage = nil
                }
            }

            if let ollamaInstallError {
                SettingsNotice(kind: .error, message: ollamaInstallError) {
                    self.ollamaInstallError = nil
                }
            }
        }
    }

    /// One curated-download row: pick a model, install it, and select it for
    /// the feature once the download finishes.
    private func downloadRow(
        title: String,
        selection: Binding<String>,
        model: String,
        canInstall: Bool,
        onInstalled: @escaping (String) -> Void
    ) -> some View {
        SettingsRow(title: title) {
            HStack(spacing: Spacing.sm) {
                OrttaaiDropdown(
                    selection: selection,
                    options: downloadableOllamaModels.map { .init($0.name, ollamaCatalogLabel(for: $0)) },
                    width: 260
                )

                Button {
                    Task {
                        await installOllamaModel(named: model)
                        await MainActor.run { onInstalled(model) }
                    }
                } label: {
                    if isInstallingOllamaModel && installingOllamaModelName == model {
                        Label("Installing…", systemImage: "arrow.down.circle")
                    } else if isOllamaModelInstalled(model) {
                        Label("Installed", systemImage: "checkmark.circle")
                    } else {
                        Label("Install", systemImage: "arrow.down.circle")
                    }
                }
                .buttonStyle(OrttaaiButtonStyle(.secondary, size: .small))
                .frame(minWidth: 96, alignment: .leading)
                .disabled(
                    !canInstall ||
                    isCheckingOllama ||
                    isLoadingOllamaCatalog ||
                    isInstallingOllamaModel ||
                    isOllamaModelInstalled(model)
                )
            }
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
                        modelBadgeCluster(for: selectedModel, precision: resolvedRow(for: selectedModel).precision)
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
        // Size follows the loaded/downloaded variant, never the curated alias.
        let sizeText = ModelSizeFormatter.text(for: resolvedRow(for: model))
        return "\(sizeText) • \(model.speedLabel.rawValue) • \(model.accuracyLabel.rawValue) accuracy"
    }

    // MARK: - Model Row

    private func compactModelRow(_ model: ModelInfo) -> some View {
        let modelID = ModelManager.canonicalModelListID(model.id)
        let selectedID = ModelManager.canonicalModelListID(selectedModelId)
        let resolved = resolvedRow(for: model)
        let isSelected = modelID == selectedID
        let isDownloaded = resolved.isDownloaded
        let isUnsupported = !model.isDeviceSupported
        let storageBlocksDownload = !isDownloaded && (!modelStorage.isAvailable || !modelStorage.isWritable)
        let isThisSwitching = switchingModelId == model.id && isSwitching
        let isMigratingThisFamily = migratingFamilyID == modelID
        let switchingStatusText = isDownloaded ? "Loading + warm-up..." : "Downloading + warm-up..."

        return VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack(spacing: Spacing.sm) {
            Button {
                guard !isUnsupported, !isSwitching, !isDeletingModel, migratingFamilyID == nil else { return }
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

                    // Measured on-disk size for downloaded builds; the exact
                    // selected variant's estimate for models not on this Mac.
                    Text(ModelSizeFormatter.text(for: resolved))
                        .font(.Orttaai.secondary)
                        .foregroundStyle(Color.Orttaai.textSecondary)
                        .lineLimit(1)

                    modelBadgeCluster(for: model, precision: resolved.precision)

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
            .disabled(isUnsupported || storageBlocksDownload || isSwitching || isDeletingModel || migratingFamilyID != nil)
            .help(storageBlocksDownload ? "Choose an available, writable model folder before downloading." : "")

            if isDownloaded && !isSelected {
                Button {
                    deleteError = nil
                    pendingDeleteModel = model
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(OrttaaiButtonStyle(.secondary, destructive: true, size: .small))
                .help("Remove this model's downloaded files")
                .accessibilityLabel("Remove downloaded files for \(model.name)")
                .disabled(isSwitching || isDeletingModel || migratingFamilyID != nil)
            }
            }

            if let offer = resolved.migrationOffer {
                QuantizedMigrationOfferView(
                    offer: offer,
                    isMigrating: isMigratingThisFamily,
                    isDisabled: isSwitching || isDeletingModel
                        || !modelStorage.isAvailable || !modelStorage.isWritable
                        || (migratingFamilyID != nil && !isMigratingThisFamily),
                    onMigrate: { startQuantizedMigration(offer) },
                    onDismiss: { dismissMigrationOffer(offer) }
                )
                .padding(.leading, Spacing.lg)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Variant Truth & Quantized Migration

    /// Resolves what this family row must show so it never contradicts the
    /// disk or the loaded model: loaded variant first, then the downloaded
    /// build with its measured size, then the exact download estimate.
    private func resolvedRow(for model: ModelInfo) -> ResolvedModelRow {
        ModelVariantResolver.resolveRow(
            family: model,
            downloadedVariants: downloadedVariants,
            activeModelID: activeModelId.isEmpty ? nil : activeModelId,
            dismissedMigrationFamilies: QuantizedMigrationDismissals.parse(dismissedMigrationFamiliesRaw)
        )
    }

    private func startQuantizedMigration(_ offer: QuantizedMigrationOffer) {
        guard let manager = ModelManager.shared else {
            migrationError = "Model manager unavailable."
            return
        }

        migrationError = nil
        migrationSuccessMessage = nil
        migratingFamilyID = offer.familyID
        let previousActiveModelID = activeModelId

        Task {
            defer { migratingFamilyID = nil }
            let migrator = QuantizedMigrator(
                operations: ModelManagerQuantizedMigrationOperations(manager: manager)
            )
            do {
                try await migrator.migrate(offer: offer, previousActiveModelID: previousActiveModelID)
                if ModelManager.canonicalModelListID(selectedModelId) == offer.familyID {
                    selectedModelId = offer.quantizedVariantID
                }
                let reclaimed = ModelSizeFormatter.text(forBytes: offer.estimatedReclaimedBytes)
                migrationSuccessMessage = "Switched to \(ModelManager.formatDisplayName(offer.quantizedVariantID)). Reclaimed ~\(reclaimed)."
            } catch {
                migrationError = error.localizedDescription
            }
            await refreshDownloadedMetrics()
        }
    }

    private func dismissMigrationOffer(_ offer: QuantizedMigrationOffer) {
        dismissedMigrationFamiliesRaw = QuantizedMigrationDismissals.adding(
            offer.familyID,
            to: dismissedMigrationFamiliesRaw
        )
    }

    private func switchToModel(_ model: ModelInfo) {
        let targetModelID = TranscriptionModelSelectionPolicy.resolvedModelID(
            selectedModelID: model.id,
            dictationLanguage: dictationLanguage
        )
        guard let manager = ModelManager.shared else {
            // ModelManager not initialized yet — fall back to just setting the preference
            selectedModelId = targetModelID
            activeModelId = ""
            return
        }

        switchError = nil
        isSwitching = true
        switchingModelId = targetModelID

        Task {
            do {
                try await manager.switchModel(toModelId: targetModelID)
                selectedModelId = targetModelID
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

    private func switchToLanguageOptimizedSmallModelIfNeeded() {
        let targetModelID = TranscriptionModelSelectionPolicy.resolvedModelID(
            selectedModelID: selectedModelId,
            dictationLanguage: dictationLanguage
        )
        guard targetModelID != selectedModelId else { return }

        guard let manager = ModelManager.shared else {
            selectedModelId = targetModelID
            activeModelId = ""
            return
        }

        switchError = nil
        isSwitching = true
        switchingModelId = targetModelID
        Task {
            do {
                try await manager.switchModel(toModelId: targetModelID)
                selectedModelId = targetModelID
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
                try await manager.deleteModel(named: model.id)
                await refreshDownloadedMetrics()
            } catch {
                deleteError = error.localizedDescription
            }
        }
    }

    @ViewBuilder
    private func modelBadgeCluster(for model: ModelInfo, precision: ModelVariantPrecision? = nil) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Spacing.xs) {
                compatibilityBadge(for: model)
                languageBadge(for: model)
                if let precision {
                    ModelPrecisionChip(precision: precision)
                }
            }

            HStack(spacing: Spacing.xs) {
                compatibilityBadge(for: model, compact: true)
                languageBadge(for: model, compact: true)
                if let precision {
                    ModelPrecisionChip(precision: precision, compact: true)
                }
            }

            compatibilityDot(for: model)
        }
    }

    /// English-only and Multilingual chips are mutually exclusive by
    /// construction: one call, one boolean, one chip.
    private func languageBadge(for model: ModelInfo, compact: Bool = false) -> some View {
        badge(
            compact
                ? ModelVariantResolver.compactLanguageBadgeTitle(isEnglishOnly: model.isEnglishOnly)
                : ModelVariantResolver.languageBadgeTitle(isEnglishOnly: model.isEnglishOnly),
            color: Color.Orttaai.textTertiary,
            compact: compact
        )
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

        localLLMPolishModel = sanitizeLocalLLMModel(localLLMPolishModel, fallback: "gemma4:e2b")
        localLLMInsightsModel = sanitizeLocalLLMModel(localLLMInsightsModel, fallback: "qwen3.5:0.8b")
        semanticEmbeddingModel = semanticEmbeddingModel.trimmingCharacters(in: .whitespacesAndNewlines)
        if semanticEmbeddingModel.isEmpty {
            semanticEmbeddingModel = "all-minilm"
        }
        semanticActiveIndexModelID = semanticActiveIndexModelID.trimmingCharacters(in: .whitespacesAndNewlines)

        // Migrate old defaults (220ms pre-1.5, 650ms pre-polish-default-on)
        // which are too short for real local generation latency.
        if localLLMPolishTimeoutMs == 220 || localLLMPolishTimeoutMs == 650 {
            localLLMPolishTimeoutMs = 3_000
        }
        localLLMPolishTimeoutMs = max(80, min(4_000, localLLMPolishTimeoutMs))
        // Migrate the old 280-char default so polish covers longer dictation.
        if localLLMPolishMaxChars == 280 {
            localLLMPolishMaxChars = 400
        }
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
        switch providerKind {
        case .ollama: return localLLMEndpoint
        case .lmStudio: return lmStudioEndpoint
        case .codex, .grok: return "" // Spawned subprocess; no HTTP endpoint.
        }
    }

    private var activeLLMEndpointBinding: Binding<String> {
        providerKind == .ollama ? $localLLMEndpoint : $lmStudioEndpoint
    }

    /// Local provider that keeps serving on-device features (polish,
    /// embeddings) while a cloud provider is selected.
    private var localFallbackProviderKind: LocalLLMProviderKind {
        if providerKind.isLocal { return providerKind }
        let stored = LocalLLMProviderKind(rawValue: lastLocalLLMProviderRaw) ?? .ollama
        return stored.isLocal ? stored : .ollama
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

    private func loadInitialModels() {
        // Start with hardcoded fallback, then fetch dynamically
        models = sortedModelsForCurrentMode(hardcodedFallbackModels())
        Task { modelStorage = await ModelDirectoryLocator.shared.storageSnapshot() }
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
        let (metrics, isComplete) = await ModelDirectoryLocator.shared.metrics()

        let summary: String
        if metrics.downloadedModelIDs.isEmpty {
            summary = isComplete ? "No models downloaded" : "Model folder unavailable"
        } else {
            let formatter = ByteCountFormatter()
            formatter.allowedUnits = [.useMB, .useGB]
            formatter.countStyle = .file
            let modelCount = metrics.downloadedModelIDs.count
            let sizeText = formatter.string(fromByteCount: metrics.totalBytes)
            summary = "\(modelCount) model\(modelCount == 1 ? "" : "s") downloaded • \(sizeText)"
                + (isComplete ? "" : " • some folders unavailable")
        }

        await MainActor.run {
            downloadedModelIDs = metrics.downloadedModelIDs
            downloadedVariants = metrics.variants
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
            "openai_whisper-large-v3-v20240930",
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
        var name = ModelManager.formatDisplayName(id)
        // ModelManager keeps ".en" tokens intact; render them as a suffix here.
        name = name.replacingOccurrences(of: ".en", with: " (English)", options: [.caseInsensitive])
        while name.contains("  ") { name = name.replacingOccurrences(of: "  ", with: " ") }
        return name.trimmingCharacters(in: .whitespaces)
    }

    private func estimateSize(_ id: String) -> Int {
        ModelManager.estimateSize(id)
    }

    private func descriptionFor(_ id: String) -> String {
        let lowered = id.lowercased()
        if lowered.contains("tiny") { return "Quick notes, commands" }
        if lowered.contains("base") { return "Short dictation" }
        if lowered.contains("small") { return "General dictation" }
        if lowered.contains("medium") { return "Longer dictation" }
        if ModelManager.isTurboFamily(lowered) { return "Maximum accuracy, optimized speed" }
        if lowered.contains("large") { return "Highest accuracy, slowest" }
        return "WhisperKit model"
    }

    private func tierFor(_ id: String) -> HardwareTier {
        let lowered = id.lowercased()
        if lowered.contains("tiny") || lowered.contains("base") || lowered.contains("small") {
            return .m1_8gb
        }
        if lowered.contains("medium") || ModelManager.isTurboFamily(lowered) {
            return .m1_16gb
        }
        return .m3_16gb
    }

    private func speedLabelFor(_ id: String) -> SpeedLabel {
        let lowered = id.lowercased()
        if lowered.contains("tiny") { return .fastest }
        if lowered.contains("base") || lowered.contains("small") { return .fast }
        if lowered.contains("medium") || ModelManager.isTurboFamily(lowered) { return .moderate }
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
        let lowered = ModelManager.normalizedModelID(id.lowercased())
        return lowered.hasSuffix(".en") || lowered.hasSuffix("-en") || lowered.hasSuffix("_en")
    }

    private func isRecommended(_ id: String) -> Bool {
        let hardware = HardwareDetector.detect()
        return ModelManager.canonicalModelListID(id) == ModelManager.canonicalModelListID(hardware.recommendedModel)
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
