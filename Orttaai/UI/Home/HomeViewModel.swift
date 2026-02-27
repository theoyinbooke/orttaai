// HomeViewModel.swift
// Orttaai

import Foundation
import os
import GRDB
import AppKit

enum GitHubStarPromptStep: String, Identifiable {
    case enjoyment
    case star

    var id: String { rawValue }
}

@MainActor
@Observable
final class HomeViewModel {
    private(set) var payload: DashboardStatsPayload = .empty
    private(set) var isLoading = false
    private(set) var hasLoaded = false
    private(set) var isApplyingFastFirstUpgrade = false
    private(set) var isInsightsPanelVisible = false
    private(set) var isGeneratingInsights = false
    private(set) var insightsRequest: WritingInsightsRequest = .default
    private(set) var insightsAvailableApps: [String] = []
    private(set) var insightsHistoryItems: [WritingInsightHistoryItem] = []
    private(set) var insightsSelectedHistoryID: Int64?
    private(set) var insightsCompareItemIDs: [Int64] = []
    private(set) var insightsComparison: WritingInsightsComparison?
    private(set) var insightsFreshness: WritingInsightFreshness?
    private(set) var appliedInsightRecommendations: Set<String> = []
    private(set) var fastFirstRecommendedModelId: String?
    private(set) var fastFirstPrefetchReady = false
    private(set) var githubStarPromptStep: GitHubStarPromptStep?
    private(set) var insightsSnapshot: WritingInsightSnapshot?
    var errorMessage: String?
    var insightsErrorMessage: String?
    var insightsStatusMessage: String?

    private let statsService: DashboardStatsService?
    private let insightsService: WritingInsightsService?
    private let settings: AppSettings
    private var observation: DatabaseCancellable?
    private let githubStarPromptCooldown: TimeInterval = 7 * 24 * 60 * 60
    private let githubStarPromptMinimumSessions = 3
    private let githubStarPromptMinimumWords = 200
    private let githubStarPromptMaxShows = 3
    private var hasLoadedInsightsContext = false
    private var lastAutoRefreshHistoryID: Int64?

    init(
        statsService: DashboardStatsService?,
        insightsService: WritingInsightsService?,
        settings: AppSettings
    ) {
        self.statsService = statsService
        self.insightsService = insightsService
        self.settings = settings
        refreshFastFirstState()
    }

    convenience init() {
        self.init(
            statsService: HomeViewModel.makeDefaultStatsService(),
            insightsService: HomeViewModel.makeDefaultInsightsService(),
            settings: AppSettings()
        )
    }

    var shouldShowFastFirstUpgradePrompt: Bool {
        guard fastFirstPrefetchReady else { return false }
        guard let recommendedModelId = fastFirstRecommendedModelId else { return false }
        guard !settings.fastFirstUpgradeDismissed else { return false }
        return currentModelIdForComparison() != ModelManager.normalizedModelID(recommendedModelId)
    }

    var fastFirstRecommendedModelDisplayName: String {
        guard let id = fastFirstRecommendedModelId else { return "Recommended model" }
        return HomeViewModel.formatModelDisplayName(id)
    }

    func load() {
        guard !isLoading else { return }
        guard let statsService else {
            errorMessage = "Couldn't load dashboard data."
            hasLoaded = true
            refreshFastFirstState()
            return
        }

        isLoading = true
        defer {
            isLoading = false
            hasLoaded = true
        }

        do {
            let activeModelId = settings.activeModelId.trimmingCharacters(in: .whitespacesAndNewlines)
            payload = try statsService.load(
                currentModelId: activeModelId.isEmpty ? nil : activeModelId
            )
            errorMessage = nil
        } catch {
            payload = .empty
            errorMessage = "Couldn't load dashboard data."
            Logger.database.error("Dashboard load failed: \(error.localizedDescription)")
        }

        refreshFastFirstState()
        startObservingIfNeeded()
        evaluateGitHubStarPromptIfNeeded()
    }

    func refresh() {
        load()
    }

    func evaluateGitHubStarPromptIfNeeded() {
        guard githubStarPromptStep == nil else { return }
        guard hasLoaded else { return }
        guard !settings.githubStarPromptCompleted else { return }

        let hasEnoughUsage = payload.today.sessions >= githubStarPromptMinimumSessions ||
            payload.header.words7d >= githubStarPromptMinimumWords
        guard hasEnoughUsage else { return }

        if settings.githubStarPromptShownCount >= githubStarPromptMaxShows {
            settings.githubStarPromptCompleted = true
            return
        }

        let now = Date().timeIntervalSince1970
        if settings.githubStarPromptLastShownAtEpoch > 0,
           now - settings.githubStarPromptLastShownAtEpoch < githubStarPromptCooldown
        {
            return
        }

        settings.githubStarPromptShownCount += 1
        settings.githubStarPromptLastShownAtEpoch = now
        githubStarPromptStep = .enjoyment
    }

    func respondToEnjoymentPrompt(enjoying: Bool) {
        guard githubStarPromptStep == .enjoyment else { return }
        if enjoying {
            githubStarPromptStep = .star
        } else {
            githubStarPromptStep = nil
        }
    }

    func starOnGitHub() {
        settings.githubStarPromptCompleted = true
        githubStarPromptStep = nil
        NSWorkspace.shared.open(AppLinks.githubRepositoryURL)
    }

    func maybeLaterForGitHubPrompt() {
        githubStarPromptStep = nil
    }

    func dismissGitHubPromptPermanently() {
        settings.githubStarPromptCompleted = true
        githubStarPromptStep = nil
    }

    func clearGitHubPromptState() {
        githubStarPromptStep = nil
    }

    func toggleInsightsPanel() {
        setInsightsPanelVisible(!isInsightsPanelVisible)
    }

    func setInsightsPanelVisible(_ isVisible: Bool) {
        isInsightsPanelVisible = isVisible
        guard isVisible else { return }
        loadInsightsContextIfNeeded()
    }

    func refreshInsights() {
        generateInsights(force: true)
    }

    func loadInsightsSnapshotFromHistory(_ item: WritingInsightHistoryItem) {
        insightsSnapshot = item.snapshot
        insightsRequest = item.snapshot.request
        insightsSelectedHistoryID = item.id
        appliedInsightRecommendations = []
        mergeSelectedAppsIntoAvailableList()
        insightsStatusMessage = "Loaded snapshot from \(item.snapshot.generatedAt.formatted(date: .abbreviated, time: .shortened))."
        insightsErrorMessage = nil

        if let insightsService {
            refreshInsightsFreshness(using: insightsService)
            maybeAutoRefreshInsights(using: insightsService)
        }
    }

    func toggleInsightsHistoryPin(_ item: WritingInsightHistoryItem) {
        guard let insightsService else { return }
        do {
            try insightsService.setSnapshotPinned(id: item.id, isPinned: !item.isPinned)
            refreshInsightsHistory(using: insightsService)
            recomputeInsightsComparison()
            insightsStatusMessage = item.isPinned ? "Removed pin." : "Pinned to top."
            insightsErrorMessage = nil
        } catch {
            insightsErrorMessage = error.localizedDescription
        }
    }

    func deleteInsightsHistoryItem(_ item: WritingInsightHistoryItem) {
        guard let insightsService else { return }
        do {
            _ = try insightsService.deleteSnapshot(id: item.id)

            if insightsSelectedHistoryID == item.id {
                insightsSelectedHistoryID = nil
                insightsSnapshot = nil
            }
            insightsCompareItemIDs.removeAll { $0 == item.id }

            refreshInsightsHistory(using: insightsService)
            recomputeInsightsComparison()

            if insightsSnapshot == nil, let fallback = insightsHistoryItems.first {
                loadInsightsSnapshotFromHistory(fallback)
            } else {
                insightsStatusMessage = "Deleted snapshot."
                insightsErrorMessage = nil
                if insightsSnapshot == nil {
                    insightsFreshness = nil
                } else {
                    refreshInsightsFreshness(using: insightsService)
                }
            }
        } catch {
            insightsErrorMessage = error.localizedDescription
        }
    }

    func toggleInsightsCompareItem(_ item: WritingInsightHistoryItem) {
        if let index = insightsCompareItemIDs.firstIndex(of: item.id) {
            insightsCompareItemIDs.remove(at: index)
            recomputeInsightsComparison()
            insightsStatusMessage = "Removed from compare."
            return
        }

        if insightsCompareItemIDs.count == 2 {
            insightsCompareItemIDs.removeFirst()
        }
        insightsCompareItemIDs.append(item.id)
        recomputeInsightsComparison()

        if insightsComparison != nil {
            insightsStatusMessage = "Comparison updated."
        } else {
            insightsStatusMessage = "Select one more snapshot to compare."
        }
    }

    func clearInsightsComparison() {
        insightsCompareItemIDs = []
        insightsComparison = nil
        insightsStatusMessage = "Comparison cleared."
    }

    func setInsightsTimeRange(_ timeRange: WritingInsightsTimeRange) {
        guard insightsRequest.timeRange != timeRange else { return }
        insightsRequest.timeRange = timeRange
        insightsStatusMessage = "Range updated. Click Regenerate to refresh."
    }

    func setInsightsGenerationMode(_ mode: WritingInsightsGenerationMode) {
        guard insightsRequest.generationMode != mode else { return }
        insightsRequest.generationMode = mode
        insightsStatusMessage = "Mode updated. Click Regenerate to refresh."
    }

    func setInsightsAppFilterMode(_ mode: WritingInsightsAppFilterMode) {
        guard insightsRequest.appFilterMode != mode else { return }
        insightsRequest.appFilterMode = mode
        if mode == .allApps {
            insightsRequest.selectedApps = []
        }
        insightsStatusMessage = "App filter updated. Click Regenerate to refresh."
    }

    func toggleInsightsAppSelection(_ appName: String) {
        let trimmed = appName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        var selected = Set(insightsRequest.selectedApps)
        if selected.contains(trimmed) {
            selected.remove(trimmed)
        } else {
            selected.insert(trimmed)
        }

        insightsRequest.selectedApps = selected
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }

        if insightsRequest.appFilterMode == .allApps && !insightsRequest.selectedApps.isEmpty {
            insightsRequest.appFilterMode = .includeOnly
        }

        insightsStatusMessage = "App selection updated. Click Regenerate to refresh."
    }

    func clearInsightsAppSelection() {
        guard !insightsRequest.selectedApps.isEmpty else { return }
        insightsRequest.selectedApps = []
        if insightsRequest.appFilterMode != .allApps {
            insightsStatusMessage = "App filter cleared. Click Regenerate to refresh."
        }
    }

    func isRecommendationApplied(_ recommendation: WritingInsightRecommendation) -> Bool {
        appliedInsightRecommendations.contains(recommendation.stableKey)
    }

    func applyInsightRecommendation(_ recommendation: WritingInsightRecommendation) {
        guard let insightsService else { return }
        guard !isRecommendationApplied(recommendation) else { return }

        do {
            try insightsService.applyRecommendation(recommendation)
            appliedInsightRecommendations.insert(recommendation.stableKey)
            insightsErrorMessage = nil
            switch recommendation.kind {
            case .dictionary:
                insightsStatusMessage = "Added to dictionary: \(recommendation.source) → \(recommendation.target)"
            case .snippet:
                insightsStatusMessage = "Added snippet: \(recommendation.source)"
            }
        } catch {
            insightsErrorMessage = error.localizedDescription
        }
    }

    func copyRecentDictation(_ entry: DashboardRecentDictation) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(entry.fullText, forType: .string)
    }

    func deleteRecentDictation(id: Int64) {
        guard let statsService else { return }

        do {
            try statsService.deleteRecentDictation(id: id)
        } catch {
            errorMessage = "Couldn't delete dictation."
            Logger.database.error("Failed to delete dictation: \(error.localizedDescription)")
        }
    }

    func refreshFastFirstState() {
        let recommended = ModelManager.normalizedModelID(
            settings.fastFirstRecommendedModelId.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        fastFirstRecommendedModelId = recommended.isEmpty ? nil : recommended
        fastFirstPrefetchReady = settings.fastFirstOnboardingEnabled && settings.fastFirstPrefetchReady
    }

    func applyFastFirstUpgrade() {
        guard !isApplyingFastFirstUpgrade else { return }
        guard shouldShowFastFirstUpgradePrompt else { return }
        guard let modelId = fastFirstRecommendedModelId else { return }

        isApplyingFastFirstUpgrade = true
        errorMessage = nil

        Task {
            defer { isApplyingFastFirstUpgrade = false }

            do {
                if let manager = ModelManager.shared {
                    try await manager.switchModel(toModelId: modelId)
                } else {
                    settings.selectedModelId = modelId
                    settings.activeModelId = modelId
                }
                settings.fastFirstOnboardingEnabled = false
                settings.fastFirstUpgradeDismissed = true
                settings.fastFirstPrefetchReady = false
                refreshFastFirstState()
                refresh()
            } catch {
                errorMessage = "Couldn't switch to recommended model."
                Logger.model.error("Fast-first upgrade switch failed: \(error.localizedDescription)")
            }
        }
    }

    private func startObservingIfNeeded() {
        guard observation == nil else { return }
        guard let statsService else { return }
        observation = statsService.observeChanges { [weak self] in
            Task { @MainActor in
                self?.refresh()
            }
        }
    }

    private func generateInsights(force: Bool) {
        guard !isGeneratingInsights else { return }
        guard let insightsService else {
            insightsErrorMessage = "Couldn't initialize insights service."
            return
        }

        if !force, insightsSnapshot != nil {
            return
        }

        isGeneratingInsights = true
        insightsErrorMessage = nil
        insightsStatusMessage = nil

        Task {
            let request = self.insightsRequest
            let result = await insightsService.generateInsights(request: request)
            self.isGeneratingInsights = false

            if let errorMessage = result.errorMessage {
                self.insightsErrorMessage = errorMessage
                return
            }

            guard let snapshot = result.snapshot else {
                self.insightsStatusMessage = "No history yet to analyze."
                return
            }

            self.insightsSnapshot = snapshot
            self.appliedInsightRecommendations = []
            self.insightsSelectedHistoryID = result.persistedSnapshotID
            self.lastAutoRefreshHistoryID = nil
            self.refreshInsightsHistory(using: insightsService)
            self.refreshInsightsFreshness(using: insightsService)
            self.recomputeInsightsComparison()
            let fallbackLabel = snapshot.usedFallback ? " (fallback used)" : ""
            self.insightsStatusMessage = "Generated from \(snapshot.sampleCount) sessions using \(snapshot.analyzerName)\(fallbackLabel)."
            if let warning = result.persistenceWarning {
                self.insightsStatusMessage = "\(self.insightsStatusMessage ?? "") \(warning)"
            }
            self.insightsErrorMessage = nil
        }
    }

    private func loadInsightsContextIfNeeded() {
        guard let insightsService else {
            insightsErrorMessage = "Couldn't initialize insights service."
            return
        }

        if !hasLoadedInsightsContext {
            let availableApps = insightsService.loadAvailableApps()
            insightsAvailableApps = availableApps

            refreshInsightsHistory(using: insightsService)
            if let persistedItem = insightsHistoryItems.first {
                insightsSnapshot = persistedItem.snapshot
                insightsRequest = persistedItem.snapshot.request
                insightsSelectedHistoryID = persistedItem.id
            }
            mergeSelectedAppsIntoAvailableList()
            refreshInsightsFreshness(using: insightsService)
            recomputeInsightsComparison()

            hasLoadedInsightsContext = true
        } else {
            insightsAvailableApps = insightsService.loadAvailableApps()
            refreshInsightsHistory(using: insightsService)
            mergeSelectedAppsIntoAvailableList()
            refreshInsightsFreshness(using: insightsService)
            recomputeInsightsComparison()
        }

        if insightsSnapshot == nil {
            generateInsights(force: true)
        } else {
            maybeAutoRefreshInsights(using: insightsService)
        }
    }

    private func mergeSelectedAppsIntoAvailableList() {
        let allApps = Set(insightsAvailableApps).union(insightsRequest.selectedApps)
        insightsAvailableApps = allApps.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    private func refreshInsightsHistory(using insightsService: WritingInsightsService) {
        insightsHistoryItems = insightsService.loadRecentHistoryItems(limit: 24)
    }

    private func refreshInsightsFreshness(using insightsService: WritingInsightsService) {
        guard let snapshot = insightsSnapshot else {
            insightsFreshness = nil
            return
        }
        insightsFreshness = insightsService.freshness(for: snapshot)
    }

    private func maybeAutoRefreshInsights(using insightsService: WritingInsightsService) {
        guard let selectedID = insightsSelectedHistoryID else { return }
        guard let freshness = insightsFreshness else { return }
        guard freshness.shouldAutoRefresh else { return }
        guard lastAutoRefreshHistoryID != selectedID else { return }
        guard !isGeneratingInsights else { return }

        lastAutoRefreshHistoryID = selectedID
        insightsStatusMessage = "Found \(freshness.newSessionCount) new sessions since this insight. Regenerating..."
        generateInsights(force: true)
    }

    private func recomputeInsightsComparison() {
        guard insightsCompareItemIDs.count == 2 else {
            insightsComparison = nil
            return
        }

        let lookup = Dictionary(uniqueKeysWithValues: insightsHistoryItems.map { ($0.id, $0) })
        guard let first = lookup[insightsCompareItemIDs[0]],
              let second = lookup[insightsCompareItemIDs[1]] else {
            insightsComparison = nil
            return
        }

        let older: WritingInsightHistoryItem
        let newer: WritingInsightHistoryItem
        if first.snapshot.generatedAt <= second.snapshot.generatedAt {
            older = first
            newer = second
        } else {
            older = second
            newer = first
        }

        var bullets: [String] = []
        let sessionDelta = newer.snapshot.sampleCount - older.snapshot.sampleCount
        let deltaText = sessionDelta == 0 ? "no change" : (sessionDelta > 0 ? "+\(sessionDelta)" : "\(sessionDelta)")
        bullets.append("Sessions analyzed: \(older.snapshot.sampleCount) -> \(newer.snapshot.sampleCount) (\(deltaText)).")

        let olderOpportunitySet = Set(older.snapshot.opportunities)
        let newerOpportunitySet = Set(newer.snapshot.opportunities)
        let addedOpportunities = newerOpportunitySet.subtracting(olderOpportunitySet)
        let resolvedOpportunities = olderOpportunitySet.subtracting(newerOpportunitySet)
        if !addedOpportunities.isEmpty || !resolvedOpportunities.isEmpty {
            bullets.append("Opportunity changes: \(addedOpportunities.count) added, \(resolvedOpportunities.count) resolved.")
        }

        let olderPatternSet = Set(older.snapshot.patterns.map(\.title))
        let newerPatternSet = Set(newer.snapshot.patterns.map(\.title))
        let newPatterns = newerPatternSet.subtracting(olderPatternSet)
        if !newPatterns.isEmpty {
            bullets.append("New patterns detected: \(newPatterns.sorted().joined(separator: ", ")).")
        }

        insightsComparison = WritingInsightsComparison(
            older: older,
            newer: newer,
            headline: "Comparing \(older.snapshot.generatedAt.formatted(date: .abbreviated, time: .shortened)) vs \(newer.snapshot.generatedAt.formatted(date: .abbreviated, time: .shortened))",
            bullets: Array(bullets.prefix(4))
        )
    }

    private static func makeDefaultStatsService() -> DashboardStatsService? {
        do {
            let db = try DatabaseManager()
            return DashboardStatsService(databaseManager: db)
        } catch {
            Logger.database.error("Failed to initialize DashboardStatsService: \(error.localizedDescription)")
            return nil
        }
    }

    private static func makeDefaultInsightsService() -> WritingInsightsService? {
        do {
            let db = try DatabaseManager()
            return WritingInsightsService(databaseManager: db)
        } catch {
            Logger.database.error("Failed to initialize WritingInsightsService: \(error.localizedDescription)")
            return nil
        }
    }

    private func currentModelIdForComparison() -> String {
        let active = settings.activeModelId.trimmingCharacters(in: .whitespacesAndNewlines)
        if !active.isEmpty {
            return ModelManager.normalizedModelID(active)
        }
        return ModelManager.normalizedModelID(settings.selectedModelId.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func formatModelDisplayName(_ id: String) -> String {
        var name = id
            .replacingOccurrences(of: "openai_whisper-", with: "Whisper ")
            .replacingOccurrences(of: "openai_whisper_", with: "Whisper ")
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")

        name = name.split(separator: " ")
            .map { word in
                let w = String(word)
                if w.hasPrefix("v") && w.count <= 3 { return w.uppercased() }
                if w == "en" || w == ".en" { return "(English)" }
                return w.prefix(1).uppercased() + w.dropFirst()
            }
            .joined(separator: " ")

        return name.replacingOccurrences(of: ".(English)", with: " (English)")
    }

}
