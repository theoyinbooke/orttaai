// ModelSettingsView.swift
// Uttrai

import SwiftUI

struct ModelSettingsView: View {
    @AppStorage("selectedModelId") private var selectedModelId = "openai_whisper-large-v3_turbo"
    @State private var downloadProgress: Double?
    @State private var diskUsage: String = "Calculating..."

    private let availableModels: [ModelInfo] = [
        ModelInfo(
            id: "openai_whisper-large-v3_turbo",
            name: "Whisper Large V3 Turbo",
            downloadSizeMB: 950,
            description: "Best accuracy, recommended for 16GB+ RAM",
            minimumTier: .m1_16gb
        ),
        ModelInfo(
            id: "openai_whisper-small",
            name: "Whisper Small",
            downloadSizeMB: 300,
            description: "Good accuracy, works on 8GB RAM",
            minimumTier: .m1_8gb
        ),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xl) {
            Text("Model")
                .font(.Uttrai.heading)
                .foregroundStyle(Color.Uttrai.textPrimary)

            // Current model info
            VStack(alignment: .leading, spacing: Spacing.sm) {
                Text("Current Model")
                    .font(.Uttrai.subheading)
                    .foregroundStyle(Color.Uttrai.textPrimary)

                Text(selectedModelId)
                    .font(.Uttrai.mono)
                    .foregroundStyle(Color.Uttrai.accent)

                Text(diskUsage)
                    .font(.Uttrai.caption)
                    .foregroundStyle(Color.Uttrai.textTertiary)
            }
            .padding(Spacing.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.Uttrai.bgSecondary)
            .clipShape(RoundedRectangle(cornerRadius: CornerRadius.card))

            // Available models
            Text("Available Models")
                .font(.Uttrai.subheading)
                .foregroundStyle(Color.Uttrai.textPrimary)

            ForEach(availableModels) { model in
                modelRow(model)
            }

            Spacer()
        }
        .padding(Spacing.xxl)
        .onAppear {
            calculateDiskUsage()
        }
    }

    private func modelRow(_ model: ModelInfo) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text(model.name)
                    .font(.Uttrai.bodyMedium)
                    .foregroundStyle(Color.Uttrai.textPrimary)

                Text("\(model.downloadSizeMB)MB — \(model.description)")
                    .font(.Uttrai.secondary)
                    .foregroundStyle(Color.Uttrai.textSecondary)
            }

            Spacer()

            if model.id == selectedModelId {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Color.Uttrai.success)
            } else {
                Button("Switch") {
                    selectedModelId = model.id
                }
                .buttonStyle(UttraiButtonStyle(.secondary))
            }
        }
        .padding(Spacing.lg)
        .background(Color.Uttrai.bgSecondary)
        .clipShape(RoundedRectangle(cornerRadius: CornerRadius.card))
    }

    private func calculateDiskUsage() {
        let modelsDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Uttrai/Models")

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
}
