// DownloadStepView.swift
// Uttrai

import SwiftUI

struct DownloadStepView: View {
    @State private var isDownloading = false
    @State private var progress: Double = 0
    @State private var downloadComplete = false
    @State private var errorMessage: String?

    private let hardwareInfo = HardwareDetector.detect()

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            Text("Download Model")
                .font(.Uttrai.title)
                .foregroundStyle(Color.Uttrai.textPrimary)

            // Hardware info card
            VStack(alignment: .leading, spacing: Spacing.sm) {
                Text("Your Hardware")
                    .font(.Uttrai.subheading)
                    .foregroundStyle(Color.Uttrai.textPrimary)

                HStack(spacing: Spacing.xl) {
                    Label(hardwareInfo.chipName, systemImage: "cpu")
                    Label("\(hardwareInfo.ramGB)GB RAM", systemImage: "memorychip")
                }
                .font(.Uttrai.secondary)
                .foregroundStyle(Color.Uttrai.textSecondary)
            }
            .padding(Spacing.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.Uttrai.bgSecondary)
            .clipShape(RoundedRectangle(cornerRadius: CornerRadius.card))

            // Recommended model
            VStack(alignment: .leading, spacing: Spacing.sm) {
                Text("Recommended Model")
                    .font(.Uttrai.subheading)
                    .foregroundStyle(Color.Uttrai.textPrimary)

                Text(hardwareInfo.recommendedModel)
                    .font(.Uttrai.mono)
                    .foregroundStyle(Color.Uttrai.accent)

                Text("This model provides the best balance of speed and accuracy for your hardware.")
                    .font(.Uttrai.secondary)
                    .foregroundStyle(Color.Uttrai.textSecondary)
            }
            .padding(Spacing.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.Uttrai.bgSecondary)
            .clipShape(RoundedRectangle(cornerRadius: CornerRadius.card))

            if isDownloading {
                VStack(alignment: .leading, spacing: Spacing.sm) {
                    ProgressView(value: progress, total: 1.0)
                        .progressViewStyle(UttraiProgressBarStyle())

                    Text("\(Int(progress * 100))% — Downloading model...")
                        .font(.Uttrai.secondary)
                        .foregroundStyle(Color.Uttrai.textSecondary)
                }
            } else if downloadComplete {
                HStack(spacing: Spacing.sm) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color.Uttrai.success)
                    Text("Model downloaded and verified")
                        .font(.Uttrai.body)
                        .foregroundStyle(Color.Uttrai.success)
                }
            } else if let error = errorMessage {
                VStack(alignment: .leading, spacing: Spacing.sm) {
                    Text(error)
                        .font(.Uttrai.body)
                        .foregroundStyle(Color.Uttrai.error)

                    Button("Retry") {
                        errorMessage = nil
                        startDownload()
                    }
                    .buttonStyle(UttraiButtonStyle(.primary))
                }
            } else {
                Button("Download Model") {
                    startDownload()
                }
                .buttonStyle(UttraiButtonStyle(.primary))
            }
        }
    }

    private func startDownload() {
        isDownloading = true
        progress = 0

        // Simulate download progress — in production, this connects to ModelManager
        Task {
            for i in 1...20 {
                try? await Task.sleep(nanoseconds: 200_000_000)
                await MainActor.run {
                    progress = Double(i) / 20.0
                }
            }
            await MainActor.run {
                isDownloading = false
                downloadComplete = true
            }
        }
    }
}
