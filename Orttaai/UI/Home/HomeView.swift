// HomeView.swift
// Orttaai

import SwiftUI

enum HomeLayoutMode {
    case regular
    case compact
}

struct HomeView: View {
    let onOpenSettings: () -> Void
    let onOpenModelSettings: () -> Void
    let onOpenHistory: () -> Void
    let onRunSetup: () -> Void
    let layoutMode: HomeLayoutMode

    @State private var viewModel = HomeViewModel()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(
        onOpenSettings: @escaping () -> Void,
        onOpenModelSettings: @escaping () -> Void,
        onOpenHistory: @escaping () -> Void,
        onRunSetup: @escaping () -> Void,
        layoutMode: HomeLayoutMode = .regular
    ) {
        self.onOpenSettings = onOpenSettings
        self.onOpenModelSettings = onOpenModelSettings
        self.onOpenHistory = onOpenHistory
        self.onRunSetup = onRunSetup
        self.layoutMode = layoutMode
    }

    var body: some View {
        Group {
            if viewModel.isLoading && !viewModel.hasLoaded {
                HomeLoadingView()
                    .transition(reduceMotion ? .identity : .opacity)
            } else {
                content
                    .transition(reduceMotion ? .identity : .opacity)
            }
        }
        .animation(
            reduceMotion ? nil : .easeOut(duration: 0.18),
            value: viewModel.hasLoaded
        )
        .background(Color.Orttaai.bgPrimary)
        .onAppear {
            if !viewModel.hasLoaded {
                viewModel.load()
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Orttaai home dashboard")
    }

    private var content: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: Spacing.xl) {
                HomeHeaderView(
                    stats: viewModel.payload.header,
                    isRefreshing: viewModel.isLoading && viewModel.hasLoaded,
                    isCompact: isCompact
                )

                if let errorMessage = viewModel.errorMessage {
                    Text(errorMessage)
                        .font(.Orttaai.secondary)
                        .foregroundStyle(Color.Orttaai.error)
                        .padding(.horizontal, Spacing.md)
                        .padding(.vertical, Spacing.sm)
                        .background(Color.Orttaai.errorSubtle)
                        .clipShape(RoundedRectangle(cornerRadius: CornerRadius.card))
                        .accessibilityLabel("Dashboard error: \(errorMessage)")
                }

                HomeBannerView(
                    title: bannerTitle,
                    subtitle: bannerSubtitle,
                    buttonTitle: bannerButtonTitle,
                    showsArtwork: !isCompact,
                    onButtonTap: bannerAction
                )

                rowLayout(
                    left: TodaySnapshotCard(snapshot: viewModel.payload.today),
                    right: PerformanceHealthCard(health: viewModel.payload.performance)
                )

                TrendCardView(points: viewModel.payload.trend7d, showsLegend: !isCompact)

                rowLayout(
                    left: TopAppsCard(apps: viewModel.payload.topApps7d),
                    right: QuickActionsCard(
                        onOpenSettings: onOpenSettings,
                        onOpenModelSettings: onOpenModelSettings,
                        onOpenHistory: onOpenHistory,
                        onRunSetup: onRunSetup,
                        onRefresh: viewModel.refresh
                    )
                )

                RecentDictationsCard(
                    entries: viewModel.payload.recent,
                    isCompact: isCompact,
                    onOpenHistory: onOpenHistory,
                    onCopyEntry: viewModel.copyRecentDictation,
                    onDeleteEntry: { entry in
                        viewModel.deleteRecentDictation(id: entry.id)
                    }
                )
            }
            .padding(Spacing.xxl)
        }
    }

    private var isCompact: Bool {
        layoutMode == .compact
    }

    private var bannerTitle: String {
        if viewModel.payload.today.sessions == 0 {
            return "Start your first dictation"
        }
        if viewModel.payload.performance.level == .slow {
            return "Speed things up"
        }
        return "You're in a good flow"
    }

    private var bannerSubtitle: String {
        if viewModel.payload.today.sessions == 0 {
            return "Grant permissions and run a quick test to start dictating anywhere on your Mac."
        }
        if viewModel.payload.performance.level == .slow {
            return "Latency is trending high. Switch to a lighter model for faster response."
        }
        return "Orttaai is running locally on your Mac with healthy performance."
    }

    private var bannerButtonTitle: String {
        if viewModel.payload.today.sessions == 0 {
            return "Run Setup"
        }
        if viewModel.payload.performance.level == .slow {
            return "Open Model Settings"
        }
        return "Open History"
    }

    private func bannerAction() {
        if viewModel.payload.today.sessions == 0 {
            onRunSetup()
            return
        }
        if viewModel.payload.performance.level == .slow {
            onOpenModelSettings()
            return
        }
        onOpenHistory()
    }

    @ViewBuilder
    private func rowLayout<Left: View, Right: View>(left: Left, right: Right) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: Spacing.lg) {
                left.frame(maxWidth: .infinity)
                right.frame(maxWidth: .infinity)
            }

            VStack(spacing: Spacing.lg) {
                left
                right
            }
        }
    }
}
