// AboutView.swift
// Orttaai

import SwiftUI

struct AboutView: View {
    private let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
    private let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
    private let isHomebrew = Bundle.main.isHomebrewInstall
    private let emailURL = URL(string: "mailto:Oyinbookeola@outlook.com")!
    private let githubURL = AppLinks.githubProfileURL
    private let repoURL = AppLinks.githubRepositoryURL
    private let youtubeURL = URL(string: "https://youtube.com/c/theoyinbooke")!

    private var creatorLinks: [AboutLinkItem] {
        [
            AboutLinkItem(
                title: "Author",
                value: "Olanrewaju Oyinbooke",
                systemImage: "person.crop.circle.fill"
            ),
            AboutLinkItem(
                title: "Email",
                value: "Oyinbookeola@outlook.com",
                systemImage: "envelope.fill",
                destination: emailURL
            ),
            AboutLinkItem(
                title: "GitHub",
                value: "github.com/theoyinbooke",
                systemImage: "chevron.left.forwardslash.chevron.right",
                destination: githubURL
            ),
            AboutLinkItem(
                title: "YouTube",
                value: "youtube.com/c/theoyinbooke",
                systemImage: "play.rectangle.fill",
                destination: youtubeURL
            ),
        ]
    }

    private var creatorGridColumns: [GridItem] {
        [
            GridItem(
                .adaptive(minimum: 230, maximum: 420),
                spacing: Spacing.md,
                alignment: .topLeading
            )
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            pageHeader
            appSummaryCard
            creatorCard
            openSourceCard

            if isHomebrew {
                homebrewCard
            }

            acknowledgmentsCard
        }
        .padding(WorkspaceLayout.contentInsets)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var pageHeader: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Text("About")
                .font(.Orttaai.heading)
                .foregroundStyle(Color.Orttaai.textPrimary)

            Text("Build info, creator details, and open-source components.")
                .font(.Orttaai.secondary)
                .foregroundStyle(Color.Orttaai.textSecondary)
        }
    }

    private var appSummaryCard: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: Spacing.lg) {
                appIcon
                appSummaryText
                Spacer(minLength: 0)
                versionBadge
            }

            VStack(alignment: .leading, spacing: Spacing.md) {
                HStack(alignment: .center, spacing: Spacing.md) {
                    appIcon
                    appSummaryText
                }
                versionBadge
            }
        }
        .padding(Spacing.lg)
        .dashboardCard()
    }

    private var appIcon: some View {
        Image(systemName: "waveform.circle.fill")
            .font(.system(size: 44, weight: .semibold))
            .foregroundStyle(Color.Orttaai.accent)
            .frame(width: 58, height: 58)
            .background(Color.Orttaai.accentSubtle)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var appSummaryText: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Text("Orttaai")
                .font(.Orttaai.title)
                .foregroundStyle(Color.Orttaai.textPrimary)

            Text("Native macOS voice keyboard")
                .font(.Orttaai.secondary)
                .foregroundStyle(Color.Orttaai.textSecondary)
        }
    }

    private var versionBadge: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Version")
                .font(.Orttaai.caption)
                .foregroundStyle(Color.Orttaai.textTertiary)
            Text("\(version) (\(build))")
                .font(.Orttaai.bodyMedium)
                .foregroundStyle(Color.Orttaai.textPrimary)
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.sm)
        .background(Color.Orttaai.bgPrimary.opacity(0.55))
        .clipShape(RoundedRectangle(cornerRadius: CornerRadius.input, style: .continuous))
    }

    private var creatorCard: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            HStack(alignment: .center, spacing: Spacing.md) {
                creatorMonogram

                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text("Created and maintained by Olanrewaju Oyinbooke")
                        .font(.Orttaai.subheading)
                        .foregroundStyle(Color.Orttaai.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)

                    Text("Orttaai is built as a local-first writing tool for fast, private dictation on macOS.")
                        .font(.Orttaai.secondary)
                        .foregroundStyle(Color.Orttaai.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)
            }

            LazyVGrid(columns: creatorGridColumns, alignment: .leading, spacing: Spacing.md) {
                ForEach(creatorLinks) { item in
                    creatorLinkCard(item)
                }
            }
        }
        .padding(Spacing.lg)
        .dashboardCard()
    }

    private var creatorMonogram: some View {
        Text("OO")
            .font(.system(size: 18, weight: .bold))
            .foregroundStyle(Color.Orttaai.accent)
            .frame(width: 48, height: 48)
            .background(Color.Orttaai.accentSubtle)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    @ViewBuilder
    private func creatorLinkCard(_ item: AboutLinkItem) -> some View {
        if let destination = item.destination {
            Link(destination: destination) {
                creatorLinkCardBody(item)
            }
            .buttonStyle(.plain)
        } else {
            creatorLinkCardBody(item)
        }
    }

    private func creatorLinkCardBody(_ item: AboutLinkItem) -> some View {
        HStack(spacing: Spacing.sm) {
            Image(systemName: item.systemImage)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Color.Orttaai.accent)
                .frame(width: 30, height: 30)
                .background(Color.Orttaai.accentSubtle)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(item.title.uppercased())
                    .font(.Orttaai.caption)
                    .foregroundStyle(Color.Orttaai.textTertiary)
                    .lineLimit(1)

                Text(item.value)
                    .font(.Orttaai.bodyMedium)
                    .foregroundStyle(Color.Orttaai.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 0)

            if item.destination != nil {
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.Orttaai.textTertiary)
            }
        }
        .padding(Spacing.md)
        .background(Color.Orttaai.bgPrimary.opacity(0.45))
        .clipShape(RoundedRectangle(cornerRadius: CornerRadius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: CornerRadius.card, style: .continuous)
                .stroke(Color.Orttaai.border.opacity(0.7), lineWidth: BorderWidth.standard)
        )
    }

    private var openSourceCard: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text("Open Source and Free")
                .font(.Orttaai.subheading)
                .foregroundStyle(Color.Orttaai.textPrimary)

            Text("No paywall. No server-side transcription. Local-first dictation and user trust come first.")
                .font(.Orttaai.secondary)
                .foregroundStyle(Color.Orttaai.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            ViewThatFits(in: .horizontal) {
                HStack(spacing: Spacing.sm) {
                    supportLinks
                }

                VStack(alignment: .leading, spacing: Spacing.sm) {
                    supportLinks
                }
            }
            .padding(.top, Spacing.xs)
        }
        .padding(Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .dashboardCard()
    }

    private var supportLinks: some View {
        Group {
            Link(destination: AppLinks.newIssueURL(kind: .bug, version: version, build: build)) {
                Label("Report Bug", systemImage: "ant")
                    .font(.Orttaai.bodyMedium)
            }
            .buttonStyle(OrttaaiButtonStyle(.secondary))

            Link(destination: AppLinks.newIssueURL(kind: .support, version: version, build: build)) {
                Label("Get Support", systemImage: "lifepreserver")
                    .font(.Orttaai.bodyMedium)
            }
            .buttonStyle(OrttaaiButtonStyle(.secondary))

            Link(destination: repoURL) {
                Label("Contribute on GitHub", systemImage: "arrow.up.right.square")
                    .font(.Orttaai.bodyMedium)
            }
            .buttonStyle(OrttaaiButtonStyle(.secondary))
        }
    }

    private var homebrewCard: some View {
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

    private var acknowledgmentsCard: some View {
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

    private func acknowledgmentRow(_ name: String, _ description: String) -> some View {
        HStack(spacing: Spacing.sm) {
            Text(name)
                .font(.Orttaai.bodyMedium)
                .foregroundStyle(Color.Orttaai.textPrimary)

            Text(description)
                .font(.Orttaai.secondary)
                .foregroundStyle(Color.Orttaai.textSecondary)
                .lineLimit(1)

            Spacer()
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.sm)
        .background(Color.Orttaai.bgPrimary.opacity(0.45))
        .clipShape(RoundedRectangle(cornerRadius: CornerRadius.input, style: .continuous))
    }
}

private struct AboutLinkItem: Identifiable {
    let title: String
    let value: String
    let systemImage: String
    let destination: URL?

    var id: String { title }

    init(
        title: String,
        value: String,
        systemImage: String,
        destination: URL? = nil
    ) {
        self.title = title
        self.value = value
        self.systemImage = systemImage
        self.destination = destination
    }
}
