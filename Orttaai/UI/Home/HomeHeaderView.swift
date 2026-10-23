// HomeHeaderView.swift
// Orttaai

import SwiftUI

/// The Overview page's buttons, shown at the trailing edge of the page
/// header; the header itself carries the "Welcome back" title. The numbers
/// live in the cards below.
struct HomeHeaderView: View {
    let isRefreshing: Bool
    let isInsightsVisible: Bool
    let onOpenHistory: () -> Void
    let onToggleInsights: () -> Void

    var body: some View {
        HStack(spacing: Spacing.sm) {
            if isRefreshing {
                ProgressView()
                    .controlSize(.small)
                    .help("Updating")
                    .accessibilityLabel("Dashboard updating")
            }

            Button {
                onOpenHistory()
            } label: {
                Label("Open History", systemImage: "clock.arrow.circlepath")
                    .lineLimit(1)
            }
            .buttonStyle(ChipButtonStyle())
            .fixedSize(horizontal: true, vertical: false)
            .help("Open your dictation history")

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

/// A capsule button for the page header, so its actions share one shape,
/// height and type.
struct ChipButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        ChipButton(configuration: configuration)
    }

    private struct ChipButton: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.isEnabled) private var isEnabled
        @State private var isHovered = false

        var body: some View {
            configuration.label
                .font(.Orttaai.bodyMedium)
                .foregroundStyle(Color.Orttaai.textPrimary)
                .padding(.horizontal, Spacing.md)
                .padding(.vertical, Spacing.sm)
                .background(
                    Capsule().fill(
                        configuration.isPressed || isHovered
                            ? Color.Orttaai.bgTertiary
                            : Color.Orttaai.bgSecondary
                    )
                )
                .overlay(
                    Capsule()
                        .stroke(Color.Orttaai.border, lineWidth: BorderWidth.standard)
                )
                .contentShape(Capsule())
                .opacity(isEnabled ? 1 : 0.45)
                .onHover { isHovered = $0 }
        }
    }
}
