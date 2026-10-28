// HabitTests.swift
// CoachCoreTests

import Foundation
import Testing
@testable import CoachCore

private let start = Date(timeIntervalSince1970: 1_800_000_000)

/// `hits` dictations before the start and after, one an hour, each meeting
/// the fillers habit or not.
private func samples(before: [Bool], after: [Bool], otherHit: Bool = true) -> [HabitSample] {
    func make(_ hit: Bool, _ offset: Int, _ id: Int) -> HabitSample {
        HabitSample(
            id: Int64(id),
            createdAt: start.addingTimeInterval(Double(offset) * 3_600),
            measures: DictationMeasures(
                words: 100,
                umUh: hit ? 0 : 4,
                phraseFillers: otherHit ? 0 : 3,
                wpm: 140,
                sentenceLengths: [10],
                repeats: 0,
                polishChangeRatio: 0.05,
                rawKnown: true
            )
        )
    }
    let b = before.enumerated().map { make($1, -before.count + $0, $0) }
    let a = after.enumerated().map { make($1, $0, 1_000 + $0) }
    return b + a
}

@Suite("Habits and proof")
struct HabitTests {
    @Test func watchingUntilTwentySince() {
        let v = HabitJudge.verdict(measure: .fillers, startedAt: start, samples: samples(before: Array(repeating: false, count: 20), after: Array(repeating: true, count: 11)))
        #expect(v.status == .watching)
        #expect(v.stillNeeded == 9)
        #expect(v.sinceCount == 11)
        #expect(v.controlDrift == nil)
    }

    @Test func noBaselineMeansWatching() {
        let v = HabitJudge.verdict(measure: .fillers, startedAt: start, samples: samples(before: [false, false], after: Array(repeating: true, count: 25)))
        #expect(v.status == .watching)
    }

    @Test func clearImprovementIsWorking() {
        let before = (0..<20).map { $0 % 5 < 2 }   // 40%
        let after = (0..<20).map { $0 % 10 != 0 }  // 90%
        let v = HabitJudge.verdict(measure: .fillers, startedAt: start, samples: samples(before: before, after: after))
        #expect(v.status == .working)
        #expect(v.beforeShare == 0.4)
        #expect(v.afterShare == 0.9)
        #expect(v.controlDrift == 0)
        #expect(v.before.count == 20)
        #expect(v.after.count == 20)
        #expect(v.bestExampleID == 1_019)
    }

    @Test func noChangeIsNotMoving() {
        let same = (0..<20).map { $0 % 2 == 0 }
        let v = HabitJudge.verdict(measure: .fillers, startedAt: start, samples: samples(before: same, after: same))
        #expect(v.status == .notMoving)
    }

    @Test func usesTheLatestTwentySince() {
        let after = Array(repeating: false, count: 10) + Array(repeating: true, count: 20)
        let v = HabitJudge.verdict(measure: .fillers, startedAt: start, samples: samples(before: Array(repeating: false, count: 20), after: after))
        #expect(v.after == Array(repeating: true, count: 20))
        #expect(v.sinceCount == 30)
        #expect(v.status == .working)
    }

    @Test func sameAnswerEveryTime() {
        let before = (0..<20).map { $0 % 3 == 0 }
        let after = (0..<20).map { $0 % 3 != 0 }
        let first = HabitJudge.bootstrapInterval(before: before, after: after, seed: 7)
        let second = HabitJudge.bootstrapInterval(before: before, after: after, seed: 7)
        #expect(first == second)
        #expect(first.0 < first.1)
    }
}
