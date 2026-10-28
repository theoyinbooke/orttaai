// CoachSnapshot.swift
// Orttaai
//
// Everything Coach shows, worked out in one pass off the main thread from
// the counted dictations: a voice shape per way of talking, this week's
// focus, the habits and their proof, and a quote caught in the wild.

import CoachCore
import Foundation

/// Something worth working on: a measure, in one way of talking or all.
nonisolated struct CoachFocusPick: Sendable, Equatable, Identifiable {
    var measure: CoachMeasure
    /// nil is every way of talking.
    var mode: CoachMode?
    /// Where it stands now, in the measure's unit.
    var figure: Double?

    var id: String { measure.rawValue + "-" + (mode?.rawValue ?? "all") }
}

nonisolated struct CoachHabitState: Sendable, Equatable, Identifiable {
    var habit: CoachHabitRecord
    var measure: CoachMeasure
    var mode: CoachMode?
    var verdict: HabitVerdict
    var example: CoachQuote?

    var id: Int64 { habit.id ?? 0 }
}

nonisolated struct CoachWeekDay: Sendable, Equatable, Identifiable {
    var date: Date
    var label: String
    var dictated: Bool
    var isToday: Bool
    var isFuture: Bool

    var id: Date { date }
}

/// A recent dictation that did the thing being worked on.
nonisolated struct CoachCaught: Sendable, Equatable {
    var measure: CoachMeasure
    var quote: CoachQuote
    /// In a row, most recent first, in that way of talking.
    var streak: Int
}

nonisolated struct CoachSnapshot: Sendable, Equatable {
    /// Below this many dictations in the last 28 days a shape is still filling in.
    static let fullShapeDictations = 30

    var builtAt: Date
    /// Counted dictations, apps switched off left out.
    var dictations: Int
    var shapes: [CoachMode: CoachShape]
    var allShape: CoachShape
    /// Dictations in the last 28 days for each way of talking.
    var recentByMode: [CoachMode: Int]
    var focus: CoachFocusPick?
    /// Up to three habits worth starting, for an empty Proof.
    var suggestions: [CoachFocusPick]
    var week: [CoachWeekDay]
    var dictationsThisWeek: Int
    var wordsThisWeek: Int
    var habits: [CoachHabitState]
    var caught: CoachCaught?
    var apps: [CoachAppUsage]
    var firstDictationAt: Date?

    func shape(for mode: CoachMode?) -> CoachShape {
        mode.flatMap { shapes[$0] } ?? allShape
    }

    /// The mode with the most dictations lately, for the first lens.
    var busiestMode: CoachMode {
        CoachMode.shaped.max { (recentByMode[$0] ?? 0) < (recentByMode[$1] ?? 0) } ?? .ai
    }

    /// The best working habit this week, for the weekly card.
    var headlineHabit: CoachHabitState? {
        habits
            .filter { $0.verdict.afterShare != nil }
            .max { ($0.verdict.afterShare ?? 0) < ($1.verdict.afterShare ?? 0) }
    }
}

nonisolated enum CoachSnapshotBuilder {
    static func build(
        inputs: [CoachInput],
        habits: [CoachHabitRecord],
        apps: [CoachAppUsage],
        overrides: [String: CoachAppRule],
        quotes: ([Int64]) -> [Int64: CoachQuote],
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> CoachSnapshot {
        let dated: [DatedMeasures] = inputs.compactMap { input in
            guard let mode = CoachAppCatalog.mode(bundleID: input.bundleID, appName: input.appName, overrides: overrides) else { return nil }
            return DatedMeasures(id: input.id, createdAt: input.createdAt, mode: mode, measures: input.measures)
        }

        var shapes: [CoachMode: CoachShape] = [:]
        for mode in CoachMode.shaped {
            shapes[mode] = CoachShape.make(dated, mode: mode, now: now, calendar: calendar)
        }
        let allShape = CoachShape.make(dated, mode: nil, now: now, calendar: calendar)

        let recentStart = calendar.date(byAdding: .day, value: -CoachShape.days, to: now) ?? now
        var recentByMode: [CoachMode: Int] = [:]
        for item in dated where item.createdAt >= recentStart {
            recentByMode[item.mode, default: 0] += 1
        }

        let active = habits.filter { $0.endedAt == nil }
        let busy = Set(active.map { ($0.measure) + "-" + ($0.mode ?? "all") })
        let picks = focusPicks(shapes: shapes, recent: recentByMode).filter { !busy.contains($0.id) }

        // The week so far.
        let weekStart = calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? calendar.startOfDay(for: now)
        let today = calendar.startOfDay(for: now)
        let thisWeek = dated.filter { $0.createdAt >= weekStart }
        let daysDictated = Set(thisWeek.map { calendar.startOfDay(for: $0.createdAt) })
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.setLocalizedDateFormatFromTemplate("EEEEE")
        let week: [CoachWeekDay] = (0..<7).compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: offset, to: weekStart) else { return nil }
            let start = calendar.startOfDay(for: day)
            return CoachWeekDay(
                date: start,
                label: start == today ? "Today" : formatter.string(from: start),
                dictated: daysDictated.contains(start),
                isToday: start == today,
                isFuture: start > today
            )
        }

        // Habits, judged on the dictations in their way of talking.
        var states: [CoachHabitState] = []
        for habit in active {
            guard let measure = habit.coachMeasure else { continue }
            let mode = habit.coachMode
            let samples = dated
                .filter { mode == nil || $0.mode == mode }
                .map { HabitSample(id: $0.id, createdAt: $0.createdAt, measures: $0.measures) }
            let verdict = HabitJudge.verdict(measure: measure, startedAt: habit.startedAt, samples: samples)
            states.append(CoachHabitState(habit: habit, measure: measure, mode: mode, verdict: verdict, example: nil))
        }

        // Caught in the wild: from a habit, else from this week's focus.
        var caughtID: Int64?
        var caughtMeasure: CoachMeasure?
        var caughtMode: CoachMode?
        if let state = states.first(where: { $0.verdict.bestExampleID != nil }) {
            caughtID = state.verdict.bestExampleID
            caughtMeasure = state.measure
            caughtMode = state.mode
        } else if let focus = picks.first {
            let since = calendar.date(byAdding: .day, value: -14, to: now) ?? now
            let found = dated.last {
                $0.createdAt >= since && (focus.mode == nil || $0.mode == focus.mode)
                    && $0.measures.words >= 12 && (focus.measure.isHit($0.measures) ?? false)
            }
            caughtID = found?.id
            caughtMeasure = focus.measure
            caughtMode = focus.mode
        }

        let wanted = Set(states.compactMap(\.verdict.bestExampleID) + [caughtID].compactMap { $0 })
        let found = quotes(Array(wanted))
        for index in states.indices {
            states[index].example = states[index].verdict.bestExampleID.flatMap { found[$0] }
        }
        var caught: CoachCaught?
        if let id = caughtID, let measure = caughtMeasure, let quote = found[id] {
            let run = dated.filter { caughtMode == nil || $0.mode == caughtMode }.reversed().compactMap { measure.isHit($0.measures) }
            let streak = run.prefix { $0 }.count
            caught = CoachCaught(measure: measure, quote: quote, streak: streak)
        }

        return CoachSnapshot(
            builtAt: now,
            dictations: dated.count,
            shapes: shapes,
            allShape: allShape,
            recentByMode: recentByMode,
            focus: picks.first,
            suggestions: Array(picks.prefix(3)),
            week: week,
            dictationsThisWeek: thisWeek.count,
            wordsThisWeek: thisWeek.reduce(0) { $0 + $1.measures.words },
            habits: states,
            caught: caught,
            apps: apps,
            firstDictationAt: inputs.first?.createdAt
        )
    }

    /// Needs across the ways of talking, most needed first, one per
    /// measure; when nothing stands out, the weakest axes of the busiest
    /// mode, so there's always something to try.
    static func focusPicks(shapes: [CoachMode: CoachShape], recent: [CoachMode: Int]) -> [CoachFocusPick] {
        var scored: [(CoachFocusPick, Double)] = []
        for mode in CoachMode.shaped {
            guard let shape = shapes[mode] else { continue }
            for need in CoachFocus.needs(shape.nowSummary) {
                scored.append((CoachFocusPick(measure: need.measure, mode: mode, figure: need.measure.figure(shape.nowSummary)), need.score))
            }
        }
        scored.sort { $0.1 > $1.1 }
        var picks: [CoachFocusPick] = []
        var seen: Set<CoachMeasure> = []
        for (pick, _) in scored where !seen.contains(pick.measure) {
            picks.append(pick)
            seen.insert(pick.measure)
        }
        if picks.count < 3 {
            let busiest = CoachMode.shaped.max { (recent[$0] ?? 0) < (recent[$1] ?? 0) } ?? .ai
            if let shape = shapes[busiest] {
                let weakest = shape.now
                    .filter { $0.value < 1 && !seen.contains($0.key) }
                    .sorted { $0.value < $1.value }
                for (measure, _) in weakest where picks.count < 3 {
                    picks.append(CoachFocusPick(measure: measure, mode: busiest, figure: measure.figure(shape.nowSummary)))
                    seen.insert(measure)
                }
            }
        }
        return picks
    }
}
