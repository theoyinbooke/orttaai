// HomeSettingsWorkspaceView.swift
// Orttaai

import SwiftUI

private enum HomeSettingsSubsection: String, CaseIterable, Identifiable {
    case general
    case audio

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "General"
        case .audio: return "Audio"
        }
    }

    var subtitle: String {
        switch self {
        case .general: return "App behavior and shortcuts"
        case .audio: return "Input device and live monitoring"
        }
    }

    var icon: String {
        switch self {
        case .general: return "slider.horizontal.3"
        case .audio: return "mic"
        }
    }
}

struct HomeSettingsWorkspaceView: View {
    @State private var subsection: HomeSettingsSubsection = .general

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: Spacing.md) {
                Text("Settings")
                    .font(.Orttaai.heading)
                    .foregroundStyle(Color.Orttaai.textPrimary)

                Text(subsection.subtitle)
                    .font(.Orttaai.secondary)
                    .foregroundStyle(Color.Orttaai.textSecondary)

                HStack(spacing: Spacing.sm) {
                    ForEach(HomeSettingsSubsection.allCases) { item in
                        tabButton(item)
                    }
                }
            }
            .padding(.horizontal, Spacing.xxl)
            .padding(.top, Spacing.xxl)
            .padding(.bottom, Spacing.lg)

            Divider()
                .background(Color.Orttaai.border)

            ScrollView(showsIndicators: false) {
                Group {
                    switch subsection {
                    case .general:
                        GeneralSettingsView()
                    case .audio:
                        AudioSettingsView()
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.Orttaai.bgPrimary)
    }

    private func tabButton(_ item: HomeSettingsSubsection) -> some View {
        Button {
            withAnimation(.easeOut(duration: 0.16)) {
                subsection = item
            }
        } label: {
            HStack(spacing: Spacing.xs) {
                Image(systemName: item.icon)
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 14)

                Text(item.title)
                    .font(.Orttaai.secondary)
                    .lineLimit(1)
            }
            .foregroundStyle(
                subsection == item
                    ? Color.Orttaai.textPrimary
                    : Color.Orttaai.textSecondary
            )
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, Spacing.sm)
            .background(
                RoundedRectangle(cornerRadius: CornerRadius.button, style: .continuous)
                    .fill(
                        subsection == item
                            ? Color.Orttaai.accentSubtle
                            : Color.Orttaai.bgSecondary.opacity(0.55)
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: CornerRadius.button, style: .continuous)
                    .stroke(
                        subsection == item
                            ? Color.Orttaai.accent.opacity(0.55)
                            : Color.Orttaai.border.opacity(0.6),
                        lineWidth: BorderWidth.standard
                    )
            )
        }
        .buttonStyle(.plain)
        .help(item.title)
    }
}
