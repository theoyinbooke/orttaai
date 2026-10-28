// CoachCalibration.swift
// CoachCore
//
// A judge has to earn its place. Every question comes with dictations whose
// answer is plain, two that clearly do it and two that clearly don't; a
// model is used as judge only if it gets them right, both ways.

import Foundation

public struct CalibrationExample: Sendable, Equatable {
    public var question: CoachQuestion
    public var text: String
    /// Always yes or no: the examples are chosen to be clear.
    public var expected: JudgeAnswer

    public init(_ question: CoachQuestion, _ expected: JudgeAnswer, _ text: String) {
        self.question = question
        self.expected = expected
        self.text = text
    }
}

/// How a model did on the examples.
public struct JudgeGrade: Codable, Sendable, Equatable {
    public var model: String
    /// Points over all examples: right 1, partly 0.5, wrong or no answer 0.
    public var accuracy: Double
    /// Of the examples that clearly do it, how many it said yes to.
    public var yesRecall: Double
    /// Of the examples that clearly don't, how many it said no to.
    public var noRecall: Double
    public var answered: Int
    public var total: Int
    public var msPerAnswer: Int?
    public var version: Int
    public var gradedAt: Date

    public init(model: String, accuracy: Double, yesRecall: Double, noRecall: Double, answered: Int, total: Int, msPerAnswer: Int?, version: Int, gradedAt: Date) {
        self.model = model
        self.accuracy = accuracy
        self.yesRecall = yesRecall
        self.noRecall = noRecall
        self.answered = answered
        self.total = total
        self.msPerAnswer = msPerAnswer
        self.version = version
        self.gradedAt = gradedAt
    }

    public static let passAccuracy = 0.8
    public static let passRecall = 0.7

    /// Right often enough, both ways, and answering nearly every time. A
    /// model that says the same thing to everything can't pass.
    public var passes: Bool {
        total > 0
            && Double(answered) >= Double(total) * 0.9
            && accuracy >= Self.passAccuracy
            && yesRecall >= Self.passRecall
            && noRecall >= Self.passRecall
    }

    /// Graded against the examples in use now.
    public var isCurrent: Bool { version == CoachCalibration.version }
}

public enum CoachCalibration {
    /// Bump whenever the examples change, so every model is graded again.
    public static let version = 1

    public static func grade(
        model: String,
        answers: [(example: CalibrationExample, answer: JudgeAnswer?)],
        msPerAnswer: Int?,
        at date: Date = Date()
    ) -> JudgeGrade {
        var points = 0.0
        var yesHits = 0, yesTotal = 0, noHits = 0, noTotal = 0, answered = 0
        for (example, answer) in answers {
            if answer != nil { answered += 1 }
            if example.expected == .yes { yesTotal += 1 } else { noTotal += 1 }
            switch answer {
            case example.expected?:
                points += 1
                if example.expected == .yes { yesHits += 1 } else { noHits += 1 }
            case .partly?:
                points += 0.5
            default:
                break
            }
        }
        return JudgeGrade(
            model: model,
            accuracy: answers.isEmpty ? 0 : points / Double(answers.count),
            yesRecall: yesTotal == 0 ? 0 : Double(yesHits) / Double(yesTotal),
            noRecall: noTotal == 0 ? 0 : Double(noHits) / Double(noTotal),
            answered: answered,
            total: answers.count,
            msPerAnswer: msPerAnswer,
            version: version,
            gradedAt: date
        )
    }

    public static let examples: [CalibrationExample] = [
        // Task stated first
        .init(.taskFirst, .yes, "Add a retry to the paste step. Right now if the target app is busy the paste just fails silently, so try again once after 200 milliseconds."),
        .init(.taskFirst, .yes, "Rename the settings tab from Audio to Microphone. It's the only thing on that page now."),
        .init(.taskFirst, .no, "So I was looking at the logs this morning and there's a lot going on with the paste timing, and I think it's related to the overlay, anyway can you make the paste retry once."),
        .init(.taskFirst, .no, "Okay, a bit of background first. We moved the models folder last week and some people still have the old path saved, which is why the download screen shows zero."),

        // Gives the context needed
        .init(.context, .yes, "Update the onboarding copy on the permissions step. It's in PermissionStepView, it should mention that Orttaai never sends audio off the Mac, and keep it under two sentences."),
        .init(.context, .yes, "Make the history list load faster. It reads every transcription at launch from the SQLite database; page it in batches of 200 and keep the search working across all of them."),
        .init(.context, .no, "Fix it."),
        .init(.context, .no, "Can you make that thing work better, the one we talked about."),

        // Names the file, screen, error or measurement
        .init(.filesAndErrors, .yes, "The crash is in AudioCaptureService.swift on line 212, it says index out of range when the microphone changes mid recording."),
        .init(.filesAndErrors, .yes, "On the Model settings screen the download progress sticks at 97 percent and the error says the checksum doesn't match."),
        .init(.filesAndErrors, .no, "Something's off with the app, it feels slow and sometimes things break."),
        .init(.filesAndErrors, .no, "Please make the experience nicer and more polished overall."),

        // Says what done looks like
        .init(.finishLine, .yes, "Speed up the paste after switching apps. Done when the paste lands in under 100 milliseconds and the existing paste tests still pass."),
        .init(.finishLine, .yes, "Clean up the export menu. It's finished when there are only three options and each one produces a file that opens in Numbers."),
        .init(.finishLine, .no, "Have a look at the export menu and tidy it up a bit."),
        .init(.finishLine, .no, "Start working on the paste speed, it's been bugging me."),

        // One request
        .init(.oneAsk, .yes, "Change the overlay's corner radius to 12 points to match the rest of the app."),
        .init(.oneAsk, .yes, "Write a test for the filler counter that covers um, uh and erm with stretched spellings."),
        .init(.oneAsk, .no, "Fix the login bug, also redesign the settings page, and while you're at it update the docs and bump the version."),
        .init(.oneAsk, .no, "Can you speed up the history page, add dark mode to the overlay, and look into why sync fails on the second Mac."),

        // A newcomer would follow it
        .init(.colleague, .yes, "In the Orttaai repo, open Settings, General. Add a toggle called Play a sound when dictation starts, off by default, saved in AppSettings, and play the Tink system sound when it's on."),
        .init(.colleague, .yes, "Go to the Releases folder, run release_dmg.sh with no options, and upload the DMG it prints to the GitHub release called v1.16.0."),
        .init(.colleague, .no, "Do the usual thing with the build and then the other step."),
        .init(.colleague, .no, "Same as last time but for the new one, you know."),

        // The ask comes first
        .init(.askFirst, .yes, "Could you review my pull request before 3? It's the paste fix, small, about 40 lines."),
        .init(.askFirst, .yes, "Can you send me the slides from Tuesday? I need them for the client call tomorrow."),
        .init(.askFirst, .no, "Hey, hope your week's going well. I've been heads down on the paste fix and it's finally working. When you get a chance could you review it?"),
        .init(.askFirst, .no, "So the client moved the meeting again and now it's Thursday and the deck isn't ready and I was wondering if you could help with the slides."),

        // Says when and why
        .init(.whenWhy, .yes, "Could you review the paste fix by 3 today? It has to go into tonight's build for the client demo tomorrow."),
        .init(.whenWhy, .yes, "Please send the invoice by Friday, our books close on Monday and it needs to be in this month."),
        .init(.whenWhy, .no, "Could you review the paste fix?"),
        .init(.whenWhy, .no, "Send me the invoice when you can."),

        // Friendly and direct
        .init(.tone, .yes, "Thanks for jumping on this. Could you send the updated numbers by noon? That gives me time to check them before the call."),
        .init(.tone, .yes, "Hi Sam, quick one: can you add me to the design review? Thanks."),
        .init(.tone, .no, "Send the numbers. Now. I've asked twice already."),
        .init(.tone, .no, "I'm so sorry to bother you, I really hate to ask, and please ignore this if you're busy, but I was maybe wondering if possibly you might have a moment at some point."),

        // Main point first
        .init(.pointFirst, .yes, "We should ship the paste fix on its own this week. It's ready, it's small, and waiting for the redesign would hold it back a month."),
        .init(.pointFirst, .yes, "The new model is twice as fast with the same accuracy. On our test set it takes 80 milliseconds instead of 160."),
        .init(.pointFirst, .no, "So there are a few things to think about, and the timing is tricky, and people have different views, but in the end I think we should ship the paste fix on its own."),
        .init(.pointFirst, .no, "Let me start with some history about how the old model was trained and the data it used back in the spring."),

        // One idea per sentence
        .init(.oneIdea, .yes, "The paste fix is ready. It cuts the delay to 80 milliseconds. I'd like to ship it on Thursday."),
        .init(.oneIdea, .yes, "Coach counts your fillers. It compares this month with last. It shows the change on your voice shape."),
        .init(.oneIdea, .no, "The paste fix is ready and it cuts the delay to 80 milliseconds which matters because people noticed the lag, and I'd like to ship it Thursday unless the redesign is ready, in which case we could bundle them, although that adds risk."),
        .init(.oneIdea, .no, "We moved the models folder, which broke downloads for some people because their saved path pointed at the old place, and also the progress bar was wrong, so I fixed both and added a migration and some tests."),

        // Ends with a summary or next step
        .init(.summary, .yes, "The new model is faster and just as accurate. Downloads are smaller too. Next step: I'll switch the default on Monday."),
        .init(.summary, .yes, "We looked at three ways to store the habits and picked the simplest. So, to sum up: one table, one row per habit."),
        .init(.summary, .no, "The new model is faster. It also uses less memory on older Macs. The download is 300 megabytes."),
        .init(.summary, .no, "There were three options for storing habits. The first used a table per habit. The second used a single JSON blob."),

        // Plain words
        .init(.plainWords, .yes, "Coach listens to how you talk when you dictate and shows you one thing to get better at each week."),
        .init(.plainWords, .yes, "The app keeps everything on your Mac. Nothing you say is sent anywhere."),
        .init(.plainWords, .no, "We leverage a bootstrapped CI over the delta of hit-rate distributions against a control drift baseline to adjudicate habit efficacy."),
        .init(.plainWords, .no, "The ANE-backed CoreML pipeline does int8 PTQ on the LSTM decoder with a stateful KV cache for low TTFT."),
    ]
}
