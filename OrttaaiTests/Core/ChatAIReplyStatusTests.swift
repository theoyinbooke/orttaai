// ChatAIReplyStatusTests.swift
// OrttaaiTests

import XCTest
@testable import Orttaai

final class ChatAIReplyStatusTests: XCTestCase {
    func testWaitMovesThroughItsStages() {
        XCTAssertEqual(ChatAIReplyStatus.line(elapsed: 0, thinking: false, thought: nil), "Reading your message")
        XCTAssertEqual(ChatAIReplyStatus.line(elapsed: 3, thinking: false, thought: nil), "Working on your reply")
        XCTAssertEqual(ChatAIReplyStatus.line(elapsed: 8, thinking: false, thought: nil), "Longer chats take a little more time")
        XCTAssertEqual(ChatAIReplyStatus.line(elapsed: 40, thinking: false, thought: nil), "Still working on it")
    }

    func testThinkingModelsSayTheyAreThinking() {
        XCTAssertEqual(ChatAIReplyStatus.line(elapsed: 2, thinking: true, thought: nil), "Thinking")
        XCTAssertEqual(ChatAIReplyStatus.line(elapsed: 9, thinking: true, thought: nil), "Thinking it through")
        XCTAssertEqual(ChatAIReplyStatus.line(elapsed: 25, thinking: true, thought: nil), "Still thinking")
    }

    func testLatestFinishedThoughtReplacesTheStage() {
        let thinking = "The user wants a short email. I should keep their tone. Start with a gree"
        XCTAssertEqual(ChatAIReplyStatus.line(elapsed: 5, thinking: true, thought: thinking), "I should keep their tone")
    }

    func testThoughtStillBeingWrittenIsNotShown() {
        XCTAssertNil(ChatAIReplyStatus.latestThought(in: "The user wants a short"))
        XCTAssertEqual(ChatAIReplyStatus.line(elapsed: 2, thinking: true, thought: "The user wants a short"), "Thinking")
    }

    func testLongThoughtIsCutToOneLine() {
        let long = String(repeating: "word ", count: 40) + "end."
        let line = try? XCTUnwrap(ChatAIReplyStatus.latestThought(in: long))
        XCTAssertEqual(line?.count, 90)
        XCTAssertTrue(line?.hasSuffix("…") == true)
    }

    func testInlineThinkTagsAreSplitFromTheReply() {
        XCTAssertEqual(ChatAIReplyStatus.splitInlineThinking("<think>Plan the reply").visible, "")
        XCTAssertEqual(ChatAIReplyStatus.splitInlineThinking("<think>Plan the reply").thought, "Plan the reply")
        let done = ChatAIReplyStatus.splitInlineThinking("<think>Plan it.</think>Hello there")
        XCTAssertEqual(done.visible, "Hello there")
        XCTAssertEqual(done.thought, "Plan it.")
        XCTAssertEqual(ChatAIReplyStatus.splitInlineThinking("Hello").visible, "Hello")
        XCTAssertNil(ChatAIReplyStatus.splitInlineThinking("Hello").thought)
    }
}
