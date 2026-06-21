// HomeShellView.swift
// Orttaai

import SwiftUI

struct HomeShellView: View {
    @ObservedObject var navigation: HomeNavigationState
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    let onRunSetup: () -> Void

    var body: some View {
        GeometryReader { proxy in
            let compactOverview = proxy.size.width < 1_180

            NavigationSplitView(columnVisibility: $columnVisibility) {
                HomeSidebarView(
                    selection: sidebarSelection,
                    onRunSetup: onRunSetup
                )
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 300)
            } detail: {
                content(compactOverview: compactOverview)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.Orttaai.bgPrimary)
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
    let onRunSetup: () -> Void

    private let workspaceSections: [HomeSection] = [.overview, .chatAI, .memory, .analytics]
    private let systemSections: [HomeSection] = [.model, .settings, .about]

    var body: some View {
        VStack(spacing: 0) {
            sidebarHeader

            List(selection: $selection) {
                Section("Workspace") {
                    ForEach(workspaceSections) { section in
                        HomeSidebarRow(section: section)
                            .tag(section as HomeSection?)
                    }
                }

                Section("Manage") {
                    ForEach(systemSections) { section in
                        HomeSidebarRow(section: section)
                            .tag(section as HomeSection?)
                    }
                }
            }
            .listStyle(.sidebar)

            Divider()

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

    private var sidebarHeader: some View {
        HStack(spacing: Spacing.sm) {
            Image(systemName: "waveform.circle.fill")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(Color.Orttaai.accent)
                .frame(width: 34, height: 34)

            VStack(alignment: .leading, spacing: 2) {
                Text("Orttaai")
                    .font(.Orttaai.bodyMedium)
                    .foregroundStyle(Color.Orttaai.textPrimary)
                    .lineLimit(1)

                Text("Personal workspace")
                    .font(.Orttaai.caption)
                    .foregroundStyle(Color.Orttaai.textSecondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
        .padding(.top, 54)
        .padding(.horizontal, Spacing.lg)
        .padding(.bottom, Spacing.sm)
    }
}

private struct HomeSidebarRow: View {
    let section: HomeSection

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: section.icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                Text(section.title)
                    .font(.Orttaai.bodyMedium)
                    .lineLimit(1)

                Text(section.subtitle)
                    .font(.Orttaai.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }
}
