// HomeViewModel.swift
// Orttaai

import Foundation
import os
import GRDB
import AppKit

@MainActor
@Observable
final class HomeViewModel {
    private(set) var payload: DashboardStatsPayload = .empty
    private(set) var isLoading = false
    private(set) var hasLoaded = false
    private(set) var isApplyingFastFirstUpgrade = false
    private(set) var fastFirstRecommendedModelId: String?
    private(set) var fastFirstPrefetchReady = false
    var errorMessage: String?

    private let statsService: DashboardStatsService?
    private let settings: AppSettings
    private var observation: DatabaseCancellable?

    init(statsService: DashboardStatsService?, settings: AppSettings) {
        self.statsService = statsService
        self.settings = settings
        refreshFastFirstState()
    }

    convenience init() {
        self.init(
            statsService: HomeViewModel.makeDefaultStatsService(),
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
    }

    func refresh() {
        load()
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

    private static func makeDefaultStatsService() -> DashboardStatsService? {
        do {
            let db = try DatabaseManager()
            return DashboardStatsService(databaseManager: db)
        } catch {
            Logger.database.error("Failed to initialize DashboardStatsService: \(error.localizedDescription)")
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
