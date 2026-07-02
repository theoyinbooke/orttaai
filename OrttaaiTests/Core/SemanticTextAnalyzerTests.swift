// SemanticTextAnalyzerTests.swift
// OrttaaiTests

import XCTest
@testable import Orttaai

final class SemanticTextAnalyzerTests: XCTestCase {
    func testTopicConceptsIgnoreStopwordsAndFillers() {
        let text = "I'm going to open this again because you know it's here and we should be able to do everything"

        let topics = SemanticTextAnalyzer.topicConcepts(in: text, limit: 5)
        let keys = topics.map(\.key)

        // None of the old stopword-grade "topics" survive POS filtering.
        for junk in ["going", "open", "again", "know", "here", "able", "everything"] {
            XCTAssertFalse(keys.contains(junk), "'\(junk)' should not be a topic")
        }
    }

    func testTopicConceptsExtractNounsAndMergeLemmaVariants() {
        let text = "The insight should be deeper. These insights come from the memory graph, and the memory graph keeps growing."

        let topics = SemanticTextAnalyzer.topicConcepts(in: text, limit: 6)
        let keys = topics.map(\.key)

        // "insight" and "insights" collapse into one lemma-keyed concept.
        XCTAssertEqual(keys.filter { $0.contains("insight") && !$0.contains(" ") }.count, 1)
        // The noun phrase outranks its parts.
        XCTAssertTrue(keys.contains("memory graph"), "expected 'memory graph' in \(keys)")
        XCTAssertEqual(keys.first, "memory graph")
    }

    func testNamedEntitiesFindPeopleAndCapitalizedToolNames() {
        let text = "Yesterday I asked Tim Cook about the roadmap. We should benchmark Whisper Large against the current setup."

        let entities = SemanticTextAnalyzer.namedEntities(in: text, limit: 6)
        let titles = entities.map { $0.title.lowercased() }

        XCTAssertTrue(titles.contains("tim cook"), "expected person in \(titles)")
        XCTAssertTrue(titles.contains("whisper large"), "expected tool name in \(titles)")
    }

    func testNamedEntitiesRejectSentenceStartJunk() {
        let text = "Do you want to help me to update the document? Can we make sure that the inside works."

        let entities = SemanticTextAnalyzer.namedEntities(in: text, limit: 6)
        let titles = entities.map { $0.title.lowercased() }

        XCTAssertFalse(titles.contains("do you"), "sentence starters must not become entities: \(titles)")
        XCTAssertFalse(titles.contains("can we"), "sentence starters must not become entities: \(titles)")
    }

    func testNamedEntitiesAllowSentenceLeadingContentWords() {
        let text = "Project Atlas onboarding needs a customer research plan. Project Atlas pricing work continues."

        let entities = SemanticTextAnalyzer.namedEntities(in: text, limit: 6)
        let titles = entities.map { $0.title.lowercased() }

        XCTAssertTrue(titles.contains("project atlas"), "sentence-leading entities must survive: \(titles)")
    }

    func testEmptyTextYieldsNothing() {
        XCTAssertTrue(SemanticTextAnalyzer.topicConcepts(in: "", limit: 3).isEmpty)
        XCTAssertTrue(SemanticTextAnalyzer.namedEntities(in: "", limit: 3).isEmpty)
    }
}
