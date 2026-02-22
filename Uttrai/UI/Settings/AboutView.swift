// AboutView.swift
// Uttrai

import SwiftUI

struct AboutView: View {
    private let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
    private let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
    private let isHomebrew = Bundle.main.isHomebrewInstall

    var body: some View {
        VStack(spacing: Spacing.xl) {
            // App icon placeholder
            Image(systemName: "waveform.circle.fill")
                .font(.system(size: 64))
                .foregroundStyle(Color.Uttrai.accent)

            Text("Uttrai")
                .font(.Uttrai.title)
                .foregroundStyle(Color.Uttrai.textPrimary)

            Text("Version \(version) (\(build))")
                .font(.Uttrai.secondary)
                .foregroundStyle(Color.Uttrai.textSecondary)

            Text("Native macOS voice keyboard")
                .font(.Uttrai.body)
                .foregroundStyle(Color.Uttrai.textSecondary)

            Divider()
                .background(Color.Uttrai.border)

            if isHomebrew {
                VStack(spacing: Spacing.xs) {
                    Text("Installed via Homebrew")
                        .font(.Uttrai.bodyMedium)
                        .foregroundStyle(Color.Uttrai.textPrimary)
                    Text("Updates managed by Homebrew. Run:")
                        .font(.Uttrai.secondary)
                        .foregroundStyle(Color.Uttrai.textSecondary)
                    Text("brew upgrade uttrai")
                        .font(.Uttrai.mono)
                        .foregroundStyle(Color.Uttrai.accent)
                }
            }

            Divider()
                .background(Color.Uttrai.border)

            // Acknowledgments
            VStack(alignment: .leading, spacing: Spacing.sm) {
                Text("Acknowledgments")
                    .font(.Uttrai.subheading)
                    .foregroundStyle(Color.Uttrai.textPrimary)

                VStack(alignment: .leading, spacing: Spacing.xs) {
                    acknowledgmentRow("WhisperKit", "On-device speech recognition")
                    acknowledgmentRow("GRDB.swift", "SQLite database toolkit")
                    acknowledgmentRow("Sparkle", "Auto-update framework")
                    acknowledgmentRow("KeyboardShortcuts", "Shortcut recording")
                }
            }

            Text("MIT License")
                .font(.Uttrai.caption)
                .foregroundStyle(Color.Uttrai.textTertiary)

            Spacer()
        }
        .padding(Spacing.xxl)
    }

    private func acknowledgmentRow(_ name: String, _ description: String) -> some View {
        HStack {
            Text(name)
                .font(.Uttrai.bodyMedium)
                .foregroundStyle(Color.Uttrai.textPrimary)
            Text("—")
                .foregroundStyle(Color.Uttrai.textTertiary)
            Text(description)
                .font(.Uttrai.secondary)
                .foregroundStyle(Color.Uttrai.textSecondary)
        }
    }
}
