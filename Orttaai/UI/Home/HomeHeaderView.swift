// HomeHeaderView.swift
// Orttaai

import SwiftUI

/// The Overview page's stats and Insight button, shown at the trailing edge
/// of the page header; the header itself carries the "Welcome back" title.
struct HomeHeaderView: View {
    let stats: DashboardHeaderStats
    let isRefreshing: Bool
    let isCompact: Bool
    let isInsightsVisible: Bool
    let onToggleInsights: () -> Void

    var body: some View {
        let showsStatLabels = !isInsightsVisible || !isCompact

        HStack(spacing: Spacing.sm) {
            if isRefreshing {
                ProgressView()
                    .controlSize(.small)
                    .help("Updating")
                    .accessibilityLabel("Dashboard updating")
            }

            HStack(spacing: Spacing.sm) {
                StatChipView(label: "active days", value: "\(stats.activeDays)", showsLabel: showsStatLabels)
                StatChipView(label: "words", value: stats.totalWords.formatted(), showsLabel: showsStatLabels)
                StatChipView(label: "avg WPM", value: "\(stats.averageWPM)", showsLabel: showsStatLabels)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(
                "Active days \(stats.activeDays), words \(stats.totalWords), average W P M \(stats.averageWPM)."
            )

            if !isInsightsVisible {
                Button {
                    onToggleInsights()
                } label: {
                    Label("Insight", systemImage: "lightbulb")
                        .lineLimit(1)
                }
                .buttonStyle(ChipButtonStyle())
                .fixedSize(horizontal: true, vertical: false)
                .help("Open writing insights panel")
            }
        }
    }
}
