// CoachJudgeCheckTests.swift
// OrttaaiTests
//
// A judge is only used once it has passed the judge check: grades are kept
// per model, the best one that passed is chosen unless the person picked,
// and one that failed, or was graded on older examples, is never trusted.

import CoachCore
import XCTest
@testable import Orttaai

final class CoachJudgeCheckTests: XCTestCase {
    private let keys = [CoachPreferences.judgeGradesKey, CoachPreferences.judgeModelKey, CoachPreferences.coachModelKey, "localLLMInsightsModel"]
    private var saved: [String: Any] = [:]

    override func setUp() {
        super.setUp()
        for key in keys { saved[key] = UserDefaults.standard.object(forKey: key) }
        for key in keys { UserDefaults.standard.removeObject(forKey: key) }
        UserDefaults.standard.set("insights-model", forKey: "localLLMInsightsModel")
    }

    override func tearDown() {
        for key in keys {
            if let value = saved[key] { UserDefaults.standard.set(value, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
        }
        super.tearDown()
    }

    private func grade(_ model: String, accuracy: Double, yes: Double = 0.9, no: Double = 0.9, ms: Int, version: Int = CoachCalibration.version) -> JudgeGrade {
        JudgeGrade(model: model, accuracy: accuracy, yesRecall: yes, noRecall: no, answered: 52, total: 52, msPerAnswer: ms, version: version, gradedAt: Date())
    }

    func testWithNothingCheckedCoachUsesTheInsightsModelButDoesNotTrustIt() {
        let setup = CoachModels.current()
        XCTAssertEqual(setup.judgeModel, "insights-model")
        XCTAssertEqual(setup.coachModel, "insights-model")
        XCTAssertFalse(CoachModels.judgeTrusted(setup))
        XCTAssertNil(CoachPreferences.bestPassingJudge)
    }

    func testTheBestModelThatPassedIsUsedForBothJobs() {
        CoachPreferences.saveJudgeGrade(grade("always-no", accuracy: 0.5, yes: 0, no: 1, ms: 50))
        CoachPreferences.saveJudgeGrade(grade("big", accuracy: 0.92, ms: 400))
        CoachPreferences.saveJudgeGrade(grade("small", accuracy: 0.92, ms: 120))
        CoachPreferences.saveJudgeGrade(grade("older", accuracy: 1, ms: 50, version: CoachCalibration.version - 1))

        XCTAssertEqual(CoachPreferences.bestPassingJudge?.model, "small", "Equally right, so the faster one")
        let setup = CoachModels.current()
        XCTAssertEqual(setup.judgeModel, "small")
        XCTAssertEqual(setup.coachModel, "small")
        XCTAssertTrue(CoachModels.judgeTrusted(setup))
        XCTAssertNil(CoachPreferences.judgeGrade(for: "older"), "Graded on older examples")
    }

    func testThePersonsChoiceWinsButAFailedJudgeIsNeverTrusted() {
        CoachPreferences.saveJudgeGrade(grade("always-no", accuracy: 0.5, yes: 0, no: 1, ms: 50))
        CoachPreferences.saveJudgeGrade(grade("small", accuracy: 0.92, ms: 120))
        UserDefaults.standard.set("always-no", forKey: CoachPreferences.judgeModelKey)
        UserDefaults.standard.set("writer", forKey: CoachPreferences.coachModelKey)

        let setup = CoachModels.current()
        XCTAssertEqual(setup.judgeModel, "always-no")
        XCTAssertEqual(setup.coachModel, "writer")
        XCTAssertFalse(CoachModels.judgeTrusted(setup))
    }

    func testAnUntrustedJudgeIsNeverAsked() async {
        let setup = CoachModelSetup(provider: .ollama, endpoint: "http://127.0.0.1:9", coachModel: "x", judgeModel: "unchecked")
        let started = Date()
        let answer = await CoachModels.judge(.taskFirst, text: "Fix the paste.", context: nil, setup: setup)
        XCTAssertNil(answer)
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.5, "Returned without calling the server")
    }
}
