// ChatMarkdownTests.swift
// OrttaaiTests

import XCTest
@testable import Orttaai

final class ChatMarkdownTests: XCTestCase {
    func testReplyFromTheScreenshotBecomesHeadingsAndLists() {
        let reply = """
        Based on the writing samples, here is an analysis:

        ### Writing Patterns and Habits

        *   **Focus on Inquiry:** Your recent writing often asks questions.
        *   **Informal Tone:** The language is quite casual.

        ### Favourite Phrases
        - "I'm just wondering what you think."
        """
        let blocks = ChatMarkdown.parse(reply)

        XCTAssertEqual(blocks.count, 5)
        XCTAssertEqual(blocks[0], .paragraph("Based on the writing samples, here is an analysis:"))
        XCTAssertEqual(blocks[1], .heading(level: 3, text: "Writing Patterns and Habits"))
        guard case .list(let ordered, let items) = blocks[2] else { return XCTFail("Expected a list") }
        XCTAssertFalse(ordered)
        XCTAssertEqual(items.map(\.text), ["**Focus on Inquiry:** Your recent writing often asks questions.", "**Informal Tone:** The language is quite casual."])
        XCTAssertEqual(blocks[3], .heading(level: 3, text: "Favourite Phrases"))
    }

    func testTableWithAlignment() {
        let blocks = ChatMarkdown.parse("""
        | Habit | Count | Share |
        |:------|:-----:|------:|
        | Questions | 18 | 40% |
        | Requests | 27 |
        """)
        XCTAssertEqual(blocks, [
            .table(
                header: ["Habit", "Count", "Share"],
                alignments: [.leading, .center, .trailing],
                rows: [["Questions", "18", "40%"], ["Requests", "27", ""]]
            ),
        ])
    }

    func testCodeFenceOrderedListQuoteAndRule() {
        let blocks = ChatMarkdown.parse("""
        1. First step
        2. Second step
           continues here

        > Keep it short.

        ---

        ```swift
        let x = 1
        ```
        """)
        XCTAssertEqual(blocks, [
            .list(ordered: true, items: [
                .init(marker: "1.", text: "First step", depth: 0),
                .init(marker: "2.", text: "Second step continues here", depth: 0),
            ]),
            .quote("Keep it short."),
            .rule,
            .code(language: "swift", code: "let x = 1"),
        ])
    }

    func testNestedBulletsAndAnUnfinishedFenceWhileStreaming() {
        let blocks = ChatMarkdown.parse("""
        - Top
          - Nested
        ```python
        print("hi")
        """)
        XCTAssertEqual(blocks, [
            .list(ordered: false, items: [
                .init(marker: "•", text: "Top", depth: 0),
                .init(marker: "•", text: "Nested", depth: 1),
            ]),
            .code(language: "python", code: "print(\"hi\")"),
        ])
    }

    func testHashWithoutASpaceIsNotAHeading() {
        XCTAssertEqual(ChatMarkdown.parse("#hashtag stays text"), [.paragraph("#hashtag stays text")])
    }
}
