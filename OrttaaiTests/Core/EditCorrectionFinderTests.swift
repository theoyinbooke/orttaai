// EditCorrectionFinderTests.swift
// OrttaaiTests

import XCTest
@testable import Orttaai

final class EditCorrectionFinderTests: XCTestCase {
    /// The field right after `inserted` was dictated at the end of `prefix`,
    /// with the caret after it, and the same field after `edit`.
    private func corrections(
        prefix: String = "",
        inserted: String,
        suffix: String = "",
        edited: String
    ) -> [EditCorrection] {
        let before = prefix + inserted + suffix
        let caret = (prefix + inserted).utf16.count
        return EditCorrectionFinder.corrections(inserted: inserted, before: before, insertionEndUTF16: caret, after: edited)
    }

    private func pair(_ heard: String, _ corrected: String) -> EditCorrection {
        EditCorrection(heard: heard, corrected: corrected)
    }

    func testMisheardNameSplitIntoWordsIsLearned() {
        XCTAssertEqual(
            corrections(inserted: "Please remind me to call for Lash a day tomorrow.",
                        edited: "Please remind me to call Folasade tomorrow."),
            [pair("for Lash a day", "Folasade")]
        )
    }

    func testMisspelledNameIsLearned() {
        XCTAssertEqual(
            corrections(inserted: "Olen Ruij is presenting the roadmap.", edited: "Olanrewaju is presenting the roadmap."),
            [pair("Olen Ruij", "Olanrewaju")]
        )
        XCTAssertEqual(
            corrections(inserted: "Dear Mr. Adayemi, the invoice is overdue.", edited: "Dear Mr. Adeyemi, the invoice is overdue."),
            [pair("Adayemi", "Adeyemi")]
        )
    }

    func testTechnicalTermIsLearned() {
        XCTAssertEqual(
            corrections(inserted: "grab migrations run inside a write transaction.",
                        edited: "GRDB migrations run inside a write transaction."),
            [pair("grab", "GRDB")]
        )
    }

    func testCaseFixIsLearnedOnlyForTermsWithInnerCapitals() {
        XCTAssertEqual(
            corrections(inserted: "push the branch to github today", edited: "push the branch to GitHub today"),
            [pair("github", "GitHub")]
        )
        XCTAssertEqual(corrections(inserted: "hello there, team", edited: "Hello there, team"), [])
    }

    func testOrdinaryEditsAreIgnored() {
        // A synonym.
        XCTAssertEqual(corrections(inserted: "It was a big release.", edited: "It was a large release."), [])
        // A different term, not a misheard one.
        XCTAssertEqual(corrections(inserted: "Use the cat command here.", edited: "Use the kubectl command here."), [])
        // A rewrite of the dictation.
        XCTAssertEqual(
            corrections(inserted: "We should meet Adayemi on Friday.", edited: "Let's push the Okonkwo meeting to Monday."),
            []
        )
        // Nothing changed.
        XCTAssertEqual(corrections(inserted: "Ship it on Friday.", edited: "Ship it on Friday."), [])
    }

    func testTextTypedAfterTheDictationIsIgnored() {
        XCTAssertEqual(corrections(inserted: "Thanks Sarah.", edited: "Thanks Sarah. Talk soon, Olanrewaju"), [])
    }

    func testFixInsideTheDictationIsKeptWhenMoreTextWasTypedAfter() {
        XCTAssertEqual(
            corrections(inserted: "Ask Adayemi about the deck.", edited: "Ask Adeyemi about the deck. Thanks!"),
            [pair("Adayemi", "Adeyemi")]
        )
    }

    func testEditsOutsideTheDictatedTextAreIgnored() {
        XCTAssertEqual(
            corrections(prefix: "Dear Jon, ", inserted: "the report is attached.", edited: "Dear Jonathon, the report is attached."),
            []
        )
    }

    func testTheOccurrenceAtTheCaretIsTheDictation() {
        let earlier = "Call Adayemi. "
        let inserted = "Call Adayemi."
        let before = earlier + inserted
        let after = earlier + "Call Adeyemi."
        XCTAssertEqual(
            EditCorrectionFinder.corrections(inserted: inserted, before: before, insertionEndUTF16: before.utf16.count, after: after),
            [pair("Adayemi", "Adeyemi")]
        )
        // The earlier, identical sentence was not the dictation.
        let editedEarlier = "Call Adeyemi. " + inserted
        XCTAssertEqual(
            EditCorrectionFinder.corrections(inserted: inserted, before: before, insertionEndUTF16: before.utf16.count, after: editedEarlier),
            []
        )
    }

    func testCaretIsMeasuredInUTF16() {
        XCTAssertEqual(
            corrections(prefix: "🎉🎉 Great news! ", inserted: "Folashade joined the team.", edited: "🎉🎉 Great news! Folasade joined the team."),
            [pair("Folashade", "Folasade")]
        )
    }

    func testDictationTheAppChangedIsNotLocated() {
        XCTAssertEqual(
            EditCorrectionFinder.corrections(inserted: "Call Adayemi.", before: "Something else entirely.", insertionEndUTF16: 24, after: "Call Adeyemi."),
            []
        )
    }
}
