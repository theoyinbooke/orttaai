// ExpressNumberFormatterTests.swift
// OrttaaiTests

import XCTest
@testable import Orttaai

final class ExpressNumberFormatterTests: XCTestCase {
    private func format(_ text: String) -> String {
        ExpressNumberFormatter.format(text)
    }

    // MARK: - Digits read one by one

    func testSevenSpokenDigitsBecomeALocalPhoneNumber() {
        XCTAssertEqual(
            format("Call me back at five five five zero one four three after 3 pm."),
            "Call me back at 555-0143 after 3 pm."
        )
    }

    func testTenSpokenDigitsBecomeAFullPhoneNumber() {
        XCTAssertEqual(format("It's four one five five five five zero one four three."), "It's 415-555-0143.")
    }

    func testOhInsideADigitRunIsZero() {
        XCTAssertEqual(format("The code is four oh four two."), "The code is 4042.")
    }

    func testShortDigitRunsStayWords() {
        XCTAssertEqual(format("Pick one two or three of them."), "Pick one two or three of them.")
    }

    // MARK: - Times

    func testDottedTimeBeforeMeridiemGetsAColon() {
        XCTAssertEqual(format("Our flight leaves at 6.45 a.m. on Tuesday."), "Our flight leaves at 6:45 a.m. on Tuesday.")
        XCTAssertEqual(format("See you at 10.30pm."), "See you at 10:30pm.")
    }

    func testDottedTimeAfterATimePrepositionGetsAColon() {
        XCTAssertEqual(
            format("Flight 214 departs at 6.45 a.m. and lands in Denver at 8.05 local time."),
            "Flight 214 departs at 6:45 a.m. and lands in Denver at 8:05 local time."
        )
        XCTAssertEqual(format("Back around 2.15 this afternoon."), "Back around 2:15 this afternoon.")
    }

    func testDottedNumberAfterAPrepositionWithoutATimeWordStaysADecimal() {
        XCTAssertEqual(format("Interest rates sat at 4.25 percent."), "Interest rates sat at 4.25 percent.")
        XCTAssertEqual(format("It closed at 3.15 yesterday."), "It closed at 3.15 yesterday.")
    }

    func testDecimalsWithoutMeridiemAreLeftAlone() {
        XCTAssertEqual(format("Rates fell to 4.25 percent over 26.2 miles."), "Rates fell to 4.25 percent over 26.2 miles.")
        XCTAssertEqual(format("Version 1.11.1 shipped."), "Version 1.11.1 shipped.")
    }

    func testSpokenHourBeforeMeridiem() {
        XCTAssertEqual(format("Call me after three pm."), "Call me after 3 pm.")
        XCTAssertEqual(format("It starts at seven P.M. sharp."), "It starts at 7 P.M. sharp.")
    }

    func testSpokenHourAndMinutesBeforeMeridiem() {
        XCTAssertEqual(format("Moved to ten thirty am."), "Moved to 10:30 am.")
        XCTAssertEqual(format("Leaves at six forty-five a.m."), "Leaves at 6:45 a.m.")
        XCTAssertEqual(format("Lands at eight oh five pm."), "Lands at 8:05 pm.")
    }

    func testSpokenTimeWithoutMeridiemStaysWords() {
        XCTAssertEqual(format("Meet me at ten thirty tomorrow."), "Meet me at ten thirty tomorrow.")
    }

    // MARK: - Money and percentages

    func testSpokenAmountWithDollarsBecomesCurrency() {
        XCTAssertEqual(
            format("The invoice is two thousand four hundred and fifty dollars."),
            "The invoice is $2,450."
        )
        XCTAssertEqual(format("It costs forty dollars."), "It costs $40.")
    }

    func testSpokenPercent() {
        XCTAssertEqual(format("Startup time dropped by thirty percent."), "Startup time dropped by 30%.")
        XCTAssertEqual(format("I'm one hundred percent sure."), "I'm 100% sure.")
    }

    // MARK: - Large counts

    func testCountsWithAScaleWordBecomeDigits() {
        XCTAssertEqual(format("We need two hundred and fifty chairs."), "We need 250 chairs.")
        XCTAssertEqual(format("We onboarded one thousand eight hundred forty-seven users."), "We onboarded 1,847 users.")
    }

    func testSmallCountsStayWords() {
        XCTAssertEqual(
            format("Twelve of the fifteen pairs met twice, with forty tables."),
            "Twelve of the fifteen pairs met twice, with forty tables."
        )
    }

    // MARK: - Dates

    func testOrdinalAfterAMonth() {
        XCTAssertEqual(format("It is due on March fifteenth."), "It is due on March 15th.")
        XCTAssertEqual(format("Tuesday, October twenty-eighth."), "Tuesday, October 28th.")
        XCTAssertEqual(format("From April third to April seventeenth."), "From April 3rd to April 17th.")
    }

    func testDateOrderIsLeftAsSpoken() {
        XCTAssertEqual(format("Moved from the 3rd of March to the 17th of April."), "Moved from the 3rd of March to the 17th of April.")
    }

    func testOrdinalBeforeOfMonth() {
        XCTAssertEqual(format("She turns seven on the twenty eighth of September."), "She turns seven on the 28th of September.")
    }

    func testOrdinalsOutsideDatesStayWords() {
        XCTAssertEqual(format("After the first few sessions, the second lesson runs long."), "After the first few sessions, the second lesson runs long.")
        XCTAssertEqual(format("May the first one win."), "May the first one win.")
        XCTAssertEqual(format("You may first check the logs."), "You may first check the logs.")
    }

    // MARK: - Untouched text

    func testTextWithoutNumberWordsIsUnchanged() {
        let text = "Send the contract draft to Folasade and copy the legal team."
        XCTAssertEqual(format(text), text)
    }

    func testRealVoiceOutputsFromTheEval() {
        XCTAssertEqual(
            format("The invoice is two thousand four hundred and fifty dollars and it is due on March fifteenth."),
            "The invoice is $2,450 and it is due on March 15th."
        )
        XCTAssertEqual(
            format("The meeting moved from April third to April seventeenth at ten thirty a.m."),
            "The meeting moved from April 3rd to April 17th at 10:30 a.m."
        )
        XCTAssertEqual(format("Book a table for six people at seven pm on Friday."), "Book a table for six people at 7 pm on Friday.")
        XCTAssertEqual(format("Our meeting moved to the 17th of April at 3.30 p.m."), "Our meeting moved to the 17th of April at 3:30 p.m.")
    }

    func testAlreadyWrittenNumbersAreUnchanged() {
        let text = "The invoice total comes to $1,250.50, due on the 15th at 3:30 pm."
        XCTAssertEqual(format(text), text)
    }
}
