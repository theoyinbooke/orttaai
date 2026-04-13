// DownloadStepView.swift
// Orttaai

import SwiftUI
import os

enum QuickStartModelSelector {
    static func modelId(for dictationLanguage: String) -> String {
        let language = dictationLanguage
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if language == "en" || language.hasPrefix("en-") {
            return "openai_whisper-small.en"
        }
        return "openai_whisper-small"
    }
}

enum SetupDownloadedModelResolver {
    static func resolveInstalledModelID(
        downloadedModelIDs: Set<String>,
        selectedModelID: String,
        preferredModelIDs: [String]
    ) -> String? {
        let normalizedSelected = ModelManager.normalizedModelID(selectedModelID)
        if !normalizedSelected.isEmpty, downloadedModelIDs.contains(normalizedSelected) {
            return selectedModelID
        }

        for modelID in preferredModelIDs {
            let normalized = ModelManager.normalizedModelID(modelID)
            if !normalized.isEmpty, downloadedModelIDs.contains(normalized) {
                return modelID
            }
        }

        return nil
    }
}

private enum SetupDownloadStage {
    case downloading
    case loading
    case warmingUp

    var title: String {
        switch self {
        case .downloading:
            return "Downloading model files..."
        case .loading:
            return "Loading model..."
        case .warmingUp:
            return "Warming up model..."
        }
    }

    var detail: String {
        switch self {
        case .downloading:
            return "First-time download can take a few minutes."
        case .loading:
            return "Preparing Core ML components."
        case .warmingUp:
            return "Running a quick warm-up for faster first dictation."
        }
    }
}

struct DownloadStepView: View {
    @Binding var isModelReady: Bool
    @AppStorage("dictationLanguage") private var dictationLanguage: String = "en"
    @AppStorage("selectedModelId") private var selectedModelId: String = "openai_whisper-small"
    @State private var isDownloading = false
    @State private var installedModelId: String?
    @State private var downloadedModelIDs = Set<String>()
    @State private var errorMessage: String?
    @State private var downloadProgress: Double = 0
    @State private var downloadStage: SetupDownloadStage = .downloading
    @State private var downloadingModelId: String?
    @State private var transcriptionService = TranscriptionService()

    private let hardwareInfo = HardwareDetector.detect()

    private var quickStartModelId: String {
        QuickStartModelSelector.modelId(for: dictationLanguage)
    }

    private var quickStartModelSummary: String {
        quickStartModelId == "openai_whisper-small.en"
            ? "English-optimized model that keeps first-run dictation responsive without dropping too much accuracy."
            : "Multilingual model that balances first-run speed and accuracy."
    }

    private var recommendedModelId: String {
        hardwareInfo.recommendedModel
    }

    private var recommendedModelSummary: String {
        "Best match for your Mac if you want to prioritize recognition quality over first-run download time."
    }

    private var showsSeparateRecommendedCard: Bool {
        ModelManager.normalizedModelID(recommendedModelId) != ModelManager.normalizedModelID(quickStartModelId)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            Text("Download Model")
                .font(.Orttaai.title)
                .foregroundStyle(Color.Orttaai.textPrimary)

            // Hardware info card
            VStack(alignment: .leading, spacing: Spacing.sm) {
                Text("Your Hardware")
                    .font(.Orttaai.subheading)
                    .foregroundStyle(Color.Orttaai.textPrimary)

                HStack(spacing: Spacing.xl) {
                    Label(hardwareInfo.chipName, systemImage: "cpu")
                    Label("\(hardwareInfo.ramGB)GB RAM", systemImage: "memorychip")
                }
                .font(.Orttaai.secondary)
                .foregroundStyle(Color.Orttaai.textSecondary)
            }
            .padding(Spacing.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.Orttaai.bgSecondary)
            .clipShape(RoundedRectangle(cornerRadius: CornerRadius.card))

            modelCard(
                title: "Quick Start Model",
                badge: "Faster setup",
                modelId: quickStartModelId,
                summary: quickStartModelSummary,
                footnote: "Smaller download. Best if you want the fastest first dictation.",
                accentColor: .Orttaai.accent
            )

            if showsSeparateRecommendedCard {
                modelCard(
                    title: "Recommended for Your Mac",
                    badge: "Higher accuracy",
                    modelId: recommendedModelId,
                    summary: recommendedModelSummary,
                    footnote: "Larger download. Good if you want to start with the best fit for this Mac.",
                    accentColor: .Orttaai.textPrimary
                )
            }

            if isDownloading {
                VStack(alignment: .leading, spacing: Spacing.sm) {
                    ProgressView(value: max(0, min(downloadProgress, 1)), total: 1)
                        .controlSize(.small)
                        .tint(Color.Orttaai.accent)

                    HStack {
                        Text(downloadStage.title)
                            .font(.Orttaai.secondary)
                            .foregroundStyle(Color.Orttaai.textSecondary)
                        Spacer()
                        Text("\(Int((max(0, min(downloadProgress, 1)) * 100).rounded()))%")
                            .font(.Orttaai.mono)
                            .foregroundStyle(Color.Orttaai.accent)
                    }

                    Text(downloadStage.detail)
                        .font(.Orttaai.secondary)
                        .foregroundStyle(Color.Orttaai.textTertiary)

                    if let downloadingModelId {
                        Text("Downloading: \(downloadingModelId)")
                            .font(.Orttaai.caption)
                            .foregroundStyle(Color.Orttaai.textTertiary)
                    }
                }
            } else if let installedModelId {
                HStack(spacing: Spacing.sm) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color.Orttaai.success)
                    Text("\(installedModelId) downloaded and ready")
                        .font(.Orttaai.body)
                        .foregroundStyle(Color.Orttaai.success)
                }
            } else if let error = errorMessage {
                VStack(alignment: .leading, spacing: Spacing.sm) {
                    Text(error)
                        .font(.Orttaai.body)
                        .foregroundStyle(Color.Orttaai.error)
                }
            }
        }
        .onAppear {
            refreshInstalledModelState()
        }
        .onChange(of: dictationLanguage) { _, _ in
            refreshInstalledModelState()
        }
    }

    @ViewBuilder
    private func modelCard(
        title: String,
        badge: String,
        modelId: String,
        summary: String,
        footnote: String,
        accentColor: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            HStack(alignment: .top, spacing: Spacing.md) {
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text(title)
                        .font(.Orttaai.subheading)
                        .foregroundStyle(Color.Orttaai.textPrimary)

                    Text(badge)
                        .font(.Orttaai.caption)
                        .foregroundStyle(accentColor)
                }

                Spacer()

                Button(actionTitle(for: modelId)) {
                    startDownload(modelId: modelId)
                }
                .buttonStyle(OrttaaiButtonStyle(isSelectedForSetup(modelId) ? .secondary : .primary))
                .disabled(isDownloading || isSelectedForSetup(modelId))
            }

            Text(modelId)
                .font(.Orttaai.mono)
                .foregroundStyle(accentColor)

            Text(summary)
                .font(.Orttaai.secondary)
                .foregroundStyle(Color.Orttaai.textSecondary)

            Text(footnote)
                .font(.Orttaai.caption)
                .foregroundStyle(Color.Orttaai.textTertiary)

            if isSelectedForSetup(modelId) {
                Label("Selected for setup", systemImage: "checkmark.circle.fill")
                    .font(.Orttaai.caption)
                    .foregroundStyle(Color.Orttaai.success)
            } else if isDownloaded(modelId) {
                Label("Downloaded locally", systemImage: "externaldrive.fill.badge.checkmark")
                    .font(.Orttaai.caption)
                    .foregroundStyle(Color.Orttaai.textSecondary)
            }
        }
        .padding(Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.Orttaai.bgSecondary)
        .clipShape(RoundedRectangle(cornerRadius: CornerRadius.card))
    }

    private func actionTitle(for modelId: String) -> String {
        if isSelectedForSetup(modelId) {
            return "Ready"
        }
        if isDownloading && downloadingModelId == modelId {
            return "Downloading..."
        }
        if isDownloaded(modelId) {
            return "Use Downloaded"
        }
        if installedModelId != nil {
            return "Download Instead"
        }
        return "Download"
    }

    private func isSelectedForSetup(_ modelId: String) -> Bool {
        ModelManager.normalizedModelID(installedModelId ?? "") == ModelManager.normalizedModelID(modelId)
    }

    private func isDownloaded(_ modelId: String) -> Bool {
        downloadedModelIDs.contains(ModelManager.normalizedModelID(modelId))
    }

    private func startDownload(modelId: String) {
        guard !modelId.isEmpty else {
            errorMessage = "Orttaai requires an Apple Silicon Mac."
            isModelReady = false
            return
        }

        isDownloading = true
        downloadingModelId = modelId
        errorMessage = nil
        isModelReady = false
        downloadProgress = 0
        downloadStage = .downloading

        Task {
            do {
                let settings = AppSettings()
                await settings.syncTranscriptionSettings(to: transcriptionService)
                let modelAlreadyDownloaded = ModelManager
                    .detectDownloadedModelMetrics()
                    .downloadedModelIDs
                    .contains(ModelManager.normalizedModelID(modelId))

                if modelAlreadyDownloaded {
                    await MainActor.run {
                        downloadStage = .loading
                        downloadProgress = 1
                    }
                    try await transcriptionService.loadModel(named: modelId)
                } else {
                    try await transcriptionService.prepareModelForSetup(
                        named: modelId,
                        onProgress: { progress in
                            Task { @MainActor in
                                downloadProgress = max(downloadProgress, progress)
                                downloadStage = .downloading
                            }
                        },
                        onStageChange: { stage in
                            Task { @MainActor in
                                switch stage {
                                case .downloading:
                                    downloadStage = .downloading
                                case .loading:
                                    downloadStage = .loading
                                    downloadProgress = 1
                                }
                            }
                        }
                    )
                }

                await MainActor.run {
                    downloadStage = .warmingUp
                    downloadProgress = 1
                }
                await transcriptionService.warmUp()
                await MainActor.run {
                    settings.selectedModelId = modelId
                    settings.activeModelId = modelId
                    configureFastFirstOnboarding(settings: settings, quickModelId: modelId)
                    refreshInstalledModelState(selectedModelID: modelId)
                    isDownloading = false
                    downloadingModelId = nil
                    isModelReady = true
                }
            } catch {
                await MainActor.run {
                    isDownloading = false
                    downloadingModelId = nil
                    isModelReady = false
                    downloadProgress = 0
                    downloadStage = .downloading
                    errorMessage = "Couldn't download model. Check your connection and try again."
                    Logger.model.error("Setup model download failed: \(error.localizedDescription)")
                }
            }
        }
    }

    private func configureFastFirstOnboarding(settings: AppSettings, quickModelId: String) {
        let recommendedModelId = ModelManager.normalizedModelID(
            hardwareInfo.recommendedModel.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        let normalizedQuickModelId = ModelManager.normalizedModelID(quickModelId)
        let shouldEnableFastFirst = !recommendedModelId.isEmpty && recommendedModelId != normalizedQuickModelId

        settings.fastFirstOnboardingEnabled = shouldEnableFastFirst
        settings.fastFirstRecommendedModelId = shouldEnableFastFirst ? recommendedModelId : ""
        settings.fastFirstPrefetchStarted = false
        settings.fastFirstPrefetchReady = false
        settings.fastFirstUpgradeDismissed = false
        settings.fastFirstPrefetchErrorMessage = ""
    }

    private func refreshInstalledModelState(selectedModelID: String? = nil) {
        let metrics = ModelManager.detectDownloadedModelMetrics()
        downloadedModelIDs = metrics.downloadedModelIDs

        let resolvedModelID = SetupDownloadedModelResolver.resolveInstalledModelID(
            downloadedModelIDs: metrics.downloadedModelIDs,
            selectedModelID: selectedModelID ?? selectedModelId,
            preferredModelIDs: [quickStartModelId, recommendedModelId]
        )

        installedModelId = resolvedModelID
        isModelReady = resolvedModelID != nil

        if resolvedModelID != nil {
            errorMessage = nil
        }
    }
}
