// EditInstructionClassifierTests.swift
// OrttaaiTests

import XCTest
@testable import Orttaai

final class EditInstructionClassifierTests: XCTestCase {
    func testInstructionsAreRecognised() {
        let instructions = [
            "Make this shorter.",
            "make it more formal",
            "Fix the grammar.",
            "Fix the spelling",
            "Rewrite this as a friendly email.",
            "Translate to French.",
            "Shorten.",
            "Summarize",
            "Turn this into a bulleted list.",
            "Please make this more concise.",
            "Can you fix the typos?",
            "Okay, now change the tone to casual.",
            "Remove the last sentence.",
            "Put this in a numbered list",
            "Clean this up.",
            "Fix it",
            "Summarize in three bullets",
            "Rewrite for a five year old",
            "Summarize the text"
        ]
        for instruction in instructions {
            XCTAssertTrue(EditInstructionClassifier.isInstruction(instruction), instruction)
        }
    }

    func testOrdinaryDictationIsNotAnInstruction() {
        let dictation = [
            "Thanks, see you on Monday.",
            "Make sure you call the client tomorrow.",
            "Add milk and eggs",
            "Change of plans, we leave at nine.",
            "I will fix it tomorrow.",
            "The meeting has moved to four.",
            "Please",
            "",
            "Fix",
            "Make this shorter and then also send a copy over to Dana and Priya before the end of the day tomorrow.",
            // Everyday sentences with "it", "this" or "them".
            "Make it happen by Friday.",
            "Put it on the calendar.",
            "Add them to the invite.",
            "Write it down.",
            "Turn it off.",
            "Make this happen.",
            "Add this to my cart.",
            "Fix it before the demo tomorrow.",
            // Searches that start with an edit verb.
            "translate hello into Spanish",
            "summarize the history of Rome",
            "rewrite rules for nginx"
        ]
        for words in dictation {
            XCTAssertFalse(EditInstructionClassifier.isInstruction(words), words)
        }
    }
}
