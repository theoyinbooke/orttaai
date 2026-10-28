// ConversationTests.swift
// CoachCoreTests

import Foundation
import Testing
@testable import CoachCore

@Suite("Talking, not taking turns")
struct ConversationTests {
    @Test func theSceneBecomesAChatWithThePartnerAsTheAssistant() {
        let scene = CoachScene.scene(id: "scope-push")!
        let chat = CoachPartnerPrompt.chat(scene: scene, turns: [
            SceneTurn(speaker: .partner, text: scene.opening),
            SceneTurn(speaker: .you, text: "By Friday I can do one of them properly."),
        ])
        #expect(chat.first?.role == .system)
        #expect(chat.first?.content.hasPrefix(scene.partnerBrief) == true)
        #expect(chat[1].role == .user, "The person speaks first")
        #expect(chat[2] == ChatLine(.assistant, scene.opening))
        #expect(chat[3] == ChatLine(.user, "By Friday I can do one of them properly."))
    }

    @Test func moodIsReadStrictly() {
        #expect(CoachPartnerPrompt.parseMood(#"{"mood":"Weighing"}"#) == .weighing)
        #expect(CoachPartnerPrompt.parseMood(#"{"mood":"cross"}"#) == nil)
        #expect(CoachPartnerPrompt.parseMood("weighing") == nil)
        let prompt = CoachPartnerPrompt.moodPrompt(scene: CoachScene.all[1], turns: [SceneTurn(speaker: .you, text: "Hi")])
        #expect(prompt.contains("Them: Hi"))
    }

    @Test func repliesLoseANameOrQuotesTheModelAddedAnyway() {
        #expect(CoachPartnerPrompt.cleaned("Ola: \"Fine, the calendar first.\"", partnerName: "Ola") == "Fine, the calendar first.")
        #expect(CoachPartnerPrompt.cleaned("  Sure.  ", partnerName: "Ola") == "Sure.")
        #expect(CoachPartnerPrompt.cleaned("“Okay.”", partnerName: "Ola") == "Okay.")
    }

    @Test func aQuotedPhraseKeepsBothItsQuotes() {
        let reply = "\"Try your best\" is not enough. I need both features by Friday."
        #expect(CoachPartnerPrompt.cleaned(reply, partnerName: "Ola") == reply)
        #expect(CoachPartnerPrompt.spoken("\"Try your best\" is not enough.") == "Try your best\" is not enough.")
    }

    @Test func aStreamingReplyOnlyEverLosesItsStart() {
        // What has been handed on stays in step as the reply grows.
        let partial = CoachPartnerPrompt.withoutName("Ola: \"Fine, the", partnerName: "Ola")
        let whole = CoachPartnerPrompt.withoutName("Ola: \"Fine, the calendar first.\"", partnerName: "Ola")
        #expect(whole.hasPrefix(partial))
    }

    @Test func sentencesAreHandedOnAsSoonAsTheyreComplete() {
        var stream = SentenceStream()
        #expect(stream.feed("Okay, I hear").isEmpty)
        #expect(stream.feed("Okay, I hear you. If it's").isEmpty == false)
        #expect(stream.feed("Okay, I hear you. If it's one, the calendar. But version 3.5").count == 1)
        #expect(stream.feed("Okay, I hear you. If it's one, the calendar. But version 3.5 works?").isEmpty, "Waits for what follows the ?")
        #expect(stream.finish("Okay, I hear you. If it's one, the calendar. But version 3.5 works?") == "But version 3.5 works?")
        #expect(stream.finish("Okay, I hear you. If it's one, the calendar. But version 3.5 works?") == nil)

        var whole = SentenceStream()
        let text = "First one. Second one! Third"
        #expect(whole.feed(text) == ["First one.", "Second one!"])
        #expect(whole.finish(text) == "Third")
    }

    @Test func aTurnEndsAfterAPauseOnceYouveSpoken() {
        var detector = TurnDetector(pause: 0.8, patience: 12)
        var events: [TurnDetector.Event] = []
        var time = 0.0
        func run(_ level: Float, for seconds: Double) {
            let end = time + seconds
            while time < end {
                let event = detector.feed(level: level, at: time)
                if event != .none { events.append(event) }
                time += 0.1
            }
        }
        run(0.02, for: 0.5)      // the room
        run(0.4, for: 1.5)       // speaking
        run(0.02, for: 0.5)      // a breath mid-sentence
        run(0.4, for: 1.0)       // speaking again
        #expect(events == [.started])
        run(0.02, for: 1.0)      // done
        #expect(events == [.started, .ended])
    }

    @Test func aClickIsntSpeechAndSilenceEventuallyGivesUp() {
        var detector = TurnDetector(pause: 0.8, patience: 3)
        var events: [TurnDetector.Event] = []
        var time = 0.0
        for level in [Float](repeating: 0.02, count: 5) + [0.5] + [Float](repeating: 0.02, count: 30) {
            let event = detector.feed(level: level, at: time)
            if event != .none { events.append(event) }
            time += 0.1
        }
        #expect(!detector.heardSpeech)
        #expect(events.first == .gaveUp)
    }

    @Test func aNoisyRoomRaisesTheBar() {
        var detector = TurnDetector()
        var time = 0.0
        for _ in 0..<4 { _ = detector.feed(level: 0.1, at: time); time += 0.1 }
        // Hum at the room's level never counts as speech.
        var started = false
        for _ in 0..<20 { if detector.feed(level: 0.12, at: time) == .started { started = true }; time += 0.1 }
        #expect(!started)
        for _ in 0..<5 { if detector.feed(level: 0.6, at: time) == .started { started = true }; time += 0.1 }
        #expect(started)
    }
}
