// CoachShape.swift
// CoachCore
//
// The voice shape: six axes from 0 to 1 for the last 28 days, drawn over the
// 28 days before.

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
    /// Axes with enough dictations to draw.
    public var now: [CoachMeasure: Double]
    public var then: [CoachMeasure: Double]
    public var nowSummary: CoachSummary
    public var thenSummary: CoachSummary
    /// The axis that grew most, when one grew by at least 3 points.
    public var biggestGain: CoachMeasure?

    public var isComplete: Bool { now.count == CoachMeasure.allCases.count }

    public static func make(
        _ samples: [DatedMeasures],
        mode: CoachMode?,
        now date: Date,
        calendar: Calendar = .current
    ) -> CoachShape {
        let mine = mode.map { m in samples.filter { $0.mode == m } } ?? samples
        let start = calendar.date(byAdding: .day, value: -days, to: date) ?? date
        let earlier = calendar.date(byAdding: .day, value: -days * 2, to: date) ?? date
        let recent = mine.filter { $0.createdAt >= start && $0.createdAt <= date }.map(\.measures)
        let before = mine.filter { $0.createdAt >= earlier && $0.createdAt < start }.map(\.measures)
        let nowSummary = CoachSummary(recent)
        let thenSummary = CoachSummary(before)
        var nowScores: [CoachMeasure: Double] = [:]
        var thenScores: [CoachMeasure: Double] = [:]
        for measure in CoachMeasure.allCases {
            nowScores[measure] = measure.axisScore(nowSummary)
            thenScores[measure] = measure.axisScore(thenSummary)
        }
        let gain = CoachMeasure.allCases
            .compactMap { m -> (CoachMeasure, Double)? in
                guard let n = nowScores[m], let t = thenScores[m] else { return nil }
                return (m, n - t)
            }
            .filter { $0.1 >= 0.03 }
            .max { $0.1 < $1.1 }?.0
        return CoachShape(
            mode: mode,
            now: nowScores,
            then: thenScores,
            nowSummary: nowSummary,
            thenSummary: thenSummary,
            biggestGain: gain
        )
    }
}
