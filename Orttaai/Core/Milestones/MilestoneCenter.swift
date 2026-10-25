// MilestoneCenter.swift
// Orttaai

import Combine
import Foundation
import GRDB
import os

/// Where a badge stands for this person.
enum MilestoneBadgeState: Equatable {
    case unlocked(Date)
    /// Some progress: the current value and the share of the threshold.
    case inProgress(current: Int, fraction: Double)
    case locked

    var isUnlocked: Bool {
        if case .unlocked = self { return true }
        return false
    }
}

/// Keeps the badges in step with the history. It watches for new dictations,
/// replays the history off the main thread, stores any badge newly earned,
/// and tells the app which ones still need celebrating. Unlocks are stored,
/// so deleting history never takes a badge back.
@MainActor
final class MilestoneCenter: ObservableObject {
    static let shared = MilestoneCenter()

    @Published private(set) var stats = MilestoneStats()
    @Published private(set) var unlocks: [String: MilestoneUnlock] = [:]
    @Published private(set) var hasLoaded = false

    /// Called with badges earned by a dictation made in the last two
    /// minutes, newest tier first, for the corner toast.
    var onFreshUnlocks: (([MilestoneBadge]) -> Void)?

    /// A badge earned this long before it is noticed is not "just now".
    static let freshUnlockWindow: TimeInterval = 120

    private var database: DatabaseManager?
    private var observation: DatabaseCancellable?
    private var memoryObserver: NSObjectProtocol?
    private var syncObserver: NSObjectProtocol?
    private var isEvaluating = false
    private var pendingPass: Bool?
    private var hasSeenFirstChange = false

    init() {}

    func start(database: DatabaseManager) {
        guard self.database == nil else { return }
        self.database = database
        observation = database.observeTranscriptions(limit: 1) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                // The first value is the history as it stands at launch: its
                // badges are celebrated in the window, never as a toast.
                let allowToast = self.hasSeenFirstChange
                self.hasSeenFirstChange = true
                await self.evaluate(allowToast: allowToast)
            }
        }
        memoryObserver = NotificationCenter.default.addObserver(
            forName: .personalMemoryDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.evaluate(allowToast: true)
            }
        }
        // Dictations synced in from the phone or another Mac may be older
        // than the newest one watched above: count them, without toasts for
        // history that was already there.
        syncObserver = NotificationCenter.default.addObserver(
            forName: .cloudSyncDidComplete,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.evaluate(allowToast: false)
            }
        }
    }

    func refresh() async {
        await evaluate(allowToast: false)
    }

    // MARK: - Reading

    func state(for badge: MilestoneBadge) -> MilestoneBadgeState {
        if let unlock = unlocks[badge.id] {
            return .unlocked(unlock.unlockedAt)
        }
        let current = stats.value(for: badge.metric)
        guard current > 0, badge.threshold > 0 else { return .locked }
        return .inProgress(current: current, fraction: min(0.99, Double(current) / Double(badge.threshold)))
    }

    var unlockedBadges: [MilestoneBadge] {
        MilestoneCatalog.badges.filter { unlocks[$0.id] != nil }
    }

    /// Earned but not yet celebrated, oldest first.
    var badgesAwaitingCelebration: [MilestoneBadge] {
        MilestoneCatalog.badges
            .compactMap { badge -> (MilestoneBadge, Date)? in
                guard let unlock = unlocks[badge.id], unlock.celebratedAt == nil else { return nil }
                return (badge, unlock.unlockedAt)
            }
            .sorted { $0.1 < $1.1 }
            .map(\.0)
    }

    /// The next words badge, else the in-progress badge closest to done.
    var nextGoal: MilestoneBadge? {
        let open = MilestoneCatalog.badges.filter { unlocks[$0.id] == nil }
        if let words = open.first(where: { $0.metric == .words }) { return words }
        return open.max { fraction(of: $0) < fraction(of: $1) }
    }

    func fraction(of badge: MilestoneBadge) -> Double {
        switch state(for: badge) {
        case .unlocked: return 1
        case .inProgress(_, let fraction): return fraction
        case .locked: return 0
        }
    }

    func markCelebrated(_ badges: [MilestoneBadge]) {
        let ids = badges.map(\.id)
        guard let database, !ids.isEmpty else { return }
        do {
            try database.markMilestonesCelebrated(ids)
            let now = Date()
            for id in ids where unlocks[id]?.celebratedAt == nil {
                unlocks[id]?.celebratedAt = now
            }
        } catch {
            Logger.database.error("Could not mark milestones celebrated: \(error.localizedDescription)")
        }
    }

    // MARK: - Evaluating

    private func evaluate(allowToast: Bool) async {
        guard let database else { return }
        if isEvaluating {
            pendingPass = (pendingPass ?? false) || allowToast
            return
        }
        isEvaluating = true
        defer { isEvaluating = false }

        // The database lives on the main actor; only the replay, which
        // walks the whole history, runs off it.
        let outcome: Outcome?
        do {
            let inputs = try database.fetchMilestoneInputs()
            let result = await Task.detached(priority: .utility) {
                MilestoneStats.compute(
                    dictations: inputs.dictations,
                    dictionaryEntryDates: inputs.dictionaryEntryDates
                )
            }.value
            let stored = try database.fetchMilestoneUnlocks()
            let known = Set(stored.map(\.badgeID))
            let fresh = result.crossings
                .filter { !known.contains($0.key) }
                .map { MilestoneUnlock(badgeID: $0.key, unlockedAt: $0.value, celebratedAt: nil) }
            let inserted = try database.insertMilestoneUnlocks(fresh)
            outcome = Outcome(stats: result.stats, unlocks: stored + inserted, inserted: inserted)
        } catch {
            Logger.database.error("Milestone evaluation failed: \(error.localizedDescription)")
            outcome = nil
        }

        if let outcome {
            stats = outcome.stats
            unlocks = Dictionary(outcome.unlocks.map { ($0.badgeID, $0) }, uniquingKeysWith: { first, _ in first })
            hasLoaded = true
            if allowToast {
                let now = Date()
                let justEarned = outcome.inserted
                    .filter { now.timeIntervalSince($0.unlockedAt) <= Self.freshUnlockWindow }
                    .compactMap { MilestoneCatalog.badge(withID: $0.badgeID) }
                    .sorted { $0.tier > $1.tier }
                if !justEarned.isEmpty {
                    onFreshUnlocks?(justEarned)
                }
            }
        }

        if let again = pendingPass {
            pendingPass = nil
            await evaluate(allowToast: again)
        }
    }

    private struct Outcome {
        let stats: MilestoneStats
        let unlocks: [MilestoneUnlock]
        let inserted: [MilestoneUnlock]
    }
}
