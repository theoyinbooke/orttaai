// DownloadStepView.swift
// Orttaai

import SwiftUI
import os

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
    @State private var isDownloading = false
    @State private var downloadComplete = false
    @State private var errorMessage: String?
    @State private var downloadProgress: Double = 0
    @State private var downloadStage: SetupDownloadStage = .downloading
    @State private var transcriptionService = TranscriptionService()

    private let hardwareInfo = HardwareDetector.detect()

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

            // Recommended model
            VStack(alignment: .leading, spacing: Spacing.sm) {
                Text("Recommended Model")
                    .font(.Orttaai.subheading)
                    .foregroundStyle(Color.Orttaai.textPrimary)

                Text(hardwareInfo.recommendedModel)
                    .font(.Orttaai.mono)
                    .foregroundStyle(Color.Orttaai.accent)

                Text("This model provides the best balance of speed and accuracy for your hardware.")
                    .font(.Orttaai.secondary)
                    .foregroundStyle(Color.Orttaai.textSecondary)
            }
            .padding(Spacing.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.Orttaai.bgSecondary)
            .clipShape(RoundedRectangle(cornerRadius: CornerRadius.card))

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
                }
            } else if downloadComplete {
                HStack(spacing: Spacing.sm) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color.Orttaai.success)
                    Text("Model downloaded and ready")
                        .font(.Orttaai.body)
                        .foregroundStyle(Color.Orttaai.success)
                }
            } else if let error = errorMessage {
                VStack(alignment: .leading, spacing: Spacing.sm) {
                    Text(error)
                        .font(.Orttaai.body)
                        .foregroundStyle(Color.Orttaai.error)

                    Button("Retry") {
                        errorMessage = nil
                        startDownload()
                    }
                    .buttonStyle(OrttaaiButtonStyle(.primary))
                }
            } else {
                Button("Download Model") {
                    startDownload()
                }
                .buttonStyle(OrttaaiButtonStyle(.primary))
            }
        }
    }

    private func startDownload() {
        let modelId = hardwareInfo.recommendedModel
        guard !modelId.isEmpty else {
            errorMessage = "Orttaai requires an Apple Silicon Mac."
            isModelReady = false
            return
        }

        isDownloading = true
        downloadComplete = false
        errorMessage = nil
        isModelReady = false
        downloadProgress = 0
        downloadStage = .downloading

        Task {
            do {
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

                await MainActor.run {
                    downloadStage = .warmingUp
                    downloadProgress = 1
                }
                await transcriptionService.warmUp()
                await MainActor.run {
                    AppSettings().selectedModelId = modelId
                    isDownloading = false
                    downloadComplete = true
                    isModelReady = true
                }
            } catch {
                await MainActor.run {
                    isDownloading = false
                    downloadComplete = false
                    isModelReady = false
                    downloadProgress = 0
                    downloadStage = .downloading
                    errorMessage = "Couldn't download model. Check your connection and try again."
                    Logger.model.error("Setup model download failed: \(error.localizedDescription)")
                }
            }
        }
    }
}
