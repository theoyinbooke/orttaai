// CalibrationTests.swift
// CoachCoreTests

import Foundation
import Testing
@testable import CoachCore

@Suite("The judge check")
struct CalibrationTests {
    let examples = CoachCalibration.examples

    func grade(_ answer: (CalibrationExample) -> JudgeAnswer?) -> JudgeGrade {
        CoachCalibration.grade(model: "m", answers: examples.map { ($0, answer($0)) }, msPerAnswer: 120)
    }

    @Test func everyQuestionHasTwoClearYesesAndTwoClearNos() {
        for question in CoachQuestion.allCases {
            let mine = examples.filter { $0.question == question }
            #expect(mine.filter { $0.expected == .yes }.count == 2, "\(question)")
            #expect(mine.filter { $0.expected == .no }.count == 2, "\(question)")
        }
        #expect(Set(examples.map(\.text)).count == examples.count)
    }

    @Test func aJudgeThatGetsThemRightPasses() {
        let perfect = grade { $0.expected }
        #expect(perfect.accuracy == 1)
        #expect(perfect.yesRecall == 1)
        #expect(perfect.noRecall == 1)
        #expect(perfect.passes)
        #expect(perfect.isCurrent)
        #expect(perfect.msPerAnswer == 120)
    }

    @Test func aJudgeThatSaysTheSameThingToEverythingFails() {
        let alwaysNo = grade { _ in .no }
        #expect(alwaysNo.accuracy == 0.5)
        #expect(alwaysNo.yesRecall == 0)
        #expect(!alwaysNo.passes)
        let alwaysYes = grade { _ in .yes }
        #expect(alwaysYes.noRecall == 0)
        #expect(!alwaysYes.passes)
    }

    @Test func partlyEarnsHalfAndTooManyMissesFail() {
        let hedging = grade { _ in .partly }
        #expect(hedging.accuracy == 0.5)
        #expect(!hedging.passes)
        // Right whenever it answers, but silent on a fifth of them.
        var index = 0
        let quiet = grade { example in
            index += 1
            return index % 5 == 0 ? nil : example.expected
        }
        #expect(quiet.answered < quiet.total)
        #expect(!quiet.passes)
        // One wrong in ten still passes.
        index = 0
        let mostlyRight = grade { example in
            index += 1
            return index % 10 == 0 ? (example.expected == .yes ? .no : .yes) : example.expected
        }
        #expect(mostlyRight.accuracy >= 0.8)
        #expect(mostlyRight.passes)
    }

    @Test func gradesFromOlderExamplesAreNotCurrent() {
        var old = grade { $0.expected }
        old.version = CoachCalibration.version - 1
        #expect(!old.isCurrent)
        let data = try! JSONEncoder().encode(old)
        #expect(try! JSONDecoder().decode(JudgeGrade.self, from: data) == old)
    }
}
