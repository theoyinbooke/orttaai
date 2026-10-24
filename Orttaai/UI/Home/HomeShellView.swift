// HomeShellView.swift
// Orttaai

import Combine
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
            .overlay {
                MilestoneCelebrationHost(navigation: navigation)
            }
            .overlay {
                WhatsNewHost()
            }
        }
        .sheet(item: $navigation.milestoneShareSubject) { subject in
            MilestoneShareSheet(subject: subject)
        }
        .background(Color.Orttaai.bgPrimary)
        .onAppear {
            requestSyncIfShowingHome()
            appUpdates.checkIfStale()
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
            ChatAIView(pendingPrompt: $navigation.pendingChatPrompt, onOpenAISettings: navigation.openAISettings)
        case .graph:
            SemanticMemoryView(onAskChat: navigation.askChatAI, onOpenAISettings: navigation.openAISettings)
        case .memory:
            MemoryView(openSuggestions: $navigation.openMemorySuggestions)
        case .analytics:
            AnalyticsView()
        case .milestones:
            MilestonesView(shareSubject: $navigation.milestoneShareSubject)
        case .settings:
            HomeSettingsWorkspaceView()
        case .model:
            ModelSettingsView(initialSection: navigation.pendingModelSection ?? .speech)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(Color.Orttaai.bgPrimary)
                .onAppear { navigation.pendingModelSection = nil }
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
    @StateObject private var pendingSuggestions = PendingSuggestionCount()
    let onRunSetup: () -> Void

    private let workspaceSections: [HomeSection] = [.overview, .chatAI, .graph, .memory, .analytics, .milestones]
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
                            isSelected: selection == section,
                            count: section == .memory ? pendingSuggestions.count : 0
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

            AppUpdateSidebarButton(updates: appUpdates)
                .padding(.horizontal, Spacing.sm)
                .padding(.top, Spacing.md)
                .animation(.easeOut(duration: 0.2), value: appUpdates.phase == .idle)

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
    /// A small count after the title (suggestions waiting in Memory).
    var count: Int = 0
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

                if count > 0 {
                    Text("\(count)")
                        .font(.system(size: 11, weight: .bold))
                        .monospacedDigit()
                        .foregroundStyle(Color.Orttaai.bgPrimary)
                        .padding(.horizontal, 6)
                        .frame(minWidth: 18, minHeight: 18)
                        .background(Capsule().fill(Color.Orttaai.accent))
                        .accessibilityLabel("\(count) suggestions waiting")
                }
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

/// Suggestions waiting in Memory, kept current as they are added or decided.
@MainActor
private final class PendingSuggestionCount: ObservableObject {
    @Published private(set) var count = 0
    private var observer: NSObjectProtocol?
    private let database = try? DatabaseManager()

    init() {
        refresh()
        observer = NotificationCenter.default.addObserver(forName: .personalMemoryDidChange, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    private func refresh() {
        count = (try? database?.pendingLearningSuggestionCount()) ?? 0
    }
}

/// Page headers live in the transparent toolbar strip. Clipping the page to
/// its own area keeps scrolled content from drawing up under the title.
private struct SolidHeaderScrollEdge: ViewModifier {
    func body(content: Content) -> some View {
        content.clipped()
    }
}
