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

    private let acknowledgments: [(name: String, detail: String)] = [
        ("WhisperKit", "On-device speech recognition"),
        ("GRDB.swift", "SQLite database toolkit"),
        ("Sparkle", "Auto-update framework"),
        ("KeyboardShortcuts", "Shortcut recording"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            appCard
            creatorCard
            openSourceCard
            acknowledgmentsCard
        }
        .settingsPageLayout()
        .workspaceHeader("About")
    }

    // MARK: - Cards

    private var appCard: some View {
        SettingsCard {
            HStack(alignment: .center, spacing: Spacing.md) {
                OrttaaiAppIcon()
                    .frame(width: 52, height: 52)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Orttaai")
                        .font(.Orttaai.title)
                        .foregroundStyle(Color.Orttaai.textPrimary)
                    Text("Private, on-device dictation for your Mac.")
                        .font(.Orttaai.secondary)
                        .foregroundStyle(Color.Orttaai.textSecondary)
                }

                Spacer(minLength: Spacing.md)

                StatusChip(
                    title: "Version \(version) (\(build))",
                    systemImage: "checkmark.seal",
                    tint: Color.Orttaai.textSecondary
                )
            }
            .padding(.vertical, Spacing.xs)

            SettingsDivider()
                .padding(.top, Spacing.sm)

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
                    info: "Orttaai also checks for updates automatically in the background."
                ) {
                    Button("Check for Updates…") {
                        NotificationCenter.default.post(name: .checkForUpdatesRequested, object: nil)
                    }
                    .buttonStyle(OrttaaiButtonStyle(.secondary, size: .small))
                    .disabled(!appUpdates.isSupported)
                }

                SettingsDivider()
                SettingsRow(
                    title: "Automatically download updates",
                    info: "Downloads updates in the background. When ready, use Update at the bottom left to install and relaunch. Updates also install when you quit."
                ) {
                    Toggle("Automatically download updates", isOn: Binding(
                        get: { appUpdates.automaticallyDownloadsUpdates },
                        set: { appUpdates.setAutomaticallyDownloadsUpdates($0) }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .disabled(!appUpdates.isSupported)
                }
            }
        }
    }

    private var creatorCard: some View {
        SettingsCard("Creator") {
            SettingsRow(title: "Author") {
                Text("Olanrewaju Oyinbooke")
                    .font(.Orttaai.secondary)
                    .foregroundStyle(Color.Orttaai.textSecondary)
            }

            ForEach(creatorLinks) { item in
                SettingsDivider()
                SettingsRow(title: item.title) {
                    if let destination = item.destination {
                        Link(destination: destination) {
                            HStack(spacing: Spacing.xs) {
                                Text(item.value)
                                Image(systemName: "arrow.up.right")
                                    .font(.system(size: 9, weight: .bold))
                            }
                            .font(.Orttaai.secondary)
                            .foregroundStyle(Color.Orttaai.accent)
                        }
                        .buttonStyle(.plain)
                        .help("Open \(item.value)")
                    }
                }
            }
        }
    }

    private var openSourceCard: some View {
        SettingsCard(
            "Open Source",
            info: "Orttaai is free and open source under the MIT License. Bug reports and support requests open a GitHub issue prefilled with your version."
        ) {
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
            .padding(.vertical, Spacing.xs)
        }
    }

    private var acknowledgmentsCard: some View {
        SettingsCard("Acknowledgments") {
            ForEach(Array(acknowledgments.enumerated()), id: \.offset) { index, item in
                if index > 0 {
                    SettingsDivider()
                }
                SettingsRow(title: item.name) {
                    Text(item.detail)
                        .font(.Orttaai.secondary)
                        .foregroundStyle(Color.Orttaai.textSecondary)
                }
            }
        }
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
