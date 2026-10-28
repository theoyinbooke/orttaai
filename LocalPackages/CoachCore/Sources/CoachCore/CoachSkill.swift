// CoachSkill.swift
// CoachCore
//
// What there is to practise: four tracks, each a path of skills. A skill is
// checked by counting (Delivery) or by a judge answering one yes/no
// question; every rep in a track is scored on the track's checks, with the
// skill's own check marked as the one that matters.

import Foundation

public enum CoachTrack: String, CaseIterable, Codable, Sendable, Identifiable {
    case prompting
    case messages
    case delivery
    case explaining

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .prompting: return "Prompting AI"
        case .messages: return "Messages to people"
        case .delivery: return "Delivery"
        case .explaining: return "Explaining"
        }
    }

    /// The way of talking whose dictations it draws on, nil for any.
    public var mode: CoachMode? {
        switch self {
        case .prompting: return .ai
        case .messages: return .people
        case .delivery: return nil
        case .explaining: return .writing
        }
    }

    /// The track for a way of talking.
    public static func track(for mode: CoachMode) -> CoachTrack {
        switch mode {
        case .ai: return .prompting
        case .people: return .messages
        case .writing: return .explaining
        case .elsewhere: return .delivery
        }
    }

    public var skills: [CoachSkill] { CoachSkill.all.filter { $0.track == self } }

    /// The checks every rep in the track is scored on.
    public var checks: [CoachCheck] {
        switch self {
        case .prompting:
            return [.judged(.taskFirst), .judged(.context), .judged(.finishLine), .judged(.oneAsk)]
        case .messages:
            return [.judged(.askFirst), .judged(.whenWhy), .judged(.tone), .counted(.briefWords)]
        case .delivery:
            return [.counted(.measure(.fillers)), .counted(.measure(.phrases)), .counted(.measure(.sentences)), .counted(.measure(.repeats))]
        case .explaining:
            return [.judged(.pointFirst), .judged(.oneIdea), .judged(.summary), .judged(.plainWords)]
        }
    }

    /// A brief to speak or type when there's nothing of your own to redo.
    public var openBrief: String {
        switch self {
        case .prompting: return "Brief an agent on something you're working on today."
        case .messages: return "Ask a teammate for something you need from them this week."
        case .delivery: return "Explain what you're working on and why it matters."
        case .explaining: return "Explain one idea from your work to someone new to it."
        }
    }
}

/// A question a judge model answers yes, partly or no.
public enum CoachQuestion: String, CaseIterable, Codable, Sendable {
    case taskFirst
    case context
    case filesAndErrors
    case finishLine
    case oneAsk
    case colleague
    case askFirst
    case whenWhy
    case tone
    case pointFirst
    case oneIdea
    case summary
    case plainWords

    public var label: String {
        switch self {
        case .taskFirst: return "Task stated first"
        case .context: return "Gives the context needed"
        case .filesAndErrors: return "Names the file, screen or error"
        case .finishLine: return "Says what done looks like"
        case .oneAsk: return "One request, not several"
        case .colleague: return "A newcomer would follow it"
        case .askFirst: return "The ask comes first"
        case .whenWhy: return "Says when, and why it matters"
        case .tone: return "Friendly and direct"
        case .pointFirst: return "Main point first"
        case .oneIdea: return "One idea at a time"
        case .summary: return "Ends with a summary or next step"
        case .plainWords: return "Plain words"
        }
    }

    /// What the judge is asked, about the text it is shown.
    public var question: String {
        switch self {
        case .taskFirst: return "Is the task the speaker wants done stated in the first sentence?"
        case .context: return "Does it give the context needed to do the task, such as what, where and any constraints?"
        case .filesAndErrors: return "Does it name a specific file, screen, error message or measurement involved?"
        case .finishLine: return "Does it say how anyone will know the task is finished, such as a test that passes or a result to check?"
        case .oneAsk: return "Does it ask for one thing, rather than several unrelated things?"
        case .colleague: return "Would a new colleague with no background know exactly what to do from it?"
        case .askFirst: return "Is the request or question in the first sentence?"
        case .whenWhy: return "Does it say when the thing is needed and why it matters?"
        case .tone: return "Is the tone friendly and direct, neither curt nor over-apologetic?"
        case .pointFirst: return "Does the first sentence state the main point?"
        case .oneIdea: return "Does each sentence carry a single idea?"
        case .summary: return "Does it end with a short summary or a next step?"
        case .plainWords: return "Is it in plain words a newcomer would follow, without unexplained jargon?"
        }
    }
}

/// A check that's counted, not judged.
public enum CoachCount: Codable, Sendable, Equatable, Hashable {
    case measure(CoachMeasure)
    /// 60 words or fewer.
    case briefWords

    public var label: String {
        switch self {
        case .measure(let m): return m.hitTitle
        case .briefWords: return "60 words or fewer"
        }
    }

    /// Whether the attempt meets it; nil when it can't be told (typed pace).
    public func isMet(_ m: DictationMeasures) -> Bool? {
        switch self {
        case .measure(let measure): return measure.isHit(m)
        case .briefWords: return m.words <= 60
        }
    }
}

public enum CoachCheck: Codable, Sendable, Equatable, Hashable, Identifiable {
    case judged(CoachQuestion)
    case counted(CoachCount)
    /// Whether a scene's goal was reached, by the scene's id.
    case goal(String)

    public var id: String {
        switch self {
        case .judged(let q): return "q-" + q.rawValue
        case .counted(.measure(let m)): return "m-" + m.rawValue
        case .counted(.briefWords): return "m-brief"
        case .goal(let scene): return "g-" + scene
        }
    }

    public var label: String {
        switch self {
        case .judged(let q): return q.label
        case .counted(let c): return c.label
        case .goal: return "Reached the goal"
        }
    }
}

/// How a rep is set up.
public enum CoachRepKind: String, CaseIterable, Codable, Sendable {
    /// Say one of your own dictations again, better.
    case redo
    /// Meet one constraint.
    case drill
    /// A minute to brief or explain.
    case timed
    /// A roleplay scene.
    case scene

    /// The kinds a skill offers on its own; scenes start from Studio.
    public static let practice: [CoachRepKind] = [.redo, .drill, .timed]

    public var title: String {
        switch self {
        case .redo: return "Redo one of yours"
        case .drill: return "Drill"
        case .timed: return "60-second brief"
        case .scene: return "Scene"
        }
    }

    public var timeLimitSeconds: Int {
        switch self {
        case .redo: return 90
        case .drill: return 60
        case .timed: return 60
        case .scene: return 90
        }
    }
}

public struct CoachSkill: Sendable, Identifiable, Hashable {
    public let id: String
    public let track: CoachTrack
    public let title: String
    /// The check that matters most for this skill.
    public let check: CoachCheck
    /// One line on why, shown on the path.
    public let why: String
    /// The constraint a drill sets.
    public let drill: String
    /// Delivery skills map to a counted measure, so they can become habits.
    public var measure: CoachMeasure? {
        if case .counted(.measure(let m)) = check { return m }
        return nil
    }

    /// Pace needs a voice.
    public var speakOnly: Bool { measure == .pace }

    public var checks: [CoachCheck] {
        var all = track.checks
        if !all.contains(check) { all.insert(check, at: 0) }
        return all
    }

    public static func skill(id: String) -> CoachSkill? { all.first { $0.id == id } }

    public static let all: [CoachSkill] = [
        // Prompting AI.
        CoachSkill(id: "task-first", track: .prompting, title: "Task first", check: .judged(.taskFirst),
                   why: "Agents act on the first thing you say.", drill: "Say the task in your first sentence, then everything else."),
        CoachSkill(id: "context", track: .prompting, title: "Give the context it needs", check: .judged(.context),
                   why: "What, where and any limits save a round of questions.", drill: "Give the task, then where it lives and one constraint."),
        CoachSkill(id: "files-errors", track: .prompting, title: "Name the files and errors", check: .judged(.filesAndErrors),
                   why: "A file name or the exact error beats a description.", drill: "Name one file and one error or measurement."),
        CoachSkill(id: "finish-line", track: .prompting, title: "Say what done looks like", check: .judged(.finishLine),
                   why: "Agents stop sooner and ask less when they know the finish line.", drill: "End with how you'll know it's finished."),
        CoachSkill(id: "one-ask", track: .prompting, title: "One request per prompt", check: .judged(.oneAsk),
                   why: "One clear ask gets one clear result.", drill: "Ask for one thing only."),
        CoachSkill(id: "colleague", track: .prompting, title: "Pass the colleague test", check: .judged(.colleague),
                   why: "If someone new could follow it, an agent can.", drill: "Brief it as if to someone who joined today."),
        // Messages to people.
        CoachSkill(id: "ask-first", track: .messages, title: "Ask first", check: .judged(.askFirst),
                   why: "People read the first line, then decide.", drill: "Put the ask in your first sentence."),
        CoachSkill(id: "keep-short", track: .messages, title: "Keep it short", check: .counted(.briefWords),
                   why: "Short messages get answered sooner.", drill: "Three sentences, 60 words at most."),
        CoachSkill(id: "when-why", track: .messages, title: "Say when and why", check: .judged(.whenWhy),
                   why: "A deadline and a reason make it easy to say yes.", drill: "Say when you need it and why it matters."),
        CoachSkill(id: "tone", track: .messages, title: "A tone that fits", check: .judged(.tone),
                   why: "Friendly and direct beats curt or over-apologetic.", drill: "Ask warmly, without apologising."),
        // Delivery.
        CoachSkill(id: "fewer-umuh", track: .delivery, title: "Fewer ums and uhs", check: .counted(.measure(.fillers)),
                   why: "A silent pause reads better, and writes nothing.", drill: "Say it with no um or uh. Pause instead."),
        CoachSkill(id: "fewer-phrases", track: .delivery, title: "Fewer filler phrases", check: .counted(.measure(.phrases)),
                   why: "\"Basically\" and \"you know\" fill time, not meaning.", drill: "No \"basically\", \"actually\" or \"you know\"."),
        CoachSkill(id: "short-sentences", track: .delivery, title: "Shorter sentences", check: .counted(.measure(.sentences)),
                   why: "Short sentences give Polish clear places to stop.", drill: "Sentences of 14 words or fewer."),
        CoachSkill(id: "steady-pace", track: .delivery, title: "A steadier pace", check: .counted(.measure(.pace)),
                   why: "Names and numbers come out cleaner nearer 140 words a minute.", drill: "Stay at 160 words a minute or slower."),
        CoachSkill(id: "no-repeats", track: .delivery, title: "No words said twice", check: .counted(.measure(.repeats)),
                   why: "Starting a sentence a beat slower stops the stutter.", drill: "Say each word once."),
        // Explaining.
        CoachSkill(id: "point-first", track: .explaining, title: "Point first", check: .judged(.pointFirst),
                   why: "Lead with the point; the detail follows it.", drill: "Open with the main point."),
        CoachSkill(id: "one-idea", track: .explaining, title: "One idea at a time", check: .judged(.oneIdea),
                   why: "One idea per sentence is easy to follow.", drill: "One idea per sentence."),
        CoachSkill(id: "sum-up", track: .explaining, title: "Sum it up", check: .judged(.summary),
                   why: "A last line that sums up is what people remember.", drill: "End with a one-line summary or next step."),
        CoachSkill(id: "plain-words", track: .explaining, title: "Plain words", check: .judged(.plainWords),
                   why: "Plain words travel further than jargon.", drill: "Explain it without jargon."),
    ]
}
