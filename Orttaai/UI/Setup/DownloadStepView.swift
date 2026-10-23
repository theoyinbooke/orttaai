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
    @AppStorage("expressEngineEnabled") private var expressEngineEnabled = false
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

    /// Detected once per launch (it takes ~17 ms); SetupView starts it in
    /// the background so the Engine step never waits for it.
    static let hardwareInfo = HardwareDetector.detect()
    private var hardwareInfo: HardwareInfo { Self.hardwareInfo }
    /// Express installs and loads through the same controller as Settings.
    private let express = ExpressEngine.isSupported ? ModelManager.shared?.express : nil

    private var quickStartModelId: String {
        QuickStartModelSelector.modelId(for: dictationLanguage)
    }

    private var quickStartModelSummary: String {
        ModelManager.normalizedModelID(quickStartModelId) == "openai_whisper-small.en"
            ? "OpenAI's Whisper, tuned for English. A dependable alternative."
            : "OpenAI's Whisper. Works in many languages."
    }

    /// Express can be chosen: supported on this Mac and the dictation
    /// language is English.
    private var isExpressAvailable: Bool {
        express != nil && expressSupportsLanguage
    }

    private var expressSupportsLanguage: Bool {
        ExpressEngine.supportsLanguage(dictationLanguage)
    }

    private var isExpressSelected: Bool {
        express?.status == .active && expressEngineEnabled
    }

    private var isExpressBusy: Bool {
        express?.isBusy ?? false
    }

    private var isAnyDownloadRunning: Bool {
        isDownloading || isExpressBusy
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            // Express first and recommended; Whisper Small is the
            // alternative, and the recommendation when Express can't be used.
            if let express {
                expressCard(express)
            }

            modelCard(
                title: "Whisper Small",
                badge: isExpressAvailable ? nil : "Recommended",
                modelId: quickStartModelId,
                detail: quickStartModelSummary,
                accentColor: .Orttaai.accent
            )

            if let express, isExpressBusy {
                expressProgress(express)
            } else if isDownloading {
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
            } else if case .failed(let message) = express?.status {
                Text("Express couldn't start: \(message)")
                    .font(.Orttaai.body)
                    .foregroundStyle(Color.Orttaai.error)
            } else if let error = errorMessage {
                VStack(alignment: .leading, spacing: Spacing.sm) {
                    Text(error)
                        .font(.Orttaai.body)
                        .foregroundStyle(Color.Orttaai.error)
                }
            }

            setupModelStorageCard
                .padding(.top, Spacing.xs)
        }
        .onAppear {
            refreshInstalledModelState()
        }
        .task {
            await express?.refresh()
        }
        .onChange(of: express?.status) { _, status in
            if status == .active, expressEngineEnabled {
                configureFastFirstOnboarding(settings: AppSettings())
                isModelReady = true
            } else if installedModelId == nil {
                isModelReady = false
            }
        }
        .onChange(of: dictationLanguage) { _, _ in
            refreshInstalledModelState()
        }
        .onReceive(NotificationCenter.default.publisher(for: ModelStorageLocation.didChangeNotification)) { _ in
            refreshModelStorage()
        }
    }

    /// This Mac: where models go, and the chip and memory they run on.
    private var setupModelStorageCard: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            HStack(alignment: .center, spacing: Spacing.md) {
                Image(systemName: modelStorage.isCustom ? "externaldrive" : "internaldrive")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(modelStorage.isAvailable ? Color.Orttaai.textSecondary : Color.Orttaai.error)
                    .frame(width: 34, height: 34)
                    .background(Color.Orttaai.bgTertiary, in: RoundedRectangle(cornerRadius: 9, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    Text(modelStorage.url.path)
                        .font(.Orttaai.mono)
                        .foregroundStyle(Color.Orttaai.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    HStack(spacing: Spacing.md) {
                        Label(hardwareInfo.chipName, systemImage: "cpu")
                        Label("\(hardwareInfo.ramGB) GB memory", systemImage: "memorychip")
                    }
                    .font(.Orttaai.caption)
                    .foregroundStyle(Color.Orttaai.textTertiary)
                }

                Spacer(minLength: Spacing.sm)

                Button("Change…") {
                    chooseModelStorageLocation()
                }
                .buttonStyle(OrttaaiButtonStyle(.ghost, size: .small))
                .disabled(isDownloading)
                .help("Where Orttaai keeps speech models")
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
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.Orttaai.bgSecondary.opacity(0.6), in: RoundedRectangle(cornerRadius: CornerRadius.card, style: .continuous))
    }

    private func modelCard(
        title: String,
        badge: String?,
        modelId: String,
        detail: String,
        accentColor: Color
    ) -> some View {
        engineCard(
            icon: "waveform",
            title: title,
            badge: badge,
            subtitle: modelId,
            detail: detail,
            isSelected: isSelectedForSetup(modelId),
            actionTitle: actionTitle(for: modelId),
            isActionDisabled: isAnyDownloadRunning
                || isSelectedForSetup(modelId)
                || (!isDownloaded(modelId) && (!modelStorage.isAvailable || !modelStorage.isWritable))
        ) {
            startDownload(modelId: modelId)
        }
    }

    /// Express: the compact English engine, offered as experimental. Choosing
    /// it downloads Fluid Speech Mini and the Word Boost model, loads them and
    /// turns Express on; the Whisper model stays the fallback.
    private func expressCard(_ express: ExpressController) -> some View {
        engineCard(
            icon: "bolt.fill",
            title: "Express",
            badge: expressSupportsLanguage ? "Recommended" : nil,
            subtitle: "\(ExpressEngine.displayName) + Word Boost",
            detail: expressSupportsLanguage
                ? "Fastest dictation, best with names. English only, \(Self.expressDownloadSize)."
                : "English only. Set dictation to English to use it.",
            isSelected: isExpressSelected,
            actionTitle: expressActionTitle(express),
            isActionDisabled: isAnyDownloadRunning
                || isExpressSelected
                || !expressSupportsLanguage
                || (!modelStorage.isAvailable || !modelStorage.isWritable)
        ) {
            express.setEnabled(true)
        }
    }

    /// One engine choice: icon, name and badge, what it is, and its action;
    /// the chosen one glows.
    private func engineCard(
        icon: String,
        title: String,
        badge: String?,
        subtitle: String,
        detail: String,
        isSelected: Bool,
        actionTitle: String,
        isActionDisabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        let tint = isSelected ? Color.Orttaai.success : Color.Orttaai.accent
        return HStack(alignment: .top, spacing: Spacing.md) {
            Image(systemName: isSelected ? "checkmark" : icon)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 42, height: 42)
                .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                .contentTransition(.symbolEffect(.replace))

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: Spacing.sm) {
                    Text(title)
                        .font(.Orttaai.subheading)
                        .foregroundStyle(Color.Orttaai.textPrimary)
                    if let badge {
                        Text(badge)
                            .font(.Orttaai.caption)
                            .foregroundStyle(Color.Orttaai.accent)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Color.Orttaai.accentSubtle, in: Capsule())
                    }
                }
                Text(subtitle)
                    .font(.Orttaai.mono)
                    .foregroundStyle(Color.Orttaai.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(detail)
                    .font(.Orttaai.secondary)
                    .foregroundStyle(Color.Orttaai.textSecondary)
                    .lineLimit(1)
                    .help(detail)
            }

            Spacer(minLength: Spacing.sm)

            Button(actionTitle, action: action)
                .buttonStyle(OrttaaiButtonStyle(isSelected ? .secondary : .primary, size: .small))
                .disabled(isActionDisabled)
        }
        .padding(Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            isSelected ? Color.Orttaai.success.opacity(0.06) : Color.Orttaai.bgSecondary,
            in: RoundedRectangle(cornerRadius: CornerRadius.card, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: CornerRadius.card, style: .continuous)
                .stroke(isSelected ? Color.Orttaai.success.opacity(0.45) : Color.Orttaai.border.opacity(0.6), lineWidth: isSelected ? 1.5 : BorderWidth.standard)
        )
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: isSelected)
    }

    private static let expressDownloadSize = ByteCountFormatter.string(
        fromByteCount: ExpressModelStore.totalBytes,
        countStyle: .file
    )

    private func expressActionTitle(_ express: ExpressController) -> String {
        switch express.status {
        case .active where isExpressSelected: return "Ready"
        case .downloading: return "Downloading..."
        case .loading, .checking: return "Loading..."
        case .installed: return "Use Downloaded"
        default: return installedModelId != nil ? "Download Instead" : "Download"
        }
    }

    @ViewBuilder
    private func expressProgress(_ express: ExpressController) -> some View {
        let progress: Double = {
            if case .downloading(let fraction) = express.status { return fraction }
            return 1
        }()
        let isDownloadingExpress: Bool = {
            if case .downloading = express.status { return true }
            return false
        }()
        VStack(alignment: .leading, spacing: Spacing.sm) {
            ProgressView(value: max(0, min(progress, 1)), total: 1)
                .controlSize(.small)
                .tint(Color.Orttaai.accent)

            HStack {
                Text(isDownloadingExpress ? "Downloading Express models..." : "Preparing Express...")
                    .font(.Orttaai.secondary)
                    .foregroundStyle(Color.Orttaai.textSecondary)
                Spacer()
                Text("\(Int((max(0, min(progress, 1)) * 100).rounded()))%")
                    .font(.Orttaai.mono)
                    .foregroundStyle(Color.Orttaai.accent)
            }

            Text(isDownloadingExpress
                 ? "The speech model and the Word Boost model."
                 : "Preparing for the Neural Engine. The first time takes about 10 seconds.")
                .font(.Orttaai.secondary)
                .foregroundStyle(Color.Orttaai.textTertiary)
        }
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

    /// While Express is chosen, the Whisper model is only its fallback.
    private func isSelectedForSetup(_ modelId: String) -> Bool {
        !isExpressSelected
            && ModelManager.normalizedModelID(installedModelId ?? "") == ModelManager.normalizedModelID(modelId)
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
        if expressEngineEnabled {
            express?.setEnabled(false)
        }
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
                    configureFastFirstOnboarding(settings: settings)
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

    /// Setup no longer offers the large model, so it doesn't start the
    /// background download of it either; it stays a choice on the Model page.
    private func configureFastFirstOnboarding(settings: AppSettings) {
        settings.fastFirstOnboardingEnabled = false
        settings.fastFirstRecommendedModelId = ""
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
                preferredModelIDs: [quickStartModelId]
            )

            installedModelId = resolvedModelID
            isModelReady = resolvedModelID != nil || isExpressSelected

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
