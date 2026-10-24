// LearningVisibilityTests.swift
// OrttaaiTests

import GRDB
import XCTest
@testable import Orttaai

@MainActor
final class LearningVisibilityTests: XCTestCase {
    func testEditChecksKeepTheNewestThirty() throws {
        let db = try DatabaseManager(dbQueue: try DatabaseQueue(path: ":memory:"))
        let start = Date(timeIntervalSince1970: 1_000)
        for index in 0..<35 {
            try db.insertEditCheck(outcome: .noChange, appName: "Claude", learnedCount: 0, at: start.addingTimeInterval(Double(index)))
        }
        try db.insertEditCheck(outcome: .learned, appName: "Notes", learnedCount: 2, at: start.addingTimeInterval(100))

        let checks = try db.fetchEditChecks()
        XCTAssertEqual(checks.count, DatabaseManager.maxEditChecks)
        XCTAssertEqual(checks.first?.checkOutcome, .learned)
        XCTAssertEqual(checks.first?.learnedCount, 2)
        XCTAssertEqual(checks.first?.appName, "Notes")
    }

    func testEveryOutcomeHasWordsAndAnIcon() {
        for outcome in EditCheckOutcome.allCases {
            XCTAssertFalse(MemoryView.description(for: outcome, learned: 1).isEmpty)
            XCTAssertFalse(MemoryView.symbol(for: outcome).isEmpty)
        }
    }

    func testAISuggestionLabelsAreStripped() {
        XCTAssertEqual(AppleFoundationLearningAnalyzer.strippingLabel("Misheard term: VASEL"), "VASEL")
        XCTAssertEqual(AppleFoundationLearningAnalyzer.strippingLabel("Preferred term: \"Superbase\""), "Superbase")
        XCTAssertEqual(AppleFoundationLearningAnalyzer.strippingLabel("Short trigger: my address"), "my address")
        XCTAssertEqual(AppleFoundationLearningAnalyzer.strippingLabel("Orttaai"), "Orttaai")
    }

    func testAISuggestionsMustHaveBeenSaidAndSoundAlike() {
        let parsed = AppleLearningResponse(
            dictionary: [
                AppleDictionarySuggestion(source: "Misheard term: otta ai", target: "Preferred term: Orttaai", confidence: 0.8, evidence: nil),
                AppleDictionarySuggestion(source: "ASNA", target: "Superbase", confidence: 0.7, evidence: nil),
                AppleDictionarySuggestion(source: "VASEL", target: "Virtual Asset Exchange", confidence: 0.8, evidence: nil),
                AppleDictionarySuggestion(source: "Kubernets", target: "Kubernetes", confidence: 0.6, evidence: nil),
            ],
            snippets: [
                AppleSnippetSuggestion(trigger: "system delay", expansion: "troubleshooting guide for intermittent delays", confidence: 0.9, evidence: nil),
                AppleSnippetSuggestion(trigger: "sign off", expansion: "Thanks so much, talk soon", confidence: 0.7, evidence: nil),
            ]
        )
        let history = [
            "I was testing the fastest model ever in otta ai today.",
            "ASNA and VASEL came up in the meeting. Thanks so much, talk soon",
            "Thanks so much, talk soon",
        ]
        let drafts = AppleFoundationLearningAnalyzer.sanitize(parsed: parsed, history: history, existingDictionary: [], existingSnippets: [])

        XCTAssertEqual(drafts.filter { $0.type == .dictionary }.map(\.candidateSource), ["otta ai"], "Kubernets was never said; ASNA and VASEL don't sound like their targets")
        XCTAssertEqual(drafts.filter { $0.type == .dictionary }.map(\.candidateTarget), ["Orttaai"])
        XCTAssertEqual(drafts.filter { $0.type == .snippet }.map(\.candidateTarget), ["Thanks so much, talk soon"])
    }
}
