// ProfileTests.swift
// CoachCoreTests

import Foundation
import Testing
@testable import CoachCore

private func measures(
    words: Int = 40,
    umUh: Int = 0,
    phrases: Int = 0,
    wpm: Int? = 145,
    sentences: [Int] = [10, 12],
    repeats: Int = 0,
    polish: Double? = 0.05,
    raw: Bool = true
) -> DictationMeasures {
    DictationMeasures(words: words, umUh: umUh, phraseFillers: phrases, wpm: wpm, sentenceLengths: sentences, repeats: repeats, polishChangeRatio: polish, rawKnown: raw)
}

@Suite("Summaries, the voice shape and focus")
struct ProfileTests {
    @Test func summaryAddsUpLikeOrttakey() {
        let s = CoachSummary([
            measures(words: 100, umUh: 3, wpm: 120, sentences: [10, 20]),
            measures(words: 100, umUh: 1, wpm: 150, sentences: [30]),
            measures(words: 50, umUh: 9, wpm: 200, sentences: [5], raw: false),
            measures(words: 100, umUh: 0, wpm: 170, sentences: [14]),
        ])
        #expect(s.dictations == 4)
        #expect(s.words == 350)
        #expect(s.rawWords == 300)
        // The unknown-raw row's fillers stay out.
        #expect(s.umUh == 4)
        #expect(abs(s.umUhRate - 4.0 / 3.0) < 0.0001)
        // Paces sorted 120,150,170,200: median is the upper middle; a quarter above 200.
        #expect(s.pace == 170)
        #expect(s.fastPace == 200)
        // Raw sentence lengths 10,20,30,14 sorted 10,14,20,30.
        #expect(s.medianSentence == 20)
        #expect(s.longestSentence == 30)
    }

    @Test func axesNeedEightDictations() {
        let few = CoachSummary(Array(repeating: measures(), count: 7))
        #expect(CoachMeasure.fillers.axisScore(few) == nil)
        let enough = CoachSummary(Array(repeating: measures(), count: 8))
        #expect(CoachMeasure.fillers.axisScore(enough) == 1)
        #expect(CoachMeasure.pace.axisScore(enough) == 1)
        #expect(CoachMeasure.sentences.axisScore(enough) == 1)
    }

    @Test func axisScalesAreFixed() {
        let s = CoachSummary(Array(repeating: measures(words: 100, umUh: 2, phrases: 2, wpm: 190, sentences: [22], repeats: 1, polish: 0.4), count: 10))
        #expect(abs(CoachMeasure.fillers.axisScore(s)! - 0.6) < 0.0001)
        #expect(abs(CoachMeasure.phrases.axisScore(s)! - 0.5) < 0.0001)
        #expect(abs(CoachMeasure.pace.axisScore(s)! - 0.5) < 0.0001)
        #expect(abs(CoachMeasure.sentences.axisScore(s)! - 0.5) < 0.0001)
        #expect(abs(CoachMeasure.repeats.axisScore(s)! - 0.5) < 0.0001)
        #expect(CoachMeasure.clarity.axisScore(s) == 0)
    }

    @Test func focusUsesOrttakeyScoresFirst() {
        let s = CoachSummary(Array(repeating: measures(words: 100, umUh: 3, wpm: 180, sentences: [16]), count: 10))
        let needs = CoachFocus.needs(s)
        #expect(needs.map(\.measure) == [.fillers, .sentences, .pace])
        #expect(abs(needs[0].score - 3.0) < 0.0001)
        #expect(abs(needs[1].score - 0.9 * 16.0 / 14.0) < 0.0001)
        #expect(abs(needs[2].score - 0.8 * 180.0 / 160.0) < 0.0001)
        #expect(CoachFocus.needs(CoachSummary(Array(repeating: measures(), count: 10))).isEmpty)
        // One long sentence alone isn't a focus when the typical one is short.
        let oneLong = CoachSummary(Array(repeating: measures(sentences: [8, 10, 45]), count: 10))
        #expect(!CoachFocus.needs(oneLong).map(\.measure).contains(.sentences))
    }

    @Test func shapeComparesTheLast28DaysWithThe28Before() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var samples: [DatedMeasures] = []
        for day in 0..<10 {
            let recent = now.addingTimeInterval(-Double(day) * 86_400)
            let older = now.addingTimeInterval(-Double(day + 30) * 86_400)
            samples.append(DatedMeasures(id: Int64(day), createdAt: recent, mode: .writing, measures: measures(words: 100, umUh: 1)))
            samples.append(DatedMeasures(id: Int64(day + 100), createdAt: older, mode: .writing, measures: measures(words: 100, umUh: 4)))
            samples.append(DatedMeasures(id: Int64(day + 200), createdAt: recent, mode: .people, measures: measures(words: 100, umUh: 5)))
        }
        let ai = CoachShape.make(samples, mode: .writing, now: now)
        #expect(abs(ai.now[.fillers]! - 0.8) < 0.0001)
        #expect(abs(ai.then[.fillers]! - 0.2) < 0.0001)
        #expect(ai.biggestGain == .measure(.fillers))
        let people = CoachShape.make(samples, mode: .people, now: now)
        #expect(people.then[.fillers] == nil)
        #expect(people.biggestGain == nil)
    }
}

@Suite("Ways of talking")
struct ModeTests {
    @Test func builtInTable() {
        #expect(CoachAppCatalog.builtInMode(bundleID: "com.anthropic.claudefordesktop", appName: "Claude") == .ai)
        #expect(CoachAppCatalog.builtInMode(bundleID: "com.apple.Terminal", appName: nil) == .ai)
        #expect(CoachAppCatalog.builtInMode(bundleID: "com.tinyspeck.slackmacgap", appName: "Slack") == .people)
        #expect(CoachAppCatalog.builtInMode(bundleID: "md.obsidian", appName: nil) == .writing)
        #expect(CoachAppCatalog.builtInMode(bundleID: "com.apple.Safari", appName: "Safari") == .elsewhere)
        #expect(CoachAppCatalog.builtInMode(bundleID: nil, appName: "Orttakey on iPhone") == .elsewhere)
        // Rows that only kept the name.
        #expect(CoachAppCatalog.builtInMode(bundleID: nil, appName: " Slack ") == .people)
        #expect(CoachAppCatalog.builtInMode(bundleID: "com.cmuxterm.app", appName: "cmux") == .ai)
        #expect(CoachAppCatalog.builtInMode(bundleID: "com.orttaai.Orttaai", appName: "Orttaai") == .ai)
    }

    @Test func overridesWin() {
        let overrides: [String: CoachAppRule] = [
            "com.apple.safari": .writing,
            "com.tinyspeck.slackmacgap": .off,
            "name:codex": .people,
        ]
        #expect(CoachAppCatalog.mode(bundleID: "com.apple.Safari", appName: "Safari", overrides: overrides) == .writing)
        #expect(CoachAppCatalog.mode(bundleID: "com.tinyspeck.slackmacgap", appName: "Slack", overrides: overrides) == nil)
        #expect(CoachAppCatalog.mode(bundleID: nil, appName: "Codex", overrides: overrides) == .people)
        #expect(CoachAppCatalog.mode(bundleID: "com.openai.codex", appName: "Codex", overrides: overrides) == .ai)
        #expect(CoachAppCatalog.key(bundleID: nil, appName: nil) == nil)
    }
}
