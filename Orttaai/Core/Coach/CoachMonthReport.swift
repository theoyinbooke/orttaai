// CoachMonthReport.swift
// Orttaai
//
// A calendar month looked back on: how much you dictated, your voice shape
// against the month before, what moved, the practice you did, where each
// habit stood at the month's end, and the month's best moment.

import CoachCore
import Foundation

nonisolated struct CoachMonthMove: Sendable, Equatable, Identifiable {
    var axis: CoachAxis
    var mode: CoachMode?
    var now: Double
    var then: Double

    var change: Double { now - then }
    var id: String { axis.id + "-" + (mode?.rawValue ?? "all") }
}

nonisolated struct CoachMonthTrack: Sendable, Equatable, Identifiable {
    var track: CoachTrack
    var reps: Int
    var mastered: [CoachSkill]

    var id: CoachTrack { track }
}

nonisolated struct CoachMonthBestRep: Sendable, Equatable {
    var skill: CoachSkill
    var score: Double
    var createdAt: Date
}

nonisolated struct CoachMonthReport: Sendable, Equatable {
    /// The calendar month; its end is the first moment of the next.
    var month: DateInterval
    var previous: DateInterval
    /// Still running: the month we're in.
    var isCurrent: Bool
    /// The first month there's anything to look back on, for stepping back.
    var firstMonth: Date?

    var dictations: Int
    var words: Int
    var daysDictated: Int
    var reps: Int
    var dictationsBefore: Int

    /// nil is every way of talking.
    var shapes: [CoachMode: CoachShape]
    var allShape: CoachShape
    /// Every axis that moved by 3 points or more, gains first, by lens.
    var moves: [CoachMonthMove]

    var tracks: [CoachMonthTrack]
    var bestRep: CoachMonthBestRep?
    /// Habits that ran during the month, judged on dictations up to its end.
    var habits: [CoachHabitState]
    /// A dictation that met the month's top gain.
    var bestMoment: CoachQuote?
    var bestMomentAxis: CoachAxis?

    var isEmpty: Bool { dictations == 0 && reps == 0 }

    var masteredCount: Int { tracks.reduce(0) { $0 + $1.mastered.count } }

    func shape(for mode: CoachMode?) -> CoachShape {
        mode.flatMap { shapes[$0] } ?? allShape
    }

    func moves(for mode: CoachMode?) -> [CoachMonthMove] {
        moves.filter { $0.mode == mode }
    }

    /// The biggest gain anywhere, for the headline.
    var topGain: CoachMonthMove? {
        moves.filter { $0.change > 0 }.max { $0.change < $1.change }
    }
}

nonisolated enum CoachMonthReportBuilder {
    /// The smallest change worth reporting, in axis points.
    static let notableChange = 0.03

    static func build(
        month date: Date,
        inputs: [CoachInput],
        habits: [CoachHabitRecord],
        reps: [CoachRepRecord],
        scores: [CoachQuestion: [Int64: Double]],
        overrides: [String: CoachAppRule],
        quotes: ([Int64]) -> [Int64: CoachQuote],
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> CoachMonthReport {
        let month = calendar.dateInterval(of: .month, for: date) ?? DateInterval(start: date, duration: 0)
        let previousStart = calendar.date(byAdding: .month, value: -1, to: month.start) ?? month.start
        let previous = DateInterval(start: previousStart, end: month.start)
        let isCurrent = month.contains(now) && now < month.end

        let dated: [DatedMeasures] = inputs.compactMap { input in
            guard input.createdAt < month.end,
                  let mode = CoachAppCatalog.mode(bundleID: input.bundleID, appName: input.appName, overrides: overrides) else { return nil }
            return DatedMeasures(id: input.id, createdAt: input.createdAt, mode: mode, measures: input.measures)
        }
        let inMonth = dated.filter { $0.createdAt >= month.start }
        let window = DateInterval(start: month.start, end: max(month.start, min(now, month.end)))

        var shapes: [CoachMode: CoachShape] = [:]
        for mode in CoachMode.shaped {
            shapes[mode] = CoachShape.make(dated, mode: mode, window: window, before: previous, judgements: scores)
        }
        let allShape = CoachShape.make(dated, mode: nil, window: window, before: previous, judgements: scores)

        var moves: [CoachMonthMove] = []
        let lenses: [(CoachMode?, CoachShape)] = [(nil, allShape)] + CoachMode.shaped.compactMap { mode in shapes[mode].map { (mode, $0) } }
        for (mode, shape) in lenses {
            for axis in shape.axes {
                guard let n = shape.nowAxes[axis], let t = shape.thenAxes[axis], abs(n - t) >= notableChange else { continue }
                moves.append(CoachMonthMove(axis: axis, mode: mode, now: n, then: t))
            }
        }
        moves.sort { $0.change > $1.change }

        // Practice: reps by track, and skills whose mastering rep fell in the month.
        let monthReps = reps.filter { month.contains($0.createdAt) && $0.createdAt < month.end }
        var masteredAt: [String: Date] = [:]
        var strong: [String: Int] = [:]
        for rep in reps.sorted(by: { $0.createdAt < $1.createdAt }) where (rep.score ?? 0) >= CoachScore.masteryScore && rep.skillMet == true {
            strong[rep.skillID, default: 0] += 1
            if strong[rep.skillID] == CoachScore.repsToMaster { masteredAt[rep.skillID] = rep.createdAt }
        }
        let tracks: [CoachMonthTrack] = CoachTrack.allCases.map { track in
            let skills = track.skills
            let ids = Set(skills.map(\.id))
            let mastered = skills.filter { skill in
                masteredAt[skill.id].map { $0 >= month.start && $0 < month.end } ?? false
            }
            return CoachMonthTrack(track: track, reps: monthReps.filter { ids.contains($0.skillID) }.count, mastered: mastered)
        }
        let bestRep = monthReps
            .compactMap { rep -> CoachMonthBestRep? in
                guard let skill = rep.skill, let score = rep.score else { return nil }
                return CoachMonthBestRep(skill: skill, score: score, createdAt: rep.createdAt)
            }
            .max { $0.score < $1.score }

        // Habits that ran during the month, as they stood at its end.
        let judged = scores.mapValues { $0.mapValues { $0 == JudgeAnswer.yes.points } }
        let habitStates: [CoachHabitState] = habits.compactMap { habit in
            guard let target = habit.target, habit.startedAt < month.end, (habit.endedAt ?? .distantFuture) >= month.start else { return nil }
            let verdict = CoachSnapshotBuilder.habitVerdict(habit, target: target, dated: dated, judgements: judged)
            return CoachHabitState(habit: habit, target: target, mode: habit.coachMode, verdict: verdict, example: nil)
        }

        // The best moment: the latest dictation in the month that met the top gain.
        let topGain = moves.filter { $0.change > 0 }.max { $0.change < $1.change }
        var momentID: Int64?
        if let gain = topGain {
            let pool = inMonth.filter { (gain.mode == nil || $0.mode == gain.mode) && $0.measures.words >= 12 }
            switch gain.axis {
            case .measure(let measure):
                momentID = pool.last { measure.isHit($0.measures) == true }?.id
            case .question(let question):
                let answers = scores[question] ?? [:]
                momentID = pool.last { answers[$0.id] == JudgeAnswer.yes.points }?.id
            }
        }
        let found = momentID.map { quotes([$0]) } ?? [:]

        let firstDictation = inputs.map(\.createdAt).min()
        let firstRep = reps.map(\.createdAt).min()
        let first = [firstDictation, firstRep].compactMap { $0 }.min()

        return CoachMonthReport(
            month: month,
            previous: previous,
            isCurrent: isCurrent,
            firstMonth: first.flatMap { calendar.dateInterval(of: .month, for: $0)?.start },
            dictations: inMonth.count,
            words: inMonth.reduce(0) { $0 + $1.measures.words },
            daysDictated: Set(inMonth.map { calendar.startOfDay(for: $0.createdAt) }).count,
            reps: monthReps.count,
            dictationsBefore: dated.filter { previous.contains($0.createdAt) && $0.createdAt < previous.end }.count,
            shapes: shapes,
            allShape: allShape,
            moves: moves,
            tracks: tracks,
            bestRep: bestRep,
            habits: habitStates,
            bestMoment: momentID.flatMap { found[$0] },
            bestMomentAxis: momentID == nil ? nil : topGain?.axis
        )
    }
}
