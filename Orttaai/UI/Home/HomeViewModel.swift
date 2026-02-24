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
    var errorMessage: String?

    private let statsService: DashboardStatsService?
    private let settings: AppSettings
    private var observation: DatabaseCancellable?

    init(statsService: DashboardStatsService?, settings: AppSettings) {
        self.statsService = statsService
        self.settings = settings
    }

    convenience init() {
        self.init(
            statsService: HomeViewModel.makeDefaultStatsService(),
            settings: AppSettings()
        )
    }

    func load() {
        guard !isLoading else { return }
        guard let statsService else {
            errorMessage = "Couldn't load dashboard data."
            hasLoaded = true
            return
        }

        isLoading = true
        defer {
            isLoading = false
            hasLoaded = true
        }

        do {
            payload = try statsService.load(currentModelId: settings.selectedModelId)
            errorMessage = nil
        } catch {
            payload = .empty
            errorMessage = "Couldn't load dashboard data."
            Logger.database.error("Dashboard load failed: \(error.localizedDescription)")
        }

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

}
