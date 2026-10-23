// HomeView.swift
// Orttaai

import SwiftUI
import Foundation

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
        ZStack {
            Group {
                if viewModel.isLoading && !viewModel.hasLoaded {
                    HomeLoadingView()
                        .transition(reduceMotion ? .identity : .opacity)
                } else {
                    content
                        .transition(reduceMotion ? .identity : .opacity)
                }
            }
            .blur(radius: viewModel.githubStarPromptStep == nil ? 0 : 2)
            .allowsHitTesting(viewModel.githubStarPromptStep == nil)

            if let promptStep = viewModel.githubStarPromptStep {
                HomeGitHubPromptOverlay(
                    step: promptStep,
                    onEnjoying: {
                        viewModel.respondToEnjoymentPrompt(enjoying: true)
                    },
                    onMaybeLater: {
                        viewModel.maybeLaterForGitHubPrompt()
                    },
                    onStar: {
                        viewModel.starOnGitHub()
                    },
                    onDismissPermanently: {
                        viewModel.dismissGitHubPromptPermanently()
                    }
                )
                .zIndex(1)
                .accessibilityAddTraits(.isModal)
            }
        }
        .animation(
            reduceMotion ? nil : .easeOut(duration: 0.18),
            value: viewModel.hasLoaded
        )
        .background(Color.Orttaai.bgPrimary)
        .workspaceHeader("Welcome back", leading: { EmptyView() }) {
            HomeHeaderView(
                isRefreshing: viewModel.isLoading && viewModel.hasLoaded,
                isInsightsVisible: viewModel.isInsightsPanelVisible,
                onOpenHistory: onOpenHistory,
                onToggleInsights: viewModel.toggleInsightsPanel
            )
        }
        .onAppear {
            if !viewModel.hasLoaded {
                viewModel.load()
            } else {
                viewModel.refreshFastFirstState()
                viewModel.evaluateGitHubStarPromptIfNeeded()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .fastFirstUpgradeAvailabilityDidChange)) { _ in
            viewModel.refreshFastFirstState()
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Orttaai home dashboard")
    }

    private var content: some View {
        HStack(alignment: .top, spacing: Spacing.md) {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: Spacing.md) {

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

                    if let banner {
                        HomeBannerView(
                            title: banner.title,
                            buttonTitle: banner.buttonTitle,
                            isButtonDisabled: isBannerButtonDisabled,
                            onButtonTap: bannerAction
                        )
                    }

                    rowLayout(
                        left: TodaySnapshotCard(
                            snapshot: viewModel.payload.today,
                            week: Array(viewModel.payload.trend30d.suffix(7)),
                            usualWords: usualDailyWords
                        ),
                        right: PerformanceHealthCard(health: viewModel.payload.performance)
                    )

                    TrendCardView(
                        points: viewModel.payload.trend30d,
                        allTime: viewModel.payload.header,
                        showsLegend: !isCompact
                    )

                    rowLayout(
                        left: TopAppsCard(apps: viewModel.payload.topApps30d),
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
                .padding(WorkspaceLayout.contentInsets)
            }

            if viewModel.isInsightsPanelVisible {
                HomeInsightsPanel(
                    snapshot: viewModel.insightsSnapshot,
                    stats: insightStats,
                    request: viewModel.insightsRequest,
                    availableApps: viewModel.insightsAvailableApps,
                    historyItems: viewModel.insightsHistoryItems,
                    selectedHistoryID: viewModel.insightsSelectedHistoryID,
                    compareItemIDs: viewModel.insightsCompareItemIDs,
                    comparison: viewModel.insightsComparison,
                    freshness: viewModel.insightsFreshness,
                    isGenerating: viewModel.isGeneratingInsights,
                    generationStartedAt: viewModel.insightsGenerationStartedAt,
                    isPreliminary: viewModel.isInsightsPreliminary,
                    errorMessage: viewModel.insightsErrorMessage,
                    statusMessage: viewModel.insightsStatusMessage,
                    onGenerate: viewModel.refreshInsights,
                    onTimeRangeChange: viewModel.setInsightsTimeRange,
                    onGenerationModeChange: viewModel.setInsightsGenerationMode,
                    onAppFilterModeChange: viewModel.setInsightsAppFilterMode,
                    onToggleAppSelection: viewModel.toggleInsightsAppSelection,
                    onClearAppSelection: viewModel.clearInsightsAppSelection,
                    onLoadSnapshot: viewModel.loadInsightsSnapshotFromHistory,
                    onTogglePinHistory: viewModel.toggleInsightsHistoryPin,
                    onDeleteHistoryItem: viewModel.deleteInsightsHistoryItem,
                    onToggleCompareItem: viewModel.toggleInsightsCompareItem,
                    onClearComparison: viewModel.clearInsightsComparison,
                    onClose: {
                        viewModel.setInsightsPanelVisible(false)
                    }
                )
                .frame(width: isCompact ? 320 : 380)
                // Lines up with the first card instead of the page's edge.
                .padding(.top, WorkspaceLayout.contentTopPadding)
                .padding(.bottom, Spacing.md)
                .padding(.trailing, Spacing.md)
                .transition(
                    reduceMotion
                        ? .identity
                        : .move(edge: .trailing).combined(with: .opacity)
                )
            }
        }
        .animation(
            reduceMotion ? nil : .easeOut(duration: 0.2),
            value: viewModel.isInsightsPanelVisible
        )
    }

    /// What the Insights ticker cycles through, counted over the last 30 days.
    private var insightStats: [InsightStat] {
        let trend = viewModel.payload.trend30d
        let words = trend.reduce(0) { $0 + $1.words }
        let sessions = trend.reduce(0) { $0 + $1.sessions }
        let activeDays = trend.filter { $0.sessions > 0 }.count
        let wpm = viewModel.payload.header.averageWPM
        var stats: [InsightStat] = []
        if sessions > 0 {
            stats.append(InsightStat(id: "sessions", icon: "waveform", number: Double(sessions), label: sessions == 1 ? "dictation in 30 days" : "dictations in 30 days"))
        }
        if words > 0 {
            stats.append(InsightStat(id: "words", icon: "text.word.spacing", number: Double(words), label: "words in 30 days"))
        }
        if wpm > 0 {
            stats.append(InsightStat(id: "wpm", icon: "speedometer", number: Double(wpm), label: "words per minute"))
        }
        if activeDays > 0 {
            stats.append(InsightStat(id: "days", icon: "calendar", number: Double(activeDays), label: activeDays == 1 ? "active day" : "active days"))
        }
        if let app = viewModel.payload.topApps30d.first {
            stats.append(InsightStat(id: "app", icon: "macwindow", text: app.name, label: "where you dictate most · \(Int((app.sessionShare * 100).rounded()))%"))
        }
        return stats
    }

    private var isCompact: Bool {
        layoutMode == .compact
    }

    /// Average words on the other active days of the last 30, for the
    /// Today card's comparison; nil without earlier history.
    private var usualDailyWords: Int? {
        let calendar = Calendar.current
        let earlier = viewModel.payload.trend30d.filter { $0.sessions > 0 && !calendar.isDateInToday($0.dayStart) }
        guard !earlier.isEmpty else { return nil }
        return earlier.reduce(0) { $0 + $1.words } / earlier.count
    }

    /// Shown only when there is something to do; on an ordinary day the
    /// page opens straight onto the cards.
    private var banner: (title: String, buttonTitle: String)? {
        if viewModel.shouldShowFastFirstUpgradePrompt {
            return (
                "Recommended model is ready",
                viewModel.isApplyingFastFirstUpgrade ? "Applying..." : "Use Recommended Model"
            )
        }
        if !hasAnyDictation {
            return ("Start your first dictation", "Run Setup")
        }
        if viewModel.payload.performance.level == .slow {
            return ("Speed things up", "Open Model Settings")
        }
        return nil
    }

    /// Before any dictation at all, not just none today: the Today card
    /// already says when today is empty.
    private var hasAnyDictation: Bool {
        viewModel.payload.header.activeDays > 0
    }

    private var isBannerButtonDisabled: Bool {
        viewModel.shouldShowFastFirstUpgradePrompt && viewModel.isApplyingFastFirstUpgrade
    }

    private func bannerAction() {
        if viewModel.shouldShowFastFirstUpgradePrompt {
            viewModel.applyFastFirstUpgrade()
            return
        }
        if !hasAnyDictation {
            onRunSetup()
            return
        }
        if viewModel.payload.performance.level == .slow {
            onOpenModelSettings()
        }
    }

    @ViewBuilder
    private func rowLayout<Left: View, Right: View>(left: Left, right: Right) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: Spacing.md) {
                left.frame(maxWidth: .infinity)
                right.frame(maxWidth: .infinity)
            }

            VStack(spacing: Spacing.md) {
                left
                right
            }
        }
    }
}
