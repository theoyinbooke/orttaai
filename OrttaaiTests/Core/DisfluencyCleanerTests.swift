// DisfluencyCleanerTests.swift
// OrttaaiTests

import XCTest
@testable import Orttaai

@MainActor
final class DisfluencyCleanerTests: XCTestCase {
    func testCleansFillersStuttersAndPronounI() {
        let cases: [(input: String, expected: String)] = [
            ("And, um, remember", "And remember"),
            ("so um um to avoid", "so to avoid"),
            ("and And that", "and that"),
            ("the the memory", "the memory"),
            ("i'm sure", "I'm sure"),
            // fillers
            ("Um, I think so", "I think so"),
            ("Um, i think so", "I think so"),
            ("Well um, yes", "Well yes"),
            ("I went, uh the store", "I went the store"),
            ("It was fine, uhm.", "It was fine."),
            ("Okay. Um. Then we ship.", "Okay. Then we ship."),
            ("Okay. Uh, then we ship.", "Okay. Then we ship."),
            ("okay. umm then we ship.", "okay. Then we ship."),
            ("we should erm go", "we should go"),
            ("Um... the plan", "The plan"),
            ("so uh iPhone sales", "so iPhone sales"),
            ("Um, iPhone sales", "iPhone sales"),
            // stutters
            ("to to avoid it", "to avoid it"),
            ("the, the memory", "the memory"),
            ("of of the plan and and the rest", "of the plan and the rest"),
            ("in in the box and a a test", "in the box and a test"),
            ("for for you", "for you"),
            ("the the the end", "the end"),
            ("The the plan", "The plan"),
            // pronoun I
            ("i think i'll go and i've seen i'd say", "I think I'll go and I've seen I'd say"),
            ("so do i, really", "so do I, really"),
            ("i’m sure", "I’m sure"),
            ("then i said no", "then I said no")
        ]
        for (input, expected) in cases {
            XCTAssertEqual(DisfluencyCleaner.clean(input).text, expected, "input: \(input)")
        }
    }

    func testLeavesLegitimateTextUnchanged() {
        let unchanged = [
            "no no no",
            "very very very",
            "that that's",
            "UM",
            "The UM protocol",
            "We should UH go",
            "i.e. this",
            "for i in range(10)",
            "had had",
            "the um-brella",
            "the uh-oh moment",
            "uh huh, sounds good",
            "to-do list",
            "a to-to plan",
            "section i.",
            "section i and section ii",
            "i++",
            "while i < 10",
            "let i = 0",
            "i, j, k",
            "i j",
            "x[i] is set",
            "the term is fine",
            "you you are great",
            "it it works",
            "Vitamin A and a plan",
            "the theory of the thing",
            "Um.",
            "um"
        ]
        for input in unchanged {
            let result = DisfluencyCleaner.clean(input)
            XCTAssertEqual(result.text, input, "input: \(input)")
            XCTAssertTrue(result.changes.isEmpty, "input: \(input)")
        }
    }

    func testReportsWhatItChanged() {
        let result = DisfluencyCleaner.clean("Well, um, i think the the plan, uh, works")
        XCTAssertEqual(result.text, "Well I think the plan works")
        XCTAssertEqual(
            result.changes,
            [
                "Disfluency: removed 2 fillers",
                "Disfluency: collapsed 1 repeated word",
                "Disfluency: capitalized 1 'i'"
            ]
        )
    }

    func testMultilineTextKeepsItsLineBreaks() {
        XCTAssertEqual(DisfluencyCleaner.clean("First line.\nUm, second line.").text, "First line.\nSecond line.")
    }
}
