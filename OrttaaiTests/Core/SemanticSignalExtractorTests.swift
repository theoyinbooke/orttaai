// SemanticSignalExtractorTests.swift
// OrttaaiTests

import XCTest
@testable import Orttaai

final class SemanticSignalExtractorTests: XCTestCase {
    private func values(_ signals: [SemanticSignalExtractor.ExtractedSignal], _ family: SemanticSignalFamily) -> [String] {
        signals.filter { $0.family == family }.map(\.value)
    }

    func testExtractsCommitments() {
        let signals = SemanticSignalExtractor.signals(
            in: "I'm going to sign in to my personal Docker profile. The weather is nice."
        )

        let commitments = values(signals, .commitment)
        XCTAssertEqual(commitments.count, 1)
        XCTAssertTrue(commitments[0].contains("Docker profile"))
    }

    func testExtractsQuestionsWithAndWithoutQuestionMark() {
        let signals = SemanticSignalExtractor.signals(
            in: "Do you want to help me update the document. What happens after the sync completes?"
        )

        XCTAssertEqual(values(signals, .question).count, 2)
    }

    func testExtractsDecisions() {
        let signals = SemanticSignalExtractor.signals(
            in: "After comparing both options we decided to keep the pasteboard approach for injection."
        )

        XCTAssertEqual(values(signals, .decision).count, 1)
    }

    func testToneOnlyWhenWordSupported() {
        let frustrated = SemanticSignalExtractor.signals(
            in: "This is still broken and I am stuck on the same error, it keeps happening."
        )
        XCTAssertEqual(values(frustrated, .tone), ["frustrated"])

        let neutral = SemanticSignalExtractor.signals(
            in: "The report covers the second quarter numbers for the finance team."
        )
        XCTAssertTrue(values(neutral, .tone).isEmpty, "tone must never be inferred without cues")
    }

    func testIntentClassification() {
        let instruct = SemanticSignalExtractor.signals(
            in: "Fix the countdown timer. Update the color to red. Make sure the tests pass."
        )
        XCTAssertEqual(values(instruct, .intent), ["instruct"])

        let ask = SemanticSignalExtractor.signals(
            in: "How does the sync engine decide which record wins when both changed?"
        )
        XCTAssertEqual(values(ask, .intent), ["ask"])

        let reflect = SemanticSignalExtractor.signals(
            in: "The migration went smoothly yesterday and the team seemed happy with the outcome overall."
        )
        XCTAssertEqual(values(reflect, .intent), ["reflect"])
    }

    func testEveryChunkGetsExactlyOneIntent() {
        let signals = SemanticSignalExtractor.signals(in: "Short note about the roadmap for next quarter.")
        XCTAssertEqual(values(signals, .intent).count, 1)
    }

    func testEmptyTextYieldsNoSignals() {
        XCTAssertTrue(SemanticSignalExtractor.signals(in: "   ").isEmpty)
    }
}
