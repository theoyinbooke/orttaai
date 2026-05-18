// HomeHeaderView.swift
// Orttaai

import SwiftUI

struct HomeHeaderView: View {
    let stats: DashboardHeaderStats
    let isRefreshing: Bool
    let isCompact: Bool
    let isInsightsVisible: Bool
    let onToggleInsights: () -> Void

    var body: some View {
        let showsStatLabels = !isInsightsVisible || !isCompact

        HStack(alignment: .top, spacing: Spacing.lg) {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text("Welcome back")
                    .font(.Orttaai.title)
                    .foregroundStyle(Color.Orttaai.textPrimary)

                if !isCompact {
                    Text("Your personal dictation dashboard")
                        .font(.Orttaai.secondary)
                        .foregroundStyle(Color.Orttaai.textSecondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: Spacing.sm) {
                HStack(spacing: Spacing.sm) {
                    StatChipView(label: "active days", value: "\(stats.activeDays7d)", showsLabel: showsStatLabels)
                    StatChipView(label: "words", value: stats.words7d.formatted(), showsLabel: showsStatLabels)
                    StatChipView(label: "avg WPM", value: "\(stats.averageWPM7d)", showsLabel: showsStatLabels)

                    if !isInsightsVisible {
                        Button {
                            onToggleInsights()
                        } label: {
                            Label("Insight", systemImage: "lightbulb")
                                .font(.Orttaai.secondary)
                                .lineLimit(1)
                        }
                        .buttonStyle(OrttaaiButtonStyle(.secondary))
                        .fixedSize(horizontal: true, vertical: false)
                        .help("Open writing insights panel")
                    }
                }

                if isRefreshing {
                    HStack(spacing: Spacing.xs) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Updating")
                            .font(.Orttaai.caption)
                            .foregroundStyle(Color.Orttaai.textTertiary)
                    }
                    .accessibilityLabel("Dashboard updating")
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            "Welcome back. Active days \(stats.activeDays7d), words \(stats.words7d), average W P M \(stats.averageWPM7d)."
        )
    }
}
