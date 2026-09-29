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

    func testFillersInsideEmailsFilenamesUrlsAndQuotesAreNotRemoved() {
        let unchanged = [
            "email me at um@x.com",
            "um.txt",
            "open file.um now",
            "um: hello",
            "\"um\"",
            "(um)",
            "[uh] marker",
            "see http://x.com/um/ok",
            "the path is /usr/um",
            "use um_value here",
            "call me@uh.org"
        ]
        for input in unchanged {
            let result = DisfluencyCleaner.clean(input)
            XCTAssertEqual(result.text, input, "input: \(input)")
            XCTAssertTrue(result.changes.isEmpty, "input: \(input)")
        }
    }

    func testFillersDelimitedBySentencePunctuationAreRemoved() {
        let cases: [(input: String, expected: String)] = [
            ("Well, um; yes", "Well; yes"),
            ("Is it um? Yes", "Is it? Yes"),
            ("Wow um! Great", "Wow! Great"),
            ("So, uh. We go", "So. We go"),
            ("email um then send", "email then send")
        ]
        for (input, expected) in cases {
            XCTAssertEqual(DisfluencyCleaner.clean(input).text, expected, "input: \(input)")
        }
    }

    func testFillerRemovalKeepsNewlinesIndentationTabsAndListMarkers() {
        let cases: [(input: String, expected: String)] = [
            ("Hello um\nWorld", "Hello\nWorld"),
            ("Hello um  \nWorld", "Hello\nWorld"),
            ("Hello, um,\nWorld", "Hello\nWorld"),
            ("Hello\num", "Hello\n"),
            ("Hello\r\nx um\r\ny", "Hello\r\nx\r\ny"),
            ("um\nWorld", "\nWorld"),
            ("First.\n\nUm, second.", "First.\n\nSecond."),
            ("a\tum\tb", "a\tb"),
            ("\tum foo", "\tfoo"),
            ("  Um, i think", "  I think"),
            ("- um item\n- uh other", "- item\n- other"),
            ("1. um, the plan\n2. the rest", "1. The plan\n2. the rest"),
            ("keep  double  spaces um here", "keep  double  spaces here"),
            ("a\n\n\nb um c", "a\n\n\nb c")
        ]
        for (input, expected) in cases {
            XCTAssertEqual(DisfluencyCleaner.clean(input).text, expected, "input: \(input.debugDescription)")
        }
    }

    func testEllipsisNeverOpensASentence() {
        let cases: [(input: String, expected: String)] = [
            ("we can have... um email address", "we can have... email address"),
            ("wait... um... okay", "wait... okay"),
            ("wait\u{2026} um okay", "wait\u{2026} okay"),
            ("hold on... uh, then go", "hold on... then go"),
            ("So um... yes", "So... yes"),
            // A real sentence end still recapitalizes.
            ("we can. um email address", "we can. Email address"),
            ("really? uh so yes", "really? So yes")
        ]
        for (input, expected) in cases {
            XCTAssertEqual(DisfluencyCleaner.clean(input).text, expected, "input: \(input)")
        }
    }

    func testLongDictationWithManyFillersIsCleanedInLinearTime() {
        let sentence = "we need to ship the release um and then, uh, check the dashboard erm before lunch. "
        let text = String(repeating: sentence, count: 1_500)
        XCTAssertGreaterThan(text.split(separator: " ").count, 19_000)

        let start = Date()
        let result = DisfluencyCleaner.clean(text)
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertEqual(result.changes.first, "Disfluency: removed 4500 fillers")
        XCTAssertFalse(result.text.contains(" um "))
        XCTAssertLessThan(elapsed, 0.1)
    }
}
