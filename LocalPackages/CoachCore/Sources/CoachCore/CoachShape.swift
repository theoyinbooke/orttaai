// CoachShape.swift
// CoachCore
//
// The voice shape: six axes from 0 to 1 for the last 28 days, drawn over the
// 28 days before. Counted axes come from the dictations' counts; judged
// axes from the judge's answers about them.

import Foundation

/// A dictation's counts with when and how it was said.
public struct DatedMeasures: Sendable {
    public var id: Int64
    public var createdAt: Date
    public var mode: CoachMode
    public var measures: DictationMeasures

    public init(id: Int64, createdAt: Date, mode: CoachMode, measures: DictationMeasures) {
        self.id = id
        self.createdAt = createdAt
        self.mode = mode
        self.measures = measures
    }
}

public struct CoachShape: Sendable, Equatable {
    public static let days = 28

    /// nil is every mode together.
    public var mode: CoachMode?
    /// The six axes drawn for this mode.
    public var axes: [CoachAxis]
    /// Axes with enough dictations to draw.
    public var nowAxes: [CoachAxis: Double]
    public var thenAxes: [CoachAxis: Double]
    /// Every counted measure, drawn or not, for picking a focus.
    public var now: [CoachMeasure: Double]
    public var then: [CoachMeasure: Double]
    public var nowSummary: CoachSummary
    public var thenSummary: CoachSummary
    /// The axis that grew most, when one grew by at least 3 points.
    public var biggestGain: CoachAxis?

    public var isComplete: Bool { axes.allSatisfy { nowAxes[$0] != nil } }
    public var thenIsComplete: Bool { axes.allSatisfy { thenAxes[$0] != nil } }

    /// Only judged axes are still missing.
    public var waitsOnJudge: Bool {
        !isComplete && axes.allSatisfy { nowAxes[$0] != nil || $0.isJudged }
    }

    /// Each axis's change from then to now, largest first, where both are known.
    public var changes: [(axis: CoachAxis, change: Double)] {
        axes.compactMap { axis -> (axis: CoachAxis, change: Double)? in
            guard let n = nowAxes[axis], let t = thenAxes[axis] else { return nil }
            return (axis, n - t)
        }
        .sorted { abs($0.change) > abs($1.change) }
    }

    /// The last 28 days against the 28 before.
    public static func make(
        _ samples: [DatedMeasures],
        mode: CoachMode?,
        now date: Date,
        judgements: [CoachQuestion: [Int64: Double]] = [:],
        calendar: Calendar = .current
    ) -> CoachShape {
        let start = calendar.date(byAdding: .day, value: -days, to: date) ?? date
        let earlier = calendar.date(byAdding: .day, value: -days * 2, to: date) ?? date
        return make(
            samples,
            mode: mode,
            window: DateInterval(start: start, end: date),
            before: DateInterval(start: earlier, end: start),
            judgements: judgements
        )
    }

    /// Any window against the one before it, such as a month and the last.
    /// A dictation counts in a window when start <= createdAt < end, except
    /// that the current window also takes one made at its end.
    public static func make(
        _ samples: [DatedMeasures],
        mode: CoachMode?,
        window: DateInterval,
        before: DateInterval,
        judgements: [CoachQuestion: [Int64: Double]] = [:]
    ) -> CoachShape {
        let mine = mode.map { m in samples.filter { $0.mode == m } } ?? samples
        let recent = mine.filter { $0.createdAt >= window.start && $0.createdAt <= window.end }
        let older = mine.filter { $0.createdAt >= before.start && $0.createdAt < before.end }
        let nowSummary = CoachSummary(recent.map(\.measures))
        let thenSummary = CoachSummary(older.map(\.measures))
        var now: [CoachMeasure: Double] = [:]
        var then: [CoachMeasure: Double] = [:]
        for measure in CoachMeasure.allCases {
            now[measure] = measure.axisScore(nowSummary)
            then[measure] = measure.axisScore(thenSummary)
        }

        let axes = CoachAxis.axes(for: mode)
        var nowAxes: [CoachAxis: Double] = [:]
        var thenAxes: [CoachAxis: Double] = [:]
        for axis in axes {
            switch axis {
            case .measure(let m):
                nowAxes[axis] = now[m]
                thenAxes[axis] = then[m]
            case .question(let q):
                let answers = judgements[q] ?? [:]
                nowAxes[axis] = judgedScore(recent, answers)
                thenAxes[axis] = judgedScore(older, answers)
            }
        }

        let gain = axes
            .compactMap { a -> (CoachAxis, Double)? in
                guard let n = nowAxes[a], let t = thenAxes[a] else { return nil }
                return (a, n - t)
            }
            .filter { $0.1 >= 0.03 }
            .max { $0.1 < $1.1 }?.0
        return CoachShape(
            mode: mode,
            axes: axes,
            nowAxes: nowAxes,
            thenAxes: thenAxes,
            now: now,
            then: then,
            nowSummary: nowSummary,
            thenSummary: thenSummary,
            biggestGain: gain
        )
    }

    /// The average answer over the judged dictations, once there are enough.
    static func judgedScore(_ samples: [DatedMeasures], _ answers: [Int64: Double]) -> Double? {
        let scores = samples.compactMap { answers[$0.id] }
        guard scores.count >= CoachMeasure.minimumSamples else { return nil }
        return scores.reduce(0, +) / Double(scores.count)
    }
}

/// Which dictations to ask the judge about so the judged axes fill in: up
/// to `perWindow` per axis in the last 28 days, then in the 28 before, the
/// busiest way of talking first, axes taking turns.
public enum CoachShapeJudging {
    public static let perWindow = 12
    /// Shorter dictations aren't worth a judge's time.
    public static let minimumWords = 8

    public static func queue(
        _ samples: [DatedMeasures],
        modes: [CoachMode],
        known: [CoachQuestion: [Int64: Double]],
        now date: Date,
        calendar: Calendar = .current
    ) -> [(question: CoachQuestion, id: Int64)] {
        let start = calendar.date(byAdding: .day, value: -CoachShape.days, to: date) ?? date
        let earlier = calendar.date(byAdding: .day, value: -CoachShape.days * 2, to: date) ?? date
        // The same windows as the shape: the latest includes its end.
        let windows: [(Date) -> Bool] = [{ $0 >= start && $0 <= date }, { $0 >= earlier && $0 < start }]
        let newestFirst = samples
            .filter { $0.measures.words >= minimumWords }
            .sorted { $0.createdAt > $1.createdAt }
        var queue: [(question: CoachQuestion, id: Int64)] = []
        for inWindow in windows {
            for mode in modes {
                let candidates = newestFirst.filter { $0.mode == mode && inWindow($0.createdAt) }
                let lists: [[(question: CoachQuestion, id: Int64)]] = CoachAxis.questions(for: mode).map { question in
                    let answers = known[question] ?? [:]
                    let have = candidates.filter { answers[$0.id] != nil }.count
                    return candidates
                        .filter { answers[$0.id] == nil }
                        .prefix(max(0, perWindow - have))
                        .map { (question, $0.id) }
                }
                let longest = lists.map(\.count).max() ?? 0
                for index in 0..<longest {
                    for list in lists where index < list.count {
                        queue.append(list[index])
                    }
                }
            }
        }
        return queue
    }
}
