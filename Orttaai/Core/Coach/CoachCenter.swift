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
    /// The rep in progress, shown full screen in the Studio.
    @Published private(set) var activeSession: CoachPracticeSession?

    /// A roleplay scene in progress, shown full screen.
    @Published private(set) var activeScene: CoachSceneSession?

    /// The last three weeks of counted dictations, for picking redos.
    fileprivate(set) var recentInputs: [CoachInput] = []
    /// The two shape windows of dictations, by way of talking, for judging.
    fileprivate var shapeSamples: [DatedMeasures] = []
    fileprivate var isJudging = false

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
        startHabit(.measure(pick.measure), mode: pick.mode)
    }

    func startHabit(_ target: CoachHabitTarget, mode: CoachMode?) {
        guard let database else { return }
        do {
            try database.startCoachHabit(target: target, mode: mode)
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

    // MARK: Practice

    /// Sets up a rep and opens it in the Studio.
    func beginRep(_ skill: CoachSkill, kind: CoachRepKind, spoken: Bool) async {
        let overrides = CoachPreferences.overrides
        var kind = kind
        var source: CoachQuote?
        if kind == .redo {
            if let id = CoachRepPlanner.redoSource(skill: skill, inputs: recentInputs, overrides: overrides),
               let quote = try? database?.fetchCoachQuotes(ids: [id])[id] {
                source = quote
            } else {
                kind = .drill
            }
        }
        let mode = skill.track.mode ?? snapshot?.busiestMode
        let plan = CoachRepPlan(
            skill: skill,
            kind: kind,
            spoken: spoken,
            instruction: CoachRepPlanner.instruction(skill: skill, kind: kind, hasSource: source != nil),
            source: source,
            persona: CoachPreferences.persona(for: mode)
        )
        activeSession?.cancel()
        activeSession = CoachPracticeSession(
            plan: plan,
            database: database,
            progress: snapshot?.progress(skill),
            usualSummary: snapshot?.shape(for: mode).nowSummary
        )
    }

    /// The next rep: the same skill, set up another way.
    func nextRep(after plan: CoachRepPlan) async {
        let order: [CoachRepKind] = [.redo, .drill, .timed]
        let next = order[((order.firstIndex(of: plan.kind) ?? 0) + 1) % order.count]
        await beginRep(plan.skill, kind: next, spoken: activeSession?.spoken ?? plan.spoken)
    }

    func endRep() {
        activeSession?.cancel()
        CoachVoice.shared.stop()
        activeSession = nil
    }

    /// Up to `limit` recent dictations in your busiest way of talking, for
    /// comparing judges. Read live; never kept.
    func comparisonSample(limit: Int = 20) -> (question: CoachQuestion, texts: [String]) {
        let mode = snapshot?.busiestMode ?? .ai
        let question: CoachQuestion = CoachTrack.track(for: mode).checks.compactMap {
            if case .judged(let q) = $0 { return q } else { return nil }
        }.first ?? .taskFirst
        let overrides = CoachPreferences.overrides
        let ids = recentInputs.reversed().filter { input in
            input.measures.words >= 12
                && CoachAppCatalog.mode(bundleID: input.bundleID, appName: input.appName, overrides: overrides) == mode
        }.prefix(limit).map(\.id)
        let texts = ids.compactMap { try? database?.fetchCoachText(id: $0) }
        return (question, texts)
    }

    // MARK: Scenes

    func beginScene(_ scene: CoachScene) {
        activeSession?.cancel()
        activeSession = nil
        activeScene?.cancel()
        let track = scene.track
        let skill = snapshot?.currentSkill(in: track) ?? track.skills[0]
        let mode = track.mode ?? snapshot?.busiestMode
        activeScene = CoachSceneSession(
            scene: scene,
            skill: skill,
            persona: CoachPreferences.persona(for: mode),
            database: database,
            usual: snapshot?.progress(skill).usual
        )
    }

    func endScene() {
        activeScene?.cancel()
        CoachVoice.shared.stop()
        activeScene = nil
    }

    // MARK: Month report

    /// The report for the calendar month holding `date`, worked out off the
    /// main thread from the stored counts, reps and answers.
    func monthReport(for date: Date) async -> CoachMonthReport? {
        guard let database else { return nil }
        let overrides = CoachPreferences.overrides
        let judgeModel = CoachModels.current().judgeModel
        return try? await Task.detached(priority: .userInitiated) {
            CoachMonthReportBuilder.build(
                month: date,
                inputs: try database.fetchCoachInputs(),
                habits: try database.fetchCoachHabits(),
                reps: try database.fetchCoachReps(),
                scores: try database.fetchCoachJudgementScores(model: judgeModel),
                overrides: overrides,
                quotes: { ids in (try? database.fetchCoachQuotes(ids: ids)) ?? [:] }
            )
        }.value
    }

    // MARK: Evaluation

    fileprivate func scheduleRefresh(after delay: Duration = .milliseconds(600)) {
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
        let judgeModel = CoachModels.current().judgeModel
        do {
            let built = try await Task.detached(priority: .utility) {
                try CoachIndexer.catchUp(database: database, skippingKeys: offKeys)
                let inputs = try database.fetchCoachInputs()
                let habits = try database.fetchCoachHabits()
                let apps = try database.fetchCoachApps()
                let reps = try database.fetchCoachReps()
                let scores = try database.fetchCoachJudgementScores(model: judgeModel)
                let judgements = scores.mapValues { $0.mapValues { $0 == JudgeAnswer.yes.points } }
                let snapshot = CoachSnapshotBuilder.build(
                    inputs: inputs,
                    habits: habits,
                    apps: apps,
                    overrides: overrides,
                    reps: reps,
                    judgements: judgements,
                    axisJudgements: scores,
                    quotes: { ids in (try? database.fetchCoachQuotes(ids: ids)) ?? [:] }
                )
                let since = Date().addingTimeInterval(-21 * 86_400)
                let shapeStart = Date().addingTimeInterval(-Double(CoachShape.days * 2 + 1) * 86_400)
                let samples: [DatedMeasures] = inputs.compactMap { input in
                    guard input.createdAt >= shapeStart,
                          let mode = CoachAppCatalog.mode(bundleID: input.bundleID, appName: input.appName, overrides: overrides) else { return nil }
                    return DatedMeasures(id: input.id, createdAt: input.createdAt, mode: mode, measures: input.measures)
                }
                return (snapshot, inputs.filter { $0.createdAt >= since }, samples)
            }.value
            recentInputs = built.1
            shapeSamples = built.2
            if built.0 != snapshot { snapshot = built.0 }
        } catch {
            Logger.database.error("Coach evaluation failed: \(error.localizedDescription)")
        }
        hasLoaded = true
        judgeInBackground()

        if needsAnotherPass {
            needsAnotherPass = false
            await evaluate()
        }
    }
}

// MARK: - Background judging

extension CoachCenter {
    /// Asks the judge about real dictations: first for habits on judged
    /// skills (the 20 before each started and every one since), then to fill
    /// the judged axes of the voice shape. At most 10 a pass and 40 a day,
    /// only while the server is up and Coach is idle, each answer cached.
    func judgeInBackground() {
        guard !isJudging, let database, let snapshot, activeSession == nil, activeScene == nil else { return }
        let judged = snapshot.habits.compactMap { state -> (CoachQuestion, CoachMode?, Date)? in
            if case .question(let q) = state.target { return (q, state.mode, state.habit.startedAt) }
            return nil
        }
        let samples = shapeSamples
        let modes = CoachMode.shaped.sorted { (snapshot.recentByMode[$0] ?? 0) > (snapshot.recentByMode[$1] ?? 0) }
        let overrides = CoachPreferences.overrides
        let inputs = recentInputs
        isJudging = true
        Task.detached(priority: .background) { [weak self] in
            let setup = CoachModels.current()
            var asked = 0
            defer { Task { @MainActor [weak self] in self?.finishJudgingPass(asked: asked) } }
            guard await CoachModels.installed(setup)?.contains(setup.judgeModel) == true else { return }
            let dayStart = Calendar.current.startOfDay(for: Date())
            let budget = min(10, 40 - ((try? database.countCoachJudgements(since: dayStart)) ?? 40))
            guard budget > 0 else { return }
            let known = (try? database.fetchCoachJudgementScores(model: setup.judgeModel)) ?? [:]

            var queue: [(question: CoachQuestion, id: Int64)] = []
            for (question, mode, startedAt) in judged {
                let inMode = inputs.filter { input in
                    guard input.measures.words >= CoachShapeJudging.minimumWords,
                          let m = CoachAppCatalog.mode(bundleID: input.bundleID, appName: input.appName, overrides: overrides) else { return false }
                    return mode == nil || m == mode
                }
                let before = inMode.filter { $0.createdAt < startedAt }.suffix(HabitJudge.window)
                let since = inMode.filter { $0.createdAt >= startedAt }
                // Newest first since the start, then the baseline.
                queue += (Array(since.reversed()) + Array(before.reversed())).map { (question, $0.id) }
            }
            queue += CoachShapeJudging.queue(samples, modes: modes, known: known, now: Date())

            var seen: Set<String> = []
            for item in queue where known[item.question]?[item.id] == nil {
                guard asked < budget else { return }
                guard seen.insert("\(item.question.rawValue)-\(item.id)").inserted,
                      let text = try? database.fetchCoachText(id: item.id),
                      let verdict = await CoachModels.judge(item.question, text: text, context: nil, setup: setup) else { continue }
                try? database.saveCoachJudgement(transcriptionId: item.id, question: item.question, model: setup.judgeModel, answer: verdict.answer, confidence: verdict.confidence)
                asked += 1
            }
        }
    }

    fileprivate func finishJudgingPass(asked: Int) {
        isJudging = false
        if asked > 0 { scheduleRefresh() }
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
