// SceneTests.swift
// CoachCoreTests

import Foundation
import Testing
@testable import CoachCore

@Suite("Scenes and judged habits")
struct SceneTests {
    @Test func everyTrackHasAScene() {
        for track in CoachTrack.allCases {
            #expect(!CoachScene.scenes(for: track).isEmpty)
        }
        #expect(Set(CoachScene.all.map(\.id)).count == CoachScene.all.count)
    }

    @Test func partnerPromptCarriesTheConversation() {
        let scene = CoachScene.scene(id: "scope-push")!
        let prompt = CoachPartnerPrompt.prompt(scene: scene, turns: [
            SceneTurn(speaker: .partner, text: scene.opening),
            SceneTurn(speaker: .you, text: "By Friday I can do one of them properly."),
        ])
        #expect(prompt.contains("Tolu: \(scene.opening)"))
        #expect(prompt.contains("Them: By Friday I can do one of them properly."))
        #expect(prompt.hasPrefix(scene.partnerBrief))
    }

    @Test func partnerRepliesAreReadStrictly() {
        let parsed = CoachPartnerPrompt.parse(#"{"reply":"Hmm, which one then?","mood":"Weighing"}"#)
        #expect(parsed?.reply == "Hmm, which one then?")
        #expect(parsed?.mood == .weighing)
        #expect(CoachPartnerPrompt.parse(#"{"reply":"","mood":"agreed"}"#) == nil)
        #expect(CoachPartnerPrompt.parse(#"{"reply":"Fine.","mood":"happy"}"#) == nil)
        #expect(CoachPartnerPrompt.parse("Sure, let's do it.") == nil)
    }

    @Test func goalChecksHaveTheirOwnIdentity() {
        let goal = CoachCheck.goal("newcomer")
        #expect(goal.id == "g-newcomer")
        #expect(goal.label == "Reached the goal")
        let data = try! JSONEncoder().encode([CheckResult(check: goal, answer: .yes, confidence: 0.8)])
        #expect(try! JSONDecoder().decode([CheckResult].self, from: data).first?.check == goal)
        #expect(CoachJudgePrompt.prompt(questionText: "Was it clear?", text: "Hi.", context: nil).contains("Question: Was it clear?"))
    }

    @Test func habitsWorkOnAnyNotionOfMet() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        func sample(_ id: Int, _ offset: Int) -> HabitSample {
            HabitSample(id: Int64(id), createdAt: start.addingTimeInterval(Double(offset) * 600),
                        measures: DictationMeasures(words: 30, umUh: 0, phraseFillers: 0, wpm: 140, sentenceLengths: [10], repeats: 0, polishChangeRatio: 0, rawKnown: true))
        }
        let samples = (0..<20).map { sample($0, -20 + $0) } + (0..<20).map { sample(100 + $0, $0) }
        // Judged answers: none before, all since; one not judged yet.
        let answers: [Int64: Bool] = Dictionary(uniqueKeysWithValues: samples.compactMap { s in
            s.id == 105 ? nil : (s.id, s.id >= 100)
        })
        let verdict = HabitJudge.verdict(
            startedAt: start,
            samples: samples,
            isHit: { answers[$0.id] },
            value: { answers[$0.id].map { $0 ? 1 : 0 } },
            controls: CoachMeasure.allCases
        )
        #expect(verdict.before.count == 20)
        #expect(verdict.sinceCount == 19)
        #expect(verdict.status == .watching)
        #expect(verdict.stillNeeded == 1)
    }
}
