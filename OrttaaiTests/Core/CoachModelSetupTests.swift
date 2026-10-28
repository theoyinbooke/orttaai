// CoachModelSetupTests.swift
// OrttaaiTests
//
// Coach recommends a quick scene partner on every Mac, and the big judge only
// where both fit in memory.

import XCTest
@testable import Orttaai

final class CoachModelSetupTests: XCTestCase {
    func testABigMacGetsTheQuickPartnerAndTheBigJudge() {
        let models = CoachStarterModels.recommended(memory: 64 << 30)
        XCTAssertEqual(models.map(\.name), [CoachStarterModels.partner, CoachStarterModels.bigJudge])
        XCTAssertEqual(models.first?.jobs, ["Scene partner"])
        XCTAssertEqual(CoachStarterModels.judge(memory: 64 << 30), CoachStarterModels.bigJudge)
    }

    func testASmallerMacGetsOneModelForEveryJob() {
        let models = CoachStarterModels.recommended(memory: 16 << 30)
        XCTAssertEqual(models.map(\.name), [CoachStarterModels.partner])
        XCTAssertEqual(models.first?.jobs, ["Scene partner", "Judge", "Coach"])
        XCTAssertEqual(CoachStarterModels.judge(memory: 16 << 30), CoachStarterModels.partner)
    }

    func testEveryRecommendedModelIsLocal() {
        for model in CoachStarterModels.recommended(memory: 64 << 30) {
            XCTAssertFalse(model.name.contains("cloud"), "\(model.name) must run on this Mac")
        }
    }
}
