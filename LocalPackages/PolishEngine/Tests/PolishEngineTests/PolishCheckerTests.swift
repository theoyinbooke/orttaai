@testable import PolishEngine
import Testing

/// The checker decides whether S1-mini's text replaces the rules text. The
/// accepted cases are S1-mini's real output on an iPhone 17 Pro Max.
struct PolishCheckerTests {
    static let short = "So I was thinking we should move the team meeting to thursday no wait friday at 3 pm because sarah is out on thursday and I also need to finish the budget for the q4 review before then can you let everyone know and book the big room on the second floor"
    static let shortPolished = "So I was thinking we should move the team meeting to Friday at 3pm, because Sarah is out on Thursday. And I also need to finish the budget for the Q4 review before then. Can you let everyone know and book the big room on the second floor?"

    static let long = "Okay so a few things from today's call with the vendor first they confirmed the new pricing is 4,200 dollars a month starting in january which is about 15 percent more than what we pay now second they can't do the integration until the end of february because their engineering team is tied up with another launch and third they asked if we want the premium support tier which would add another 600 dollars a month I told them I'd get back to them by next wednesday so here's what I think we should do"
    static let longPolished = """
    Okay, so a few things from today's call with the vendor:

    1. They confirmed the new pricing is $4,200 a month starting in January, which is about 15% more than what we pay now.
    2. They can't do the integration until the end of February because their engineering team is tied up with another launch.
    3. They asked if we want the premium support tier, which would add another $600 a month.

    I told them I'd get back to them by next Wednesday, so here's what I think we should do.
    """

    @Test("S1-mini's clean-ups pass: punctuation, capitals, a list, digits and symbols")
    func acceptsRealPolish() {
        #expect(PolishChecker.check(Self.shortPolished, against: Self.short).text == Self.shortPolished)
        #expect(PolishChecker.check(Self.longPolished, against: Self.long).text != nil)
    }

    @Test("Spoken numbers written as digits are fine; a number that was said can't go missing")
    func numbersSurvive() {
        let input = "send them 4,200 dollars by the 15th and call 600 people"
        #expect(PolishChecker.check("Send them $4200 by the 15th and call 600 people.", against: input).text != nil)
        #expect(PolishChecker.check("Send them $4200 by the 15th and call people.", against: input) == .rejected(.lostNumber("600")))
    }

    @Test("Answering instead of cleaning up is rejected")
    func rejectsAnswers() {
        let verdict = PolishChecker.check("The capital of France is Paris.", against: "what's the capital of france")
        #expect(verdict == .rejected(.inventedWords(["paris"])))
    }

    @Test("Several added words are rejected, a written-out contraction isn't")
    func addedWords() {
        let input = "im gonna be late tell the team"
        #expect(PolishChecker.check("I am going to be late. Tell the team.", against: input).text != nil)
        let padded = "I'm going to be late, please inform the whole team."
        guard case .rejected(.inventedWords) = PolishChecker.check(padded, against: input) else {
            Issue.record("Expected added words to be rejected")
            return
        }
    }

    @Test("Empty, much shorter or much longer text falls back")
    func lengthBand() {
        let input = Self.short
        #expect(PolishChecker.check("   ", against: input) == .rejected(.empty))
        #expect(PolishChecker.check("Move the meeting to Friday.", against: input) == .rejected(.tooShort))
        #expect(PolishChecker.check(String(repeating: input + " ", count: 2), against: input) == .rejected(.tooLong))
    }

    @Test("A list or break from the rules can't be polished away")
    func keepsBreaks() {
        let input = "I have two things to share with you.\n1. This app is working.\n2. It's able to format things for me and I really like it."
        let flattened = "I have two things to share with you. This app is working, and it's able to format things for me, and I really like it."
        #expect(PolishChecker.check(flattened, against: input) == .rejected(.lostBreaks))
        let kept = "I have two things to share with you:\n1. This app is working.\n2. It's able to format things for me, and I really like it."
        #expect(PolishChecker.check(kept, against: input).text == kept)
    }

    @Test("Wrapping the model adds is removed")
    func cleansWrapping() {
        #expect(PolishChecker.cleaned("\"Hello there.\"", input: "hello there") == "Hello there.")
        #expect(PolishChecker.cleaned("```\nHello there.\n```", input: "hello there") == "Hello there.")
        #expect(PolishChecker.cleaned("It\u{2019}s fine.", input: "its fine") == "It's fine.")
    }
}
