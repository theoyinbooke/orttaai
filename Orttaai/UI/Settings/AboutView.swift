// AboutView.swift
// Orttaai

import SwiftUI

struct AboutView: View {
    private let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
    private let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
    private let isHomebrew = Bundle.main.isHomebrewInstall
    private let emailURL = URL(string: "mailto:Oyinbookeola@outlook.com")!
    private let githubURL = URL(string: "https://github.com/theoyinbooke")!
    private let youtubeURL = URL(string: "https://youtube.com/c/theoyinbooke")!

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text("About")
                    .font(.Orttaai.heading)
                    .foregroundStyle(Color.Orttaai.textPrimary)

                Text("Build info and open-source components.")
                    .font(.Orttaai.secondary)
                    .foregroundStyle(Color.Orttaai.textSecondary)
            }

            HStack(spacing: Spacing.lg) {
                Image(systemName: "waveform.circle.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(Color.Orttaai.accent)
                    .frame(width: 64, height: 64)
                    .background(Color.Orttaai.accentSubtle)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text("Orttaai")
                        .font(.Orttaai.title)
                        .foregroundStyle(Color.Orttaai.textPrimary)

                    Text("Version \(version) (\(build))")
                        .font(.Orttaai.secondary)
                        .foregroundStyle(Color.Orttaai.textSecondary)

                    Text("Native macOS voice keyboard")
                        .font(.Orttaai.secondary)
                        .foregroundStyle(Color.Orttaai.textSecondary)
                }

                Spacer()
            }
            .padding(Spacing.lg)
            .dashboardCard()

            VStack(alignment: .leading, spacing: Spacing.md) {
                Text("Maintainer")
                    .font(.Orttaai.subheading)
                    .foregroundStyle(Color.Orttaai.textPrimary)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Spacing.md) {
                        maintainerCard(
                            title: "Author",
                            value: "Olanrewaju Oyinbooke",
                            systemImage: "person.fill"
                        )
                        maintainerCard(
                            title: "Email",
                            value: "Oyinbookeola@outlook.com",
                            systemImage: "envelope.fill",
                            destination: emailURL
                        )
                        maintainerCard(
                            title: "GitHub",
                            value: "github.com/theoyinbooke",
                            systemImage: "chevron.left.forwardslash.chevron.right",
                            destination: githubURL
                        )
                        maintainerCard(
                            title: "YouTube",
                            value: "youtube.com/c/theoyinbooke",
                            systemImage: "play.rectangle.fill",
                            destination: youtubeURL
                        )
                    }
                    .padding(.vertical, Spacing.xs)
                }
            }
            .padding(Spacing.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
            .dashboardCard()

            VStack(alignment: .leading, spacing: Spacing.sm) {
                Text("Open Source and Free")
                    .font(.Orttaai.subheading)
                    .foregroundStyle(Color.Orttaai.textPrimary)

                Text("Orttaai is built as a free community tool with no paywall. Local-first dictation and user trust come first.")
                    .font(.Orttaai.secondary)
                    .foregroundStyle(Color.Orttaai.textSecondary)

                Text("If this project helps you, consider starring the repo, sharing feedback, or contributing improvements.")
                    .font(.Orttaai.secondary)
                    .foregroundStyle(Color.Orttaai.textSecondary)

                Link(destination: githubURL) {
                    Label("Contribute on GitHub", systemImage: "arrow.up.right.square")
                        .font(.Orttaai.bodyMedium)
                }
                .buttonStyle(OrttaaiButtonStyle(.secondary))
                .padding(.top, Spacing.xs)
            }
            .padding(Spacing.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
            .dashboardCard()

            if isHomebrew {
                VStack(alignment: .leading, spacing: Spacing.sm) {
                    Label("Installed via Homebrew", systemImage: "shippingbox")
                        .font(.Orttaai.bodyMedium)
                        .foregroundStyle(Color.Orttaai.textPrimary)

                    Text("Updates are managed by Homebrew.")
                        .font(.Orttaai.secondary)
                        .foregroundStyle(Color.Orttaai.textSecondary)

                    Text("brew upgrade orttaai")
                        .font(.Orttaai.mono)
                        .foregroundStyle(Color.Orttaai.accent)
                }
                .padding(Spacing.lg)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.Orttaai.bgSecondary.opacity(0.55))
                .clipShape(RoundedRectangle(cornerRadius: CornerRadius.card, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: CornerRadius.card, style: .continuous)
                        .stroke(Color.Orttaai.border.opacity(0.7), lineWidth: BorderWidth.standard)
                )
            }

            VStack(alignment: .leading, spacing: Spacing.md) {
                Text("Acknowledgments")
                    .font(.Orttaai.subheading)
                    .foregroundStyle(Color.Orttaai.textPrimary)

                VStack(spacing: Spacing.sm) {
                    acknowledgmentRow("WhisperKit", "On-device speech recognition")
                    acknowledgmentRow("GRDB.swift", "SQLite database toolkit")
                    acknowledgmentRow("Sparkle", "Auto-update framework")
                    acknowledgmentRow("KeyboardShortcuts", "Shortcut recording")
                }

                Text("MIT License")
                    .font(.Orttaai.caption)
                    .foregroundStyle(Color.Orttaai.textTertiary)
                    .padding(.top, Spacing.sm)
            }
            .padding(Spacing.lg)
            .dashboardCard()
        }
        .padding(Spacing.xxl)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func acknowledgmentRow(_ name: String, _ description: String) -> some View {
        HStack(spacing: Spacing.sm) {
            Text(name)
                .font(.Orttaai.bodyMedium)
                .foregroundStyle(Color.Orttaai.textPrimary)

            Text(description)
                .font(.Orttaai.secondary)
                .foregroundStyle(Color.Orttaai.textSecondary)

            Spacer()
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.sm)
        .background(Color.Orttaai.bgPrimary.opacity(0.45))
        .clipShape(RoundedRectangle(cornerRadius: CornerRadius.input, style: .continuous))
    }

    @ViewBuilder
    private func maintainerCard(
        title: String,
        value: String,
        systemImage: String,
        destination: URL? = nil
    ) -> some View {
        if let destination {
            Link(destination: destination) {
                maintainerCardBody(title: title, value: value, systemImage: systemImage)
            }
            .buttonStyle(.plain)
        } else {
            maintainerCardBody(title: title, value: value, systemImage: systemImage)
        }
    }

    private func maintainerCardBody(title: String, value: String, systemImage: String) -> some View {
        VStack(alignment: .center, spacing: Spacing.sm) {
            Image(systemName: systemImage)
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(Color.Orttaai.accent)
                .frame(width: 60, height: 60)
                .background(Color.Orttaai.accentSubtle)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

            Text(title.uppercased())
                .font(.Orttaai.caption)
                .foregroundStyle(Color.Orttaai.textTertiary)
                .frame(maxWidth: .infinity, alignment: .center)
                .multilineTextAlignment(.center)

            Text(value)
                .font(.Orttaai.bodyMedium)
                .foregroundStyle(Color.Orttaai.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .center)
                .multilineTextAlignment(.center)
        }
        .padding(Spacing.md)
        .frame(width: 210, alignment: .center)
        .background(Color.Orttaai.bgPrimary.opacity(0.45))
        .clipShape(RoundedRectangle(cornerRadius: CornerRadius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: CornerRadius.card, style: .continuous)
                .stroke(Color.Orttaai.border.opacity(0.7), lineWidth: BorderWidth.standard)
        )
    }
}
