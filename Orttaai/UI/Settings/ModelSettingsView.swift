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
    @AppStorage("selectedModelId") private var selectedModelId = "openai_whisper-large-v3_turbo"
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
        let switchingStatusText = isDownloaded ? "Switching..." : "Downloading..."

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
