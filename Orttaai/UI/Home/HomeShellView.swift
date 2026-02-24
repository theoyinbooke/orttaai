// HomeShellView.swift
// Orttaai

import SwiftUI

struct HomeShellView: View {
    @ObservedObject var navigation: HomeNavigationState
    let onRunSetup: () -> Void

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let collapsedSidebar = width < 1_020
            let iconOnlySidebar = width < 860
            let compactOverview = width < 1_180

            HStack(spacing: 0) {
                sidebar(collapsed: collapsedSidebar, iconOnly: iconOnlySidebar)

                Divider()
                    .background(Color.Orttaai.border)

                content(compactOverview: compactOverview)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.Orttaai.bgPrimary)
        }
    }

    private func content(compactOverview: Bool) -> some View {
        Group {
            switch navigation.selectedSection {
            case .overview:
                HomeView(
                    onOpenSettings: { navigation.selectedSection = .settings },
                    onOpenModelSettings: { navigation.selectedSection = .model },
                    onOpenHistory: { navigation.selectedSection = .history },
                    onRunSetup: onRunSetup,
                    layoutMode: compactOverview ? .compact : .regular
                )
            case .history:
                HistoryView()
            case .settings:
                HomeSettingsWorkspaceView()
            case .model:
                ModelSettingsView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .background(Color.Orttaai.bgPrimary)
            case .about:
                ScrollView(showsIndicators: false) {
                    AboutView()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(Color.Orttaai.bgPrimary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func sidebar(collapsed: Bool, iconOnly: Bool) -> some View {
        let sidebarWidth: CGFloat = iconOnly ? 72 : (collapsed ? 88 : 240)

        return VStack(alignment: collapsed ? .center : .leading, spacing: Spacing.lg) {
            if !collapsed {
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text("Orttaai Home")
                        .font(.Orttaai.heading)
                        .foregroundStyle(Color.Orttaai.textPrimary)

                    Text("Personal workspace")
                        .font(.Orttaai.secondary)
                        .foregroundStyle(Color.Orttaai.textTertiary)
                }
            }

            VStack(spacing: Spacing.sm) {
                ForEach(HomeSection.allCases) { section in
                    navItem(section: section, collapsed: collapsed)
                }
            }

            Spacer()

            Button {
                onRunSetup()
            } label: {
                Group {
                    if collapsed {
                        Image(systemName: "slider.horizontal.3")
                    } else {
                        Label("Run Setup", systemImage: "slider.horizontal.3")
                    }
                }
                .frame(maxWidth: .infinity, alignment: collapsed ? .center : .leading)
            }
            .buttonStyle(OrttaaiButtonStyle(.secondary))
            .help("Run setup again")
        }
        .padding(.horizontal, collapsed ? Spacing.sm : Spacing.lg)
        .padding(.vertical, Spacing.lg)
        .frame(width: sidebarWidth)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color.Orttaai.bgSecondary.opacity(0.35))
    }

    private func navItem(section: HomeSection, collapsed: Bool) -> some View {
        Button {
            navigation.selectedSection = section
        } label: {
            HStack(spacing: Spacing.sm) {
                Image(systemName: section.icon)
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 16)

                if !collapsed {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(section.title)
                            .font(.Orttaai.bodyMedium)

                        Text(section.subtitle)
                            .font(.Orttaai.caption)
                            .foregroundStyle(Color.Orttaai.textTertiary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 0)
            }
            .foregroundStyle(
                navigation.selectedSection == section
                    ? Color.Orttaai.textPrimary
                    : Color.Orttaai.textSecondary
            )
            .padding(.horizontal, collapsed ? Spacing.sm : Spacing.md)
            .padding(.vertical, collapsed ? Spacing.sm : Spacing.md)
            .frame(maxWidth: .infinity, alignment: collapsed ? .center : .leading)
            .background(
                RoundedRectangle(cornerRadius: CornerRadius.card, style: .continuous)
                    .fill(
                        navigation.selectedSection == section
                            ? Color.Orttaai.accentSubtle
                            : Color.clear
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: CornerRadius.card, style: .continuous)
                    .stroke(
                        navigation.selectedSection == section
                            ? Color.Orttaai.accent.opacity(0.5)
                            : Color.Orttaai.border.opacity(0.35),
                        lineWidth: BorderWidth.standard
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: CornerRadius.card, style: .continuous))
        }
        .frame(maxWidth: .infinity)
        .buttonStyle(.plain)
        .help(section.title)
    }
}
