// AboutView.swift
// Orttaai

import SwiftUI

struct AboutView: View {
    @ObservedObject private var appUpdates = AppUpdateService.shared
    private let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
    private let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
    private let isHomebrew = Bundle.main.isHomebrewInstall
    private let githubURL = AppLinks.githubProfileURL
    private let repoURL = AppLinks.githubRepositoryURL
    private let youtubeURL = URL(string: "https://youtube.com/c/theoyinbooke")!

    private var creatorLinks: [AboutLinkItem] {
        [
            AboutLinkItem(
                title: "GitHub",
                value: "github.com/theoyinbooke",
                systemImage: "chevron.left.forwardslash.chevron.right",
                destination: githubURL
            ),
            AboutLinkItem(
                title: "YouTube",
                value: "youtube.com/c/theoyinbooke",
                systemImage: "play.rectangle",
                destination: youtubeURL
            ),
        ]
    }

    private let acknowledgments: [AboutCredit] = [
        AboutCredit(name: "WhisperKit", detail: "On-device speech recognition", systemImage: "waveform"),
        AboutCredit(
            name: ExpressEngine.attribution,
            detail: "Express speech model, CC BY 4.0, built on NVIDIA Parakeet TDT 0.6B v3",
            systemImage: "bolt"
        ),
        AboutCredit(
            name: "Parakeet CTC 110M",
            detail: "Express Word Boost model by NVIDIA, CC BY 4.0, Core ML conversion by FluidInference",
            systemImage: "text.badge.checkmark"
        ),
        AboutCredit(name: "FluidAudio", detail: "Runs Fluid Speech Mini on the Neural Engine, Apache 2.0", systemImage: "cpu"),
        AboutCredit(name: "GRDB.swift", detail: "SQLite database toolkit", systemImage: "cylinder"),
        AboutCredit(name: "Sparkle", detail: "Auto-update framework", systemImage: "arrow.down.circle"),
        AboutCredit(name: "KeyboardShortcuts", detail: "Shortcut recording", systemImage: "keyboard"),
    ]

    private let creditColumns = [
        GridItem(.flexible(), spacing: Spacing.xl, alignment: .top),
        GridItem(.flexible(), spacing: Spacing.xl, alignment: .top),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            heroCard
            communityCard
            acknowledgmentsCard
        }
        .settingsPageLayout()
        .workspaceHeader("About")
    }

    // MARK: - Cards

    private var heroCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: Spacing.lg) {
                OrttaaiAppIcon()
                    .frame(width: 64, height: 64)

                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text("Orttaai")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(Color.Orttaai.textPrimary)
                    Text("Private, on-device dictation for your Mac.")
                        .font(.Orttaai.secondary)
                        .foregroundStyle(Color.Orttaai.textSecondary)
                    StatusChip(
                        title: "Version \(version) (\(build))",
                        systemImage: "checkmark.seal",
                        tint: Color.Orttaai.accent
                    )
                    .padding(.top, 2)
                }

                Spacer(minLength: Spacing.md)
            }
            .padding(Spacing.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(alignment: .trailing) { heroBackdrop }
            .clipped()

            Rectangle()
                .fill(Color.Orttaai.border)
                .frame(height: BorderWidth.standard)

            updateRows
                .padding(.horizontal, Spacing.md)
                .padding(.vertical, Spacing.xs)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipShape(RoundedRectangle(cornerRadius: CornerRadius.card, style: .continuous))
        .dashboardCard()
    }

    /// The signal-bars mark, oversized and faded behind the header, with a
    /// soft amber wash: the brand's own shape instead of decoration.
    private var heroBackdrop: some View {
        ZStack(alignment: .trailing) {
            LinearGradient(
                colors: [Color.Orttaai.accent.opacity(0.10), .clear],
                startPoint: .trailing,
                endPoint: .leading
            )
            OrttaaiBrandMark(color: Color.Orttaai.accent.opacity(0.10))
                .frame(height: 112)
                .offset(x: -Spacing.xl, y: 34)
        }
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var updateRows: some View {
        if isHomebrew {
            SettingsRow(
                title: "Updates",
                info: "This copy was installed with Homebrew, which manages its updates."
            ) {
                Text("brew upgrade orttaai")
                    .font(.Orttaai.mono)
                    .foregroundStyle(Color.Orttaai.accent)
                    .textSelection(.enabled)
            }
        } else {
            SettingsRow(
                title: "Updates",
                info: "Orttaai checks every few hours, and when you open this window. A new version shows at the bottom left of the sidebar."
            ) {
                Button("Check for Updates…") {
                    NotificationCenter.default.post(name: .checkForUpdatesRequested, object: nil)
                }
                .buttonStyle(OrttaaiButtonStyle(.secondary, size: .small))
                .disabled(!appUpdates.isSupported)
            }

            SettingsDivider()
            SettingsToggleRow(
                title: "Automatically download updates",
                info: "Downloads a new version as soon as it's found, with its progress at the bottom left. Click Restart to update there, or it installs when you quit.",
                isOn: Binding(
                    get: { appUpdates.automaticallyDownloadsUpdates },
                    set: { appUpdates.setAutomaticallyDownloadsUpdates($0) }
                )
            )
            .disabled(!appUpdates.isSupported)
        }
    }

    private var communityCard: some View {
        SettingsCard(
            "Open Source",
            info: "Orttaai is free and open source under the MIT License. Bug reports and support requests open a GitHub issue prefilled with your version."
        ) {
            HStack(alignment: .center, spacing: Spacing.sm) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Made by")
                        .font(.Orttaai.caption)
                        .foregroundStyle(Color.Orttaai.textTertiary)
                    Text("Olanrewaju Oyinbooke")
                        .font(.Orttaai.bodyMedium)
                        .foregroundStyle(Color.Orttaai.textPrimary)
                }

                Spacer(minLength: Spacing.md)

                ForEach(creatorLinks) { item in
                    if let destination = item.destination {
                        Link(destination: destination) {
                            Label(item.title, systemImage: item.systemImage)
                        }
                        .buttonStyle(OrttaaiButtonStyle(.ghost, size: .small))
                        .help("Open \(item.value)")
                    }
                }
            }
            .padding(.vertical, Spacing.xs)

            SettingsDivider()

            HStack(spacing: Spacing.sm) {
                Link(destination: AppLinks.newIssueURL(kind: .bug, version: version, build: build)) {
                    Label("Report a Bug", systemImage: "ant")
                }
                .buttonStyle(OrttaaiButtonStyle(.secondary, size: .small))

                Link(destination: AppLinks.newIssueURL(kind: .support, version: version, build: build)) {
                    Label("Get Support", systemImage: "lifepreserver")
                }
                .buttonStyle(OrttaaiButtonStyle(.secondary, size: .small))

                Link(destination: repoURL) {
                    Label("Contribute on GitHub", systemImage: "arrow.up.right.square")
                }
                .buttonStyle(OrttaaiButtonStyle(.secondary, size: .small))

                Spacer(minLength: 0)
            }
            .padding(.top, Spacing.sm)
            .padding(.bottom, Spacing.xs)
        }
    }

    private var acknowledgmentsCard: some View {
        SettingsCard("Acknowledgments") {
            LazyVGrid(columns: creditColumns, alignment: .leading, spacing: Spacing.md) {
                ForEach(acknowledgments) { credit in
                    AboutCreditTile(credit: credit)
                }
            }
            .padding(.vertical, Spacing.xs)
        }
    }
}

private struct AboutCredit: Identifiable {
    let name: String
    let detail: String
    let systemImage: String

    var id: String { name }
}

/// One open-source credit: an outline glyph in an amber-tinted square, like
/// the sidebar's icons, then the project's name and what it does here.
private struct AboutCreditTile: View {
    let credit: AboutCredit

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.md) {
            Image(systemName: credit.systemImage)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.Orttaai.accent)
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.Orttaai.accentSubtle)
                )

            VStack(alignment: .leading, spacing: 2) {
                Text(credit.name)
                    .font(.Orttaai.bodyMedium)
                    .foregroundStyle(Color.Orttaai.textPrimary)
                    .lineLimit(1)
                Text(credit.detail)
                    .font(.Orttaai.caption)
                    .foregroundStyle(Color.Orttaai.textSecondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, Spacing.xs)
        .frame(maxWidth: .infinity, alignment: .topLeading)
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
