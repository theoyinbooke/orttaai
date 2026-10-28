// CoachCenter.swift
// Orttaai
//
// Keeps Coach's counts current and publishes what the Coach page shows.
// Counting and working out the snapshot run off the main thread, like
// Milestones, so a dictation never waits on them.

import CoachCore
import Combine
import Foundation
import GRDB
import os

@MainActor
final class CoachCenter: ObservableObject {
    static let shared = CoachCenter()

    @Published private(set) var snapshot: CoachSnapshot?
    @Published private(set) var isEnabled = CoachPreferences.isEnabled
    @Published private(set) var hasLoaded = false

    private var database: DatabaseManager?
    private var observation: DatabaseCancellable?
    private var observers: [NSObjectProtocol] = []
    private var isEvaluating = false
    private var needsAnotherPass = false
    private var debounce: Task<Void, Never>?

    init() {}

    func start(database: DatabaseManager) {
        guard self.database == nil else { return }
        self.database = database
        observation = database.observeTranscriptions(limit: 1) { [weak self] _ in
            Task { @MainActor [weak self] in self?.scheduleRefresh() }
        }
        for name in [Notification.Name.cloudSyncDidComplete, .coachPreferencesDidChange] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.isEnabled = CoachPreferences.isEnabled
                    self.scheduleRefresh()
                }
            })
        }
    }

    func refresh() async {
        await evaluate()
    }

    func startHabit(_ pick: CoachFocusPick) {
        guard let database else { return }
        do {
            try database.startCoachHabit(measure: pick.measure, mode: pick.mode)
        } catch {
            Logger.database.error("Coach couldn't start a habit: \(error.localizedDescription)")
        }
        scheduleRefresh(after: .zero)
    }

    func endHabit(_ state: CoachHabitState) {
        guard let database, let id = state.habit.id else { return }
        do {
            try database.endCoachHabit(id: id)
        } catch {
            Logger.database.error("Coach couldn't end a habit: \(error.localizedDescription)")
        }
        scheduleRefresh(after: .zero)
    }

    /// Files an app under a way of talking, or switches it off, which also
    /// forgets what Coach counted in it.
    func setRule(_ rule: CoachAppRule, for app: CoachAppUsage) {
        let builtIn = CoachAppCatalog.builtInMode(bundleID: app.bundleID, appName: app.appName)
        let stored: CoachAppRule? = rule.rawValue == builtIn.rawValue ? nil : rule
        if rule == .off, let database {
            do {
                try database.deleteCoachMetrics(forKeys: [app.key])
            } catch {
                Logger.database.error("Coach couldn't forget an app: \(error.localizedDescription)")
            }
        }
        CoachPreferences.setRule(stored, forKey: app.key)
    }

    // MARK: Evaluation

    private func scheduleRefresh(after delay: Duration = .milliseconds(600)) {
        debounce?.cancel()
        debounce = Task { @MainActor [weak self] in
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard !Task.isCancelled else { return }
            await self?.evaluate()
        }
    }

    private func evaluate() async {
        guard let database else { return }
        guard CoachPreferences.isEnabled else {
            hasLoaded = true
            return
        }
        if isEvaluating {
            needsAnotherPass = true
            return
        }
        isEvaluating = true
        defer { isEvaluating = false }

        let overrides = CoachPreferences.overrides
        let offKeys = CoachPreferences.offKeys
        do {
            let built = try await Task.detached(priority: .utility) {
                try CoachIndexer.catchUp(database: database, skippingKeys: offKeys)
                let inputs = try database.fetchCoachInputs()
                let habits = try database.fetchCoachHabits()
                let apps = try database.fetchCoachApps()
                return CoachSnapshotBuilder.build(
                    inputs: inputs,
                    habits: habits,
                    apps: apps,
                    overrides: overrides,
                    quotes: { ids in (try? database.fetchCoachQuotes(ids: ids)) ?? [:] }
                )
            }.value
            if built != snapshot { snapshot = built }
        } catch {
            Logger.database.error("Coach evaluation failed: \(error.localizedDescription)")
        }
        hasLoaded = true

        if needsAnotherPass {
            needsAnotherPass = false
            await evaluate()
        }
    }
}

/// Counts dictations that have no counts yet, newest first, in batches.
nonisolated enum CoachIndexer {
    static let batchSize = 500

    static func catchUp(database: DatabaseManager, skippingKeys: Set<String>) throws {
        while true {
            let batch = try database.fetchCoachBacklog(skippingKeys: skippingKeys, limit: batchSize)
            guard !batch.isEmpty else { return }
            let counted = batch.map { (id: $0.id, measures: DictationMeasures(measuring: $0.dictation)) }
            try database.saveCoachMetrics(counted)
            if batch.count < batchSize { return }
        }
    }
}
