import Foundation
@testable import PolishEngine
import Testing

/// The paragraph-by-paragraph logic, with a stand-in for the model; and, when
/// S1-mini's file is on this Mac, the real model on a short dictation.
struct S1MiniPolisherTests {
    let later = ContinuousClock.now.advanced(by: .seconds(60))

    @Test("The prompt is S1-mini's trained format, thinking off")
    func promptFormat() {
        let prompt = S1MiniPrompt.prompt(for: "um send it tomorrow")
        #expect(prompt.hasPrefix("<|im_start|>system\n" + S1MiniPrompt.instructions))
        #expect(prompt.contains("<|im_start|>user\n[Styling: semi-formal] [Structure: lists] [Context: general]\num send it tomorrow<|im_end|>"))
        #expect(prompt.hasSuffix("<|im_start|>assistant\n<think>\n\n</think>\n\n"))
    }

    @Test("Each paragraph is polished on its own and joined back")
    func paragraphsSeparately() {
        var seen: [String] = []
        let outcome = ParagraphPolish.polish("um so the first part is done\n\nand uh the second part is next", deadline: later) { paragraph, _ in
            seen.append(paragraph)
            return paragraph == "um so the first part is done" ? "So the first part is done." : "And the second part is next."
        }
        #expect(seen.count == 2)
        #expect(outcome.text == "So the first part is done.\n\nAnd the second part is next.")
        #expect(outcome.polished == 2)
        #expect(outcome.applied)
    }

    @Test("A paragraph whose answer fails the check keeps its rules text; the others are still polished")
    func rejectedParagraphKept() {
        let outcome = ParagraphPolish.polish("we pay 4200 a month for it\n\nand that is fine for now", deadline: later) { paragraph, _ in
            paragraph.hasPrefix("we") ? "We pay a lot a month for it." : "And that is fine for now."
        }
        #expect(outcome.text == "we pay 4200 a month for it\n\nAnd that is fine for now.")
        #expect(outcome.polished == 1)
        #expect(outcome.notes == ["lost the number 4200"])
    }

    @Test("Out of time: the rest keeps its rules text")
    func outOfTime() {
        var calls = 0
        let outcome = ParagraphPolish.polish("the first paragraph is here\n\nthe second paragraph is here", deadline: later) { _, _ in
            calls += 1
            return calls == 1 ? "The first paragraph is here." : nil
        }
        #expect(outcome.text == "The first paragraph is here.\n\nthe second paragraph is here")
        #expect(outcome.notes == ["out of time"])
    }

    @Test("A deadline already passed polishes nothing")
    func pastDeadline() {
        let outcome = ParagraphPolish.polish("nothing will change in this text", deadline: .now) { _, _ in
            Issue.record("should not generate")
            return nil
        }
        #expect(outcome.text == "nothing will change in this text")
        #expect(!outcome.applied)
    }

    @Test("Short paragraphs are left alone and not counted")
    func shortParagraphs() {
        let outcome = ParagraphPolish.polish("Thanks.\n\nsee you soon then", deadline: later) { _, _ in "See you soon then." }
        #expect(outcome.text == "Thanks.\n\nSee you soon then.")
        #expect(outcome.paragraphs == 1)
    }

    @Test("Your words must come through unchanged")
    func protectsWords() {
        let outcome = ParagraphPolish.polish("tell temi that Meetumo is live now", protecting: ["Meetumo"], deadline: later) { _, _ in
            "Tell Temi that Metumo is live now."
        }
        #expect(!outcome.applied)
        #expect(outcome.notes == ["changed Meetumo, one of your words"])
    }

    @Test("The time budget grows with length and is capped")
    func budget() {
        #expect(S1MiniPolisher.timeBudget(forWords: 0) == .milliseconds(1_000))
        #expect(S1MiniPolisher.timeBudget(forWords: 200) == .milliseconds(2_200))
        #expect(S1MiniPolisher.timeBudget(forWords: 5_000) == .milliseconds(8_000))
    }

    /// The real model, when it's installed on this Mac.
    @Test("S1-mini on this Mac's GPU cleans up a short dictation in well under a second",
          .enabled(if: FileManager.default.fileExists(atPath: S1MiniPolisherTests.localModel)))
    func realModel() async throws {
        let polisher = S1MiniPolisher(modelPath: Self.localModel)
        try await polisher.load()
        let started = ContinuousClock.now
        let outcome = try await polisher.polish("um so I think we should uh move the meeting to friday", deadline: .now.advanced(by: .seconds(5)))
        let elapsed = started.duration(to: .now)
        #expect(outcome.applied)
        #expect(!outcome.text.lowercased().contains("um "))
        #expect(elapsed < .seconds(1))
    }

    /// A paragraph too long for the kept context gets one of its own, and its whole answer.
    @Test("A paragraph longer than the kept context is answered in full",
          .enabled(if: FileManager.default.fileExists(atPath: S1MiniPolisherTests.localModel)))
    func longParagraph() throws {
        let runner = try LlamaRunner(path: Self.localModel, contextLength: 256, maxContextLength: 2_048)
        let paragraph = """
            so um the plan for this week is pretty simple we want to get the new onboarding flow out to \
            everyone by thursday and then spend friday on the bugs that came in from the beta testers uh \
            the biggest one is the sync issue where notes created on the phone take a few minutes to show \
            up on the mac and I think that is because the push notification is not waking the app so we \
            should look at the background refresh settings first and then maybe the subscription itself \
            um the second thing is the pricing page which still says the old annual price and that needs \
            to change before the launch email goes out on monday
            """
        let prompt = S1MiniPrompt.prompt(for: paragraph)
        let maxTokens = S1MiniPrompt.maxTokens(for: paragraph)
        #expect(runner.tokenCount(prompt) + maxTokens > runner.contextLength)
        let output = try runner.generate(prompt: prompt, maxTokens: maxTokens)
        #expect(!output.hitLimit)
        #expect(output.generatedTokens > 100)
    }

    /// Where Orttaai's model folder keeps S1-mini on this Mac.
    static let localModel = "/Volumes/MyExtSSD/Huggingface/models/superwhisper/s1-mini-GGUF/s1-mini-q4_k_m.gguf"
}
