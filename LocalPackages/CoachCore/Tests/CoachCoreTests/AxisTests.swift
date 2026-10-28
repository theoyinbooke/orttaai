// AxisTests.swift
// CoachCoreTests

import Foundation
import Testing
@testable import CoachCore

private func sample(_ id: Int64, daysAgo: Double, mode: CoachMode, words: Int = 40, from now: Date) -> DatedMeasures {
    DatedMeasures(
        id: id,
        createdAt: now.addingTimeInterval(-daysAgo * 86_400),
        mode: mode,
        measures: DictationMeasures(words: words, umUh: 0, phraseFillers: 0, wpm: 145, sentenceLengths: [10, 12], repeats: 0, polishChangeRatio: 0.05, rawKnown: true)
    )
}

@Suite("Judged axes on the voice shape")
struct AxisTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func eachWayOfTalkingHasSixAxesFromTheDesign() {
        #expect(CoachAxis.axes(for: .ai).map(\.title) == ["Task first", "Context", "Finish line", "One ask", "Said it clearly", "Steady pace"])
        #expect(CoachAxis.questions(for: .people) == [.askFirst, .whenWhy, .tone])
        #expect(CoachAxis.questions(for: .writing) == [.pointFirst, .oneIdea, .summary, .plainWords])
        #expect(CoachAxis.axes(for: nil) == CoachMeasure.allCases.map(CoachAxis.measure))
        #expect(CoachAxis.axes(for: .elsewhere) == CoachAxis.axes(for: nil))
        for mode in CoachMode.allCases {
            #expect(CoachAxis.axes(for: mode).count == 6)
            #expect(Set(CoachAxis.axes(for: mode)).count == 6)
        }
    }

    @Test func aJudgedAxisAveragesTheAnswersOnceThereAreEight() {
        var samples: [DatedMeasures] = []
        var answers: [Int64: Double] = [:]
        for i in 0..<10 {
            samples.append(sample(Int64(i), daysAgo: Double(i), mode: .ai, from: now))
            samples.append(sample(Int64(100 + i), daysAgo: Double(30 + i), mode: .ai, from: now))
            // Now: 8 judged, 6 yes and 2 partly; then: 7 judged, too few.
            if i < 6 { answers[Int64(i)] = 1 } else if i < 8 { answers[Int64(i)] = 0.5 }
            if i < 7 { answers[Int64(100 + i)] = 0 }
        }
        let shape = CoachShape.make(samples, mode: .ai, now: now, judgements: [.taskFirst: answers])
        #expect(shape.nowAxes[.question(.taskFirst)] == 7.0 / 8.0)
        #expect(shape.thenAxes[.question(.taskFirst)] == nil)
        #expect(shape.nowAxes[.question(.context)] == nil)
        // Counted axes are drawn as before, and every measure is still worked out for focus.
        #expect(shape.nowAxes[.measure(.pace)] != nil)
        #expect(shape.now.count == CoachMeasure.allCases.count)
        #expect(!shape.isComplete)
        #expect(shape.waitsOnJudge)
        #expect(shape.biggestGain == nil)
    }

    @Test func theBiggestGainCanBeAJudgedAxis() {
        var samples: [DatedMeasures] = []
        var finish: [Int64: Double] = [:]
        for i in 0..<10 {
            samples.append(sample(Int64(i), daysAgo: Double(i), mode: .ai, from: now))
            samples.append(sample(Int64(100 + i), daysAgo: Double(30 + i), mode: .ai, from: now))
            finish[Int64(i)] = i < 6 ? 1 : 0
            finish[Int64(100 + i)] = i < 3 ? 1 : 0
        }
        let shape = CoachShape.make(samples, mode: .ai, now: now, judgements: [.finishLine: finish])
        #expect(shape.biggestGain == .question(.finishLine))
        #expect(shape.changes.first?.axis == .question(.finishLine))
        #expect(abs((shape.changes.first?.change ?? 0) - 0.3) < 0.0001)
    }

    @Test func aWindowCanBeAnyIntervalAgainstTheOneBefore() {
        let calendar = Calendar(identifier: .gregorian)
        let month = calendar.dateInterval(of: .month, for: now)!
        let previous = DateInterval(start: calendar.date(byAdding: .month, value: -1, to: month.start)!, end: month.start)
        var samples: [DatedMeasures] = []
        for i in 0..<9 {
            samples.append(DatedMeasures(id: Int64(i), createdAt: month.start.addingTimeInterval(Double(i) * 3_600), mode: .ai, measures: DictationMeasures(words: 100, umUh: 1, phraseFillers: 0, wpm: 145, sentenceLengths: [10], repeats: 0, polishChangeRatio: 0.05, rawKnown: true)))
            samples.append(DatedMeasures(id: Int64(50 + i), createdAt: previous.start.addingTimeInterval(Double(i) * 3_600), mode: .ai, measures: DictationMeasures(words: 100, umUh: 4, phraseFillers: 0, wpm: 145, sentenceLengths: [10], repeats: 0, polishChangeRatio: 0.05, rawKnown: true)))
        }
        // A dictation made exactly at the month's start belongs to it, not the month before.
        let shape = CoachShape.make(samples, mode: nil, window: month, before: previous)
        #expect(shape.nowSummary.dictations == 9)
        #expect(shape.thenSummary.dictations == 9)
        #expect(shape.biggestGain == .measure(.fillers))
    }

    @Test func judgingFillsTheLatestWindowFirstWithAxesTakingTurns() {
        var samples: [DatedMeasures] = []
        for i in 0..<15 {
            samples.append(sample(Int64(i), daysAgo: Double(i), mode: .ai, from: now))
            samples.append(sample(Int64(100 + i), daysAgo: Double(30 + i), mode: .ai, from: now))
        }
        samples.append(sample(500, daysAgo: 1, mode: .ai, words: 3, from: now))
        samples.append(sample(600, daysAgo: 1, mode: .people, from: now))
        // Task first already has 12 answers in the latest window.
        let known: [CoachQuestion: [Int64: Double]] = [.taskFirst: Dictionary(uniqueKeysWithValues: (0..<12).map { (Int64($0), 1.0) })]
        let queue = CoachShapeJudging.queue(samples, modes: [.ai, .people], known: known, now: now)

        // Context, finish line and one ask take turns, newest first.
        #expect(queue.prefix(3).map(\.question) == [.context, .finishLine, .oneAsk])
        #expect(queue.prefix(3).map(\.id) == [0, 0, 0])
        #expect(!queue.contains { $0.question == .taskFirst && $0.id < 100 })
        // Up to 12 per axis per window, never a short dictation.
        #expect(queue.filter { $0.question == .context && $0.id < 100 }.count == 12)
        #expect(!queue.contains { $0.id == 500 })
        // Then people's latest window, then the windows before.
        let firstPeople = queue.firstIndex { $0.id == 600 }!
        let firstOlder = queue.firstIndex { $0.id >= 100 && $0.id < 200 }!
        #expect(firstPeople < firstOlder)
        #expect(queue.filter { $0.question == .taskFirst && $0.id >= 100 }.count == 12)
    }
}
