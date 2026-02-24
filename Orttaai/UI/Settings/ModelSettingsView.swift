// ModelSettingsView.swift
// Orttaai

import SwiftUI

struct ModelSettingsView: View {
    @AppStorage("selectedModelId") private var selectedModelId = "openai_whisper-large-v3_turbo"
    @State private var diskUsage: String = "Calculating..."
    @State private var models: [ModelInfo] = []
    @State private var isFetching: Bool = false
    @State private var isPickerExpanded: Bool = false
    @State private var isSwitching: Bool = false
    @State private var switchingModelId: String?
    @State private var switchError: String?

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
            calculateDiskUsage()
            loadInitialModels()
        }
    }

    private var selectedModel: ModelInfo? {
        models.first(where: { $0.id == selectedModelId })
    }

    private var displayNameForCurrentModel: String {
        selectedModel?.name ?? selectedModelId
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
        let isSelected = model.id == selectedModelId
        let isUnsupported = !model.isDeviceSupported
        let isThisSwitching = switchingModelId == model.id && isSwitching

        return Button {
            guard !isUnsupported, !isSwitching else { return }
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
                        .foregroundStyle(isSelected ? Color.Orttaai.success : Color.Orttaai.textTertiary)
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
                    Text("Downloading...")
                        .font(.Orttaai.caption)
                        .foregroundStyle(Color.Orttaai.accent)
                } else if isSelected {
                    Text("Current")
                        .font(.Orttaai.caption)
                        .foregroundStyle(Color.Orttaai.success)
                }
            }
            .padding(.horizontal, Spacing.sm)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: CornerRadius.input, style: .continuous)
                    .fill(isSelected ? Color.Orttaai.successSubtle : Color.Orttaai.bgPrimary.opacity(0.36))
            )
            .overlay(
                RoundedRectangle(cornerRadius: CornerRadius.input, style: .continuous)
                    .stroke(isSelected ? Color.Orttaai.success.opacity(0.35) : Color.Orttaai.border, lineWidth: BorderWidth.standard)
            )
            .opacity(isUnsupported ? 0.62 : 1.0)
        }
        .buttonStyle(.plain)
        .disabled(isUnsupported || isSwitching)
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
            } catch {
                switchError = error.localizedDescription
            }
            isSwitching = false
            switchingModelId = nil
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
            badge(compact ? "OK" : "Supported", color: Color.Orttaai.success, compact: compact)
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
        if model.isDeviceSupported { return Color.Orttaai.success }
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

    private func loadInitialModels() {
        // Start with hardcoded fallback, then fetch dynamically
        let deviceSupport = hardcodedFallbackModels()
        models = deviceSupport
        Task { await fetchModels() }
    }

    private func fetchModels() async {
        isFetching = true
        defer { isFetching = false }

        // Use ModelManager.shared to fetch the real model list from WhisperKit
        if let manager = ModelManager.shared {
            await manager.fetchModels()
            if !manager.availableModels.isEmpty {
                models = manager.availableModels
                return
            }
        }

        // Fallback: build list from hardcoded model IDs
        var fetched = hardcodedModelIds().compactMap { name -> ModelInfo? in
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

        fetched.sort { a, b in
            if a.isDeviceRecommended != b.isDeviceRecommended {
                return a.isDeviceRecommended
            }
            if a.isDeviceSupported != b.isDeviceSupported {
                return a.isDeviceSupported
            }
            return a.downloadSizeMB < b.downloadSizeMB
        }

        models = fetched
    }

    // MARK: - Disk Usage

    private func calculateDiskUsage() {
        let modelsDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Orttaai/Models")

        do {
            let contents = try FileManager.default.contentsOfDirectory(at: modelsDir, includingPropertiesForKeys: [.fileSizeKey])
            let totalSize = contents.reduce(0) { sum, url in
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                return sum + size
            }
            let mb = totalSize / (1024 * 1024)
            diskUsage = "Disk usage: \(mb)MB"
        } catch {
            diskUsage = "No models downloaded"
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
