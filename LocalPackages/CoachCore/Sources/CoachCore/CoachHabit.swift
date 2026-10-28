// CoachHabit.swift
// CoachCore
//
// Whether a habit stuck: 20 dictations before it started against the latest
// 20 since, as the share that met it, with a seeded bootstrap so the answer
// is the same every time, and a comparison with the measures nobody
// practised, so a good week doesn't take the credit.

import Foundation

/// One dictation a habit is judged on.
public struct HabitSample: Sendable {
    public var id: Int64
    public var createdAt: Date
    public var measures: DictationMeasures

    public init(id: Int64, createdAt: Date, measures: DictationMeasures) {
        self.id = id
        self.createdAt = createdAt
        self.measures = measures
    }
}

public enum HabitStatus: String, Sendable, Equatable {
    /// Not enough dictations since it started, or before it, to tell yet.
    case watching
    case working
    case notMoving
}

public struct HabitVerdict: Sendable, Equatable {
    public var status: HabitStatus
    /// Met or not, oldest first, for the dots.
    public var before: [Bool]
    public var after: [Bool]
    /// Dictations since the habit started that the measure could read.
    public var sinceCount: Int
    public var beforeShare: Double?
    public var afterShare: Double?
    /// The measure's average, in its unit.
    public var beforeValue: Double?
    public var afterValue: Double?
    /// How far the share moved, in points, on the measures nobody practised.
    public var controlDrift: Double?
    /// The latest dictation since the start that met it, 12 words or more.
    public var bestExampleID: Int64?
    /// Dictations still needed before a verdict.
    public var stillNeeded: Int
}

public enum HabitJudge {
    public static let window = 20
    /// Fewer than this before the start and there's no baseline to beat.
    public static let minimumBaseline = 10
    static let resamples = 1_000

    /// `samples` are the habit's mode, in any order.
    public static func verdict(
        measure: CoachMeasure,
        startedAt: Date,
        samples: [HabitSample],
        seed: UInt64 = 0x0C0AC4
    ) -> HabitVerdict {
        verdict(
            startedAt: startedAt,
            samples: samples,
            isHit: { measure.isHit($0.measures) },
            value: { measure.value(of: $0.measures) },
            controls: CoachMeasure.allCases.filter { $0 != measure },
            seed: seed
        )
    }

    /// Any notion of met: `isHit` is nil when a dictation can't be told,
    /// and `controls` are the measures nobody practised.
    public static func verdict(
        startedAt: Date,
        samples: [HabitSample],
        isHit: (HabitSample) -> Bool?,
        value: (HabitSample) -> Double?,
        controls: [CoachMeasure],
        seed: UInt64 = 0x0C0AC4
    ) -> HabitVerdict {
        let sorted = samples.sorted { $0.createdAt < $1.createdAt }
        let readable = sorted.filter { isHit($0) != nil }
        let beforeSamples = Array(readable.filter { $0.createdAt < startedAt }.suffix(window))
        let sinceSamples = readable.filter { $0.createdAt >= startedAt }
        let afterSamples = Array(sinceSamples.suffix(window))

        let before = beforeSamples.map { isHit($0) ?? false }
        let after = afterSamples.map { isHit($0) ?? false }
        let best = sinceSamples.reversed().first { $0.measures.words >= 12 && isHit($0) == true }

        var verdict = HabitVerdict(
            status: .watching,
            before: before,
            after: after,
            sinceCount: sinceSamples.count,
            beforeShare: share(before),
            afterShare: share(after),
            beforeValue: mean(beforeSamples.compactMap(value)),
            afterValue: mean(afterSamples.compactMap(value)),
            controlDrift: nil,
            bestExampleID: best?.id,
            stillNeeded: max(0, window - sinceSamples.count)
        )

        guard before.count >= minimumBaseline, after.count >= window,
              let beforeShare = verdict.beforeShare, let afterShare = verdict.afterShare else {
            return verdict
        }

        verdict.controlDrift = controlDrift(controls: controls, before: beforeSamples, after: afterSamples, all: sorted)
        let change = afterShare - beforeShare
        let (low, _) = bootstrapInterval(before: before, after: after, seed: seed)
        let beatsDrift = change > (verdict.controlDrift ?? 0)
        verdict.status = (low > 0 && beatsDrift) ? .working : .notMoving
        return verdict
    }

    /// The other measures' change in share over the same stretches of time.
    static func controlDrift(
        controls: [CoachMeasure],
        before: [HabitSample],
        after: [HabitSample],
        all: [HabitSample]
    ) -> Double? {
        guard let beforeStart = before.first?.createdAt, let beforeEnd = before.last?.createdAt,
              let afterStart = after.first?.createdAt, let afterEnd = after.last?.createdAt else { return nil }
        let beforeSpan = all.filter { $0.createdAt >= beforeStart && $0.createdAt <= beforeEnd }
        let afterSpan = all.filter { $0.createdAt >= afterStart && $0.createdAt <= afterEnd }
        var changes: [Double] = []
        for other in controls {
            let b = beforeSpan.compactMap { other.isHit($0.measures) }
            let a = afterSpan.compactMap { other.isHit($0.measures) }
            guard b.count >= minimumBaseline, a.count >= minimumBaseline,
                  let bs = share(b), let as_ = share(a) else { continue }
            changes.append(as_ - bs)
        }
        return mean(changes)
    }

    /// The 5th and 95th percentiles of the change in share.
    static func bootstrapInterval(before: [Bool], after: [Bool], seed: UInt64) -> (Double, Double) {
        var rng = SplitMix64(seed: seed)
        var changes: [Double] = []
        changes.reserveCapacity(resamples)
        let b = before.map { $0 ? 1.0 : 0.0 }
        let a = after.map { $0 ? 1.0 : 0.0 }
        for _ in 0..<resamples {
            let rb = (0..<b.count).reduce(0.0) { sum, _ in sum + b[Int(rng.next() % UInt64(b.count))] } / Double(b.count)
            let ra = (0..<a.count).reduce(0.0) { sum, _ in sum + a[Int(rng.next() % UInt64(a.count))] } / Double(a.count)
            changes.append(ra - rb)
        }
        changes.sort()
        return (changes[resamples * 5 / 100], changes[resamples * 95 / 100 - 1])
    }

    static func share(_ hits: [Bool]) -> Double? {
        hits.isEmpty ? nil : Double(hits.filter { $0 }.count) / Double(hits.count)
    }

    static func mean(_ values: [Double]) -> Double? {
        values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
    }
}

/// A small seeded generator, so a verdict never changes between launches.
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
