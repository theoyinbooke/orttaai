// PracticeTests.swift
// CoachCoreTests

import Foundation
import Testing
@testable import CoachCore

@Suite("Skills, scoring, the judge and the note guard")
struct PracticeTests {
    @Test func everySkillBelongsToItsTrackAndIsChecked() {
        #expect(Set(CoachSkill.all.map(\.id)).count == CoachSkill.all.count)
        for track in CoachTrack.allCases {
            #expect(!track.skills.isEmpty)
            #expect(track.checks.count == 4)
        }
        for skill in CoachSkill.all {
            #expect(skill.checks.contains(skill.check))
            #expect(skill.checks.first == skill.check || skill.track.checks.contains(skill.check))
        }
        #expect(CoachSkill.skill(id: "steady-pace")?.speakOnly == true)
        #expect(CoachSkill.skill(id: "fewer-umuh")?.measure == .fillers)
        #expect(CoachSkill.skill(id: "finish-line")?.measure == nil)
        #expect(CoachTrack.track(for: .people) == .messages)
    }

    @Test func scoreIsOnePlusFourTimesTheShareOfPoints() {
        let results = [
            CheckResult(check: .judged(.taskFirst), answer: .yes),
            CheckResult(check: .judged(.context), answer: .partly),
            CheckResult(check: .judged(.finishLine), answer: .no),
            CheckResult(check: .judged(.oneAsk), answer: nil),
        ]
        // 1.5 points over 3 answered: 1 + 4 × 0.5.
        #expect(CoachScore.score(results) == 3.0)
        #expect(CoachScore.score([CheckResult(check: .judged(.tone), answer: nil)]) == nil)
        #expect(CoachScore.score([CheckResult(check: .judged(.tone), answer: .yes)]) == 5.0)
    }

    @Test func countedChecksReadTheAttempt() {
        let m = DictationMeasures(words: 70, umUh: 0, phraseFillers: 0, wpm: nil, sentenceLengths: [10], repeats: 1, polishChangeRatio: 0, rawKnown: true)
        #expect(CheckResult.counted(.briefWords, m).answer == .no)
        #expect(CheckResult.counted(.measure(.fillers), m).answer == .yes)
        #expect(CheckResult.counted(.measure(.repeats), m).answer == .no)
        // A typed attempt has no pace: it can't be told.
        #expect(CheckResult.counted(.measure(.pace), m).answer == nil)
    }

    @Test func judgeRepliesAreReadStrictly() {
        #expect(CoachJudgePrompt.parse(#"{"answer":"yes","confidence":0.92}"#)! == (JudgeAnswer.yes, 0.92))
        #expect(CoachJudgePrompt.parse("Sure! {\"answer\": \"Partly\", \"confidence\": \"0.6\"} done")! == (JudgeAnswer.partly, 0.6))
        #expect(CoachJudgePrompt.parse(#"{"answer":"no","confidence":7}"#)?.confidence == 1)
        #expect(CoachJudgePrompt.parse(#"{"answer":"maybe","confidence":0.5}"#) == nil)
        #expect(CoachJudgePrompt.parse("no json here") == nil)
        let prompt = CoachJudgePrompt.prompt(question: .finishLine, text: "Fix the paste.", context: "Redo your prompt")
        #expect(prompt.contains("<<<\nFix the paste.\n>>>"))
        #expect(prompt.contains(CoachQuestion.finishLine.question))
    }

    @Test func notesMayOnlyUseNumbersTheyWereGiven() {
        let allowed = CoachNoteGuard.allowedNumbers(from: [4.2, 152])
        #expect(CoachNoteGuard.accepts("Strong rep: 4.2 and a pace of 152.", allowed: allowed))
        #expect(CoachNoteGuard.accepts("Nice. Do it 2 more times.", allowed: allowed))
        #expect(!CoachNoteGuard.accepts("You hit 97% of checks.", allowed: allowed))
        #expect(!CoachNoteGuard.accepts(String(repeating: "a", count: 300), allowed: allowed))
        #expect(!CoachNoteGuard.accepts("  ", allowed: allowed))
        #expect(CoachNoteGuard.cleaned("  “Good work.” ") == "Good work.")
    }

    @Test func everyCoachHasALineForEveryOutcome() {
        for persona in CoachPersona.allCases {
            for met in [true, false, nil] as [Bool?] {
                let line = persona.line(skill: "Ask first", met: met, missing: "Says when, and why it matters")
                #expect(!line.isEmpty && line.count <= CoachNoteGuard.maxCharacters)
            }
            #expect(persona.notePrompt(skill: CoachSkill.all[0], results: [], facts: ["pace 150"], score: 4.0).contains("4.0 out of 5"))
        }
    }
}
