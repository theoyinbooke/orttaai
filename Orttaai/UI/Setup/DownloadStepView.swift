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
    @State private var modelStorage = ModelStorageLocation.placeholderSnapshot()
    @State private var modelStorageError: String?

    private let hardwareInfo = HardwareDetector.detect()

    private var quickStartModelId: String {
        QuickStartModelSelector.modelId(for: dictationLanguage)
    }

    private var quickStartModelSummary: String {
        ModelManager.normalizedModelID(quickStartModelId) == "openai_whisper-small.en"
            ? "Fast English model."
            : "Fast multilingual model."
    }

    private var recommendedModelId: String {
        hardwareInfo.recommendedModel
    }

    private var recommendedModelSummary: String {
        "Best accuracy for this Mac."
    }

    private var showsSeparateRecommendedCard: Bool {
        ModelManager.normalizedModelID(recommendedModelId) != ModelManager.normalizedModelID(quickStartModelId)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            Text("Download Model")
                .font(.Orttaai.title)
                .foregroundStyle(Color.Orttaai.textPrimary)

            // Hardware info card
            VStack(alignment: .leading, spacing: Spacing.sm) {
                Text("Your Hardware")
                    .font(.Orttaai.subheading)
                    .foregroundStyle(Color.Orttaai.textPrimary)

                HStack(spacing: Spacing.md) {
                    Label(hardwareInfo.chipName, systemImage: "cpu")
                    Label("\(hardwareInfo.ramGB)GB RAM", systemImage: "memorychip")
                }
                .font(.Orttaai.secondary)
                .foregroundStyle(Color.Orttaai.textSecondary)
            }
            .padding(Spacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.Orttaai.bgSecondary)
            .clipShape(RoundedRectangle(cornerRadius: CornerRadius.card))

            setupModelStorageCard

            modelCard(
                title: "Quick Start Model",
                badge: "Faster setup",
                modelId: quickStartModelId,
                detail: quickStartModelSummary,
                accentColor: .Orttaai.accent
            )

            if showsSeparateRecommendedCard {
                modelCard(
                    title: "Recommended for Your Mac",
                    badge: "Higher accuracy",
                    modelId: recommendedModelId,
                    detail: recommendedModelSummary,
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
                        Text("\(downloadStage.modelStatusPrefix): \(downloadingModelId)")
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
        .onReceive(NotificationCenter.default.publisher(for: ModelStorageLocation.didChangeNotification)) { _ in
            refreshModelStorage()
        }
    }

    private var setupModelStorageCard: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            HStack(alignment: .top, spacing: Spacing.md) {
                Image(systemName: modelStorage.isCustom ? "externaldrive" : "internaldrive")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(modelStorage.isAvailable ? Color.Orttaai.accent : Color.Orttaai.error)
                    .frame(width: 32, height: 32)
                    .background(Color.Orttaai.accentSubtle)
                    .clipShape(RoundedRectangle(cornerRadius: CornerRadius.input, style: .continuous))

                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text("Model Storage")
                        .font(.Orttaai.subheading)
                        .foregroundStyle(Color.Orttaai.textPrimary)

                    Text(modelStorage.url.path)
                        .font(.Orttaai.mono)
                        .foregroundStyle(Color.Orttaai.textSecondary)
                        .lineLimit(2)
                        .truncationMode(.middle)

                }

                Spacer(minLength: Spacing.sm)

                Button("Choose Folder") {
                    chooseModelStorageLocation()
                }
                .buttonStyle(OrttaaiButtonStyle(.secondary))
                .disabled(isDownloading)
            }

            if modelStorage.isCustom {
                Button("Use Default Location") {
                    ModelStorageLocation.resetToDefault()
                }
                .buttonStyle(.plain)
                .font(.Orttaai.caption)
                .foregroundStyle(Color.Orttaai.accent)
                .disabled(isDownloading)
            }

            if !modelStorage.isAvailable || !modelStorage.isWritable {
                Text(modelStorage.isAvailable
                     ? "Choose a writable folder before downloading."
                     : "Reconnect the drive or choose another folder before downloading.")
                    .font(.Orttaai.caption)
                    .foregroundStyle(Color.Orttaai.error)
            }

            if let modelStorageError {
                Text(modelStorageError)
                    .font(.Orttaai.caption)
                    .foregroundStyle(Color.Orttaai.error)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.Orttaai.bgSecondary)
        .clipShape(RoundedRectangle(cornerRadius: CornerRadius.card))
    }

    @ViewBuilder
    private func modelCard(
        title: String,
        badge: String,
        modelId: String,
        detail: String,
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
                .disabled(
                    isDownloading
                        || isSelectedForSetup(modelId)
                        || (!isDownloaded(modelId) && (!modelStorage.isAvailable || !modelStorage.isWritable))
                )
            }

            Text(modelId)
                .font(.Orttaai.mono)
                .foregroundStyle(accentColor)

            Text(detail)
                .font(.Orttaai.secondary)
                .foregroundStyle(Color.Orttaai.textSecondary)

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
        .padding(Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.Orttaai.bgSecondary)
        .clipShape(RoundedRectangle(cornerRadius: CornerRadius.card))
    }

    private func actionTitle(for modelId: String) -> String {
        if isSelectedForSetup(modelId) {
            return "Ready"
        }
        if isDownloading && downloadingModelId == modelId {
            return downloadStage.actionTitle
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
            let modelAlreadyDownloaded = await ModelDirectoryLocator.shared.inventory()
                .downloadedModelIDs
                .contains(ModelManager.normalizedModelID(modelId))
            if modelAlreadyDownloaded {
                downloadProgress = 1
                downloadStage = .loading
            }

            do {
                let settings = AppSettings()
                await settings.syncTranscriptionSettings(to: transcriptionService)

                if modelAlreadyDownloaded {
                    await MainActor.run {
                        downloadStage = .loading
                        downloadProgress = 1
                    }
                    try await transcriptionService.loadModel(named: modelId, allowDownload: true)
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
                    if error is ModelStorageLocationError || error is ModelLoadError {
                        errorMessage = error.localizedDescription
                    } else {
                        errorMessage = modelAlreadyDownloaded
                            ? "Couldn't load downloaded model. Try again or choose another model."
                            : "Couldn't download model. Check your connection and try again."
                    }
                    Logger.model.error("Setup model prepare failed: \(error.localizedDescription)")
                }
            }
        }
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

    private func refreshModelStorage() {
        modelStorageError = nil
        refreshInstalledModelState()
        Task {
            modelStorage = await ModelDirectoryLocator.shared.storageSnapshot()
        }
    }

    private func configureFastFirstOnboarding(settings: AppSettings, quickModelId: String) {
        // Store the exact variant id — normalization strips quantized size
        // suffixes and would make the later prefetch fetch the full model.
        let recommendedModelId = hardwareInfo.recommendedModel.trimmingCharacters(in: .whitespacesAndNewlines)
        let shouldEnableFastFirst = !recommendedModelId.isEmpty
            && ModelManager.normalizedModelID(recommendedModelId) != ModelManager.normalizedModelID(quickModelId)

        settings.fastFirstOnboardingEnabled = shouldEnableFastFirst
        settings.fastFirstRecommendedModelId = shouldEnableFastFirst ? recommendedModelId : ""
        settings.fastFirstPrefetchStarted = false
        settings.fastFirstPrefetchReady = false
        settings.fastFirstUpgradeDismissed = false
        settings.fastFirstPrefetchErrorMessage = ""
    }

    private func refreshInstalledModelState(selectedModelID: String? = nil) {
        Task {
            let modelIDs = await ModelDirectoryLocator.shared.inventory().downloadedModelIDs
            // A refresh that outlived the start of a download must not reset it.
            guard !isDownloading else { return }
            downloadedModelIDs = modelIDs

            let resolvedModelID = SetupDownloadedModelResolver.resolveInstalledModelID(
                downloadedModelIDs: modelIDs,
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
}

private extension SetupDownloadStage {
    var actionTitle: String {
        switch self {
        case .downloading:
            return "Downloading..."
        case .loading, .warmingUp:
            return "Loading..."
        }
    }

    var modelStatusPrefix: String {
        switch self {
        case .downloading:
            return "Downloading"
        case .loading, .warmingUp:
            return "Loading"
        }
    }
}
