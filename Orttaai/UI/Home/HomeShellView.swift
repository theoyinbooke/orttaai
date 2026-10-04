// HomeShellView.swift
// Orttaai

import SwiftUI

struct HomeShellView: View {
    @ObservedObject var navigation: HomeNavigationState
    @ObservedObject var appUpdates = AppUpdateService.shared
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    let onRunSetup: () -> Void

    var body: some View {
        GeometryReader { proxy in
            let compactOverview = proxy.size.width < 1_180

            NavigationSplitView(columnVisibility: $columnVisibility) {
                HomeSidebarView(
                    selection: sidebarSelection,
                    appUpdates: appUpdates,
                    onRunSetup: onRunSetup
                )
                .toolbar(removing: .sidebarToggle)
                .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 240)
            } detail: {
                content(compactOverview: compactOverview)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.Orttaai.bgPrimary)
                    .modifier(SolidHeaderScrollEdge())
                    .environment(\.workspaceSidebarToggle) {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            columnVisibility = columnVisibility == .detailOnly ? .all : .detailOnly
                        }
                    }
            }
            .navigationSplitViewStyle(.balanced)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color.Orttaai.bgPrimary)
        .onAppear {
            requestSyncIfShowingHome()
        }
        .onChange(of: navigation.selectedSection) { oldValue, newValue in
            guard oldValue != newValue else { return }
            if newValue == .overview {
                requestSyncIfShowingHome()
            }
        }
    }

    private var sidebarSelection: Binding<HomeSection?> {
        Binding(
            get: { navigation.selectedSection },
            set: { navigation.selectedSection = $0 ?? .overview }
        )
    }

    @ViewBuilder
    private func content(compactOverview: Bool) -> some View {
        switch navigation.selectedSection {
        case .overview:
            HomeView(
                onOpenSettings: { navigation.selectedSection = .settings },
                onOpenModelSettings: { navigation.selectedSection = .model },
                onOpenHistory: { navigation.selectedSection = .analytics },
                onRunSetup: onRunSetup,
                layoutMode: compactOverview ? .compact : .regular
            )
        case .chatAI:
            ChatAIView()
        case .graph:
            SemanticMemoryView()
        case .memory:
            MemoryView()
        case .analytics:
            AnalyticsView()
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

    private func requestSyncIfShowingHome() {
        guard navigation.selectedSection == .overview else { return }
        CloudSyncScheduler.requestSync(reason: .homeReturn, debounce: 0.5)
    }
}

private struct HomeSidebarView: View {
    @Binding var selection: HomeSection?
    @ObservedObject var appUpdates: AppUpdateService
    let onRunSetup: () -> Void

    private let workspaceSections: [HomeSection] = [.overview, .chatAI, .graph, .memory, .analytics]
    private let systemSections: [HomeSection] = [.model, .settings, .about]

    var body: some View {
        VStack(spacing: 0) {
            sidebarHeader

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 2) {
                    sectionHeader("Workspace")
                    ForEach(workspaceSections) { section in
                        HomeSidebarRow(
                            section: section,
                            isSelected: selection == section
                        ) {
                            selection = section
                        }
                    }

                    sectionHeader("Manage")
                        .padding(.top, Spacing.md)
                    ForEach(systemSections) { section in
                        HomeSidebarRow(
                            section: section,
                            isSelected: selection == section
                        ) {
                            selection = section
                        }
                    }
                }
                .padding(.horizontal, Spacing.sm)
                .padding(.top, Spacing.xs)
            }

            Divider()

            if let version = appUpdates.readyVersion {
                Button {
                    appUpdates.installReadyUpdate()
                } label: {
                    Label("Update", systemImage: "arrow.down.circle.fill")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(OrttaaiButtonStyle(.primary, size: .small))
                .padding(.horizontal, Spacing.lg)
                .padding(.top, Spacing.md)
                .help("Install Orttaai \(version) and relaunch")
                .accessibilityLabel("Update to Orttaai \(version)")
                .accessibilityIdentifier("InstallReadyUpdate")
            }

            Button {
                onRunSetup()
            } label: {
                Label("Run Setup", systemImage: "slider.horizontal.3")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.borderless)
            .controlSize(.large)
            .padding(.horizontal, Spacing.lg)
            .padding(.vertical, Spacing.md)
            .help("Run setup again")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.Orttaai.caption)
            .foregroundStyle(Color.Orttaai.textTertiary)
            .padding(.horizontal, Spacing.sm)
            .padding(.bottom, 2)
            .accessibilityAddTraits(.isHeader)
    }

    private var sidebarHeader: some View {
        HStack(spacing: Spacing.sm) {
            OrttaaiBrandMark()
                .frame(width: 23, height: 20)
                .frame(width: 34, height: 34)

            Text("Orttaai")
                .font(.Orttaai.bodyMedium)
                .foregroundStyle(Color.Orttaai.textPrimary)
                .lineLimit(1)

            Spacer(minLength: 0)
        }
        .padding(.top, WorkspaceLayout.sidebarHeaderTopPadding)
        .padding(.horizontal, Spacing.lg)
        .padding(.bottom, Spacing.sm)
    }
}

private struct HomeSidebarRow: View {
    let section: HomeSection
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: section.icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(isSelected ? Color.Orttaai.accent : Color.Orttaai.textSecondary)
                    .frame(width: 18)

                Text(section.title)
                    .font(.Orttaai.bodyMedium)
                    .foregroundStyle(Color.Orttaai.textPrimary)
                    .lineLimit(1)

                Spacer(minLength: 0)
            }
            .padding(.vertical, 6)
            .padding(.horizontal, Spacing.sm)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(rowBackground)
            )
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityLabel(section.title)
        .accessibilityIdentifier("Sidebar-\(section.title)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var rowBackground: Color {
        if isSelected {
            return Color.Orttaai.accentSubtle
        }
        if isHovering {
            return Color.Orttaai.bgTertiary.opacity(0.5)
        }
        return .clear
    }
}

/// Page headers live in the transparent toolbar strip. Clipping the page to
/// its own area keeps scrolled content from drawing up under the title.
private struct SolidHeaderScrollEdge: ViewModifier {
    func body(content: Content) -> some View {
        content.clipped()
    }
}
