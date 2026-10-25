// S1MiniPolishRow.swift
// Orttaai

import SwiftUI

/// Settings > Model > AI Features > Text Polish, when S1-mini is the engine:
/// its download, whether it's loaded, and the credit its licence asks for.
struct S1MiniPolishRow: View {
    let controller: S1MiniPolishController

    private static let downloadSizeText = ByteCountFormatter.string(
        fromByteCount: ExpressModelStore.s1Mini.totalBytes,
        countStyle: .file
    )

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            SettingsRow(
                title: "S1-mini",
                info: "A 0.6B model trained only to clean up dictation: it removes fillers, resolves self-corrections, punctuates and writes lists, without rewriting what you said. Downloaded once, \(Self.downloadSizeText)."
            ) {
                accessory
            }

            if case .downloading(let progress) = controller.status {
                ProgressView(value: progress) {
                    Text("Downloading S1-mini… \(Int(progress * 100))%")
                        .font(.Orttaai.caption)
                        .foregroundStyle(Color.Orttaai.textSecondary)
                }
                .tint(Color.Orttaai.accent)
            }

            if case .failed(let message) = controller.status {
                SettingsNotice(kind: .error, message: "S1-mini couldn't start: \(message)")
            }

            SettingsFootnote("S1-mini by Superwhisper (Apache 2.0), built on Qwen3 0.6B. It runs inside Orttaai on this Mac.")
        }
        .task {
            await controller.refresh()
        }
    }

    @ViewBuilder
    private var accessory: some View {
        switch controller.status {
        case .checking:
            ProgressView().controlSize(.small)
        case .notInstalled, .failed:
            Button("Download \(Self.downloadSizeText)") {
                Task { await controller.install() }
            }
            .buttonStyle(OrttaaiButtonStyle(.primary, size: .small))
        case .downloading(let progress):
            Text("\(Int(progress * 100))%")
                .font(.Orttaai.caption)
                .monospacedDigit()
                .foregroundStyle(Color.Orttaai.textSecondary)
        case .loading:
            Text("Loading…")
                .font(.Orttaai.caption)
                .foregroundStyle(Color.Orttaai.textSecondary)
        case .installed:
            Text("Downloaded")
                .font(.Orttaai.caption)
                .foregroundStyle(Color.Orttaai.textSecondary)
        case .ready:
            Label("Ready", systemImage: "checkmark.circle.fill")
                .font(.Orttaai.caption)
                .foregroundStyle(Color.Orttaai.success)
        }
    }
}
