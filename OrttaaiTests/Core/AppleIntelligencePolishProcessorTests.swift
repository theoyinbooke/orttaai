// AppleIntelligencePolishProcessorTests.swift
// OrttaaiTests

import XCTest
@testable import Orttaai

final class AppleIntelligencePolishProcessorTests: XCTestCase {
    // MARK: - Sanitizer

    func testSanitizerAcceptsReasonablePolish() {
        let original = "so um i think we should move the meeting to thursday afternoon"
        let candidate = "I think we should move the meeting to Thursday afternoon."

        XCTAssertEqual(
            AppleIntelligencePolishProcessor.sanitizedPolishOutput(candidate, original: original),
            candidate
        )
    }

    func testSanitizerRejectsEmptyOutput() {
        XCTAssertNil(AppleIntelligencePolishProcessor.sanitizedPolishOutput("  \n ", original: "some dictated text"))
    }

    func testSanitizerRejectsSevereTruncation() {
        let original = String(repeating: "we need to review the quarterly numbers together ", count: 4)

        XCTAssertNil(AppleIntelligencePolishProcessor.sanitizedPolishOutput("Reviewed.", original: original))
    }

    func testSanitizerRejectsRunawayExpansion() {
        let original = "short note about the plan"
        let candidate = String(repeating: "Here is a much longer elaboration of the plan. ", count: 4)

        XCTAssertNil(AppleIntelligencePolishProcessor.sanitizedPolishOutput(candidate, original: original))
    }

    func testSanitizerRejectsOutputThatDropsANumber() {
        let original = "the budget is 45000 dollars and the deadline is March 3"
        let candidate = "The budget is forty-five thousand dollars and the deadline is March 3."

        XCTAssertNil(AppleIntelligencePolishProcessor.sanitizedPolishOutput(candidate, original: original))
    }

    func testSanitizerAllowsCommaFormattingOfNumbers() {
        let original = "the budget is 45000 dollars for quarter 3"
        let candidate = "The budget is 45,000 dollars for quarter 3."

        XCTAssertEqual(
            AppleIntelligencePolishProcessor.sanitizedPolishOutput(candidate, original: original),
            candidate
        )
    }

    // MARK: - Number extraction

    func testNumberTokensExtractsAndNormalizes() {
        let tokens = AppleIntelligencePolishProcessor.numberTokens(
            in: "pay 1,250 by June 30. reference 88."
        )

        XCTAssertEqual(tokens, ["1250", "30", "88"])
    }

    // MARK: - Gating

    func testDisabledSettingPassesTextThroughUnchanged() async throws {
        let settings = AppSettings()
        let original = settings.appleIntelligencePolishEnabled
        defer { settings.appleIntelligencePolishEnabled = original }
        settings.appleIntelligencePolishEnabled = false

        let processor = AppleIntelligencePolishProcessor(
            baseProcessor: PassthroughProcessor(),
            settings: settings
        )

        let output = try await processor.process(
            TextProcessorInput(rawTranscript: "um hello there world", targetApp: nil, mode: .raw)
        )

        XCTAssertEqual(output.text, "um hello there world")
        XCTAssertTrue(output.changes.isEmpty)
    }
}
