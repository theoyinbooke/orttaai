// CoachScene.swift
// CoachCore
//
// Roleplay scenes: a partner played by the coach model, a goal to reach,
// and the reply format that carries the partner's mood.

import Foundation

public enum PartnerMood: String, Codable, Sendable, CaseIterable {
    case pushing
    case weighing
    case agreed

    public var title: String {
        switch self {
        case .pushing: return "Pushing"
        case .weighing: return "Weighing it"
        case .agreed: return "Agreed"
        }
    }

    public var step: Int {
        switch self {
        case .pushing: return 0
        case .weighing: return 1
        case .agreed: return 2
        }
    }
}

public struct CoachScene: Sendable, Identifiable, Hashable {
    public let id: String
    public let track: CoachTrack
    public let title: String
    public let partnerName: String
    public let partnerRole: String
    /// How the partner behaves, for the model.
    public let partnerBrief: String
    /// What the partner says first.
    public let opening: String
    /// The goal, as shown.
    public let goal: String
    /// The goal, as the judge is asked about it at the end.
    public let goalQuestion: String

    public static let maxTurns = 8

    public static func scene(id: String) -> CoachScene? { all.first { $0.id == id } }

    public static func scenes(for track: CoachTrack) -> [CoachScene] { all.filter { $0.track == track } }

    public static let all: [CoachScene] = [
        CoachScene(
            id: "brief-agent", track: .prompting, title: "Brief an agent",
            partnerName: "Atlas", partnerRole: "An AI coding agent",
            partnerBrief: "You are Atlas, an AI coding agent about to start work. Ask one short question about whatever the speaker left out: the task, where it lives, a constraint, or how you'll know it's done. Once nothing important is missing, say you'll start, briefly.",
            opening: "Ready when you are. What should I work on?",
            goal: "Give it the task, the context and the finish line",
            goalQuestion: "Did the speaker give the agent a clear task, the context it needs, and how to know it's done?"
        ),
        CoachScene(
            id: "scope-push", track: .messages, title: "Push back on scope, kindly",
            partnerName: "Tolu", partnerRole: "A client, friendly and in a hurry",
            partnerBrief: "You are Tolu, a friendly client in a hurry who wants two extra features, a team calendar and a PDF export, by Friday. Push back once or twice. Agree only when you're offered a realistic choice warmly.",
            opening: "Can we also get the team calendar and the PDF export in by Friday? The board wants both.",
            goal: "Keep Friday realistic, offer a choice, stay warm",
            goalQuestion: "Did the speaker keep the deadline realistic while offering the client a real choice, kindly?"
        ),
        CoachScene(
            id: "review-ask", track: .messages, title: "Get a review today",
            partnerName: "Dami", partnerRole: "A teammate with a full day",
            partnerBrief: "You are Dami, a helpful teammate with a packed day. You'll help if the ask is clear, you know when it's needed and why. If it's vague, say you're slammed and ask what exactly is needed.",
            opening: "Hey, what's up? I'm slammed today.",
            goal: "Get a review by 3 pm",
            goalQuestion: "Did the speaker clearly ask for the review, say by when, and say why it matters?"
        ),
        CoachScene(
            id: "status-update", track: .delivery, title: "A quick status update",
            partnerName: "Priya", partnerRole: "Your manager, between meetings",
            partnerBrief: "You are Priya, a manager with two minutes between meetings. Ask for the one thing you most need to know next, briefly. Agree once you have a clear picture.",
            opening: "Give me a quick update on where things are.",
            goal: "A clear update without fillers",
            goalQuestion: "Did the speaker give a clear, concise status update?"
        ),
        CoachScene(
            id: "newcomer", track: .explaining, title: "Explain it to a newcomer",
            partnerName: "Sam", partnerRole: "Joined the team today",
            partnerBrief: "You are Sam, who joined the team today and is curious. Ask about whatever you didn't follow, one question at a time. Agree once you could explain it to someone else.",
            opening: "I just joined. What does your team actually do?",
            goal: "Explain it so Sam could tell someone else",
            goalQuestion: "Would a newcomer understand the main point from what the speaker said?"
        ),
    ]
}

/// One line of a scene.
public struct SceneTurn: Sendable, Equatable, Identifiable {
    public enum Speaker: String, Sendable { case you, partner }

    public let id = UUID()
    public var speaker: Speaker
    public var text: String
    /// Only on spoken turns: how long it took to say.
    public var durationMs: Int?

    public init(speaker: Speaker, text: String, durationMs: Int? = nil) {
        self.speaker = speaker
        self.text = text
        self.durationMs = durationMs
    }

    public static func == (a: SceneTurn, b: SceneTurn) -> Bool {
        a.id == b.id && a.speaker == b.speaker && a.text == b.text && a.durationMs == b.durationMs
    }
}

public enum CoachPartnerPrompt {
    public static let jsonSchema = """
    {"type":"object","properties":{"reply":{"type":"string"},"mood":{"type":"string","enum":["pushing","weighing","agreed"]}},"required":["reply","mood"]}
    """

    public static func prompt(scene: CoachScene, turns: [SceneTurn]) -> String {
        var lines = [
            scene.partnerBrief,
            "Stay in character. Speak in one to three short sentences, as in conversation. Never mention being an AI model or a roleplay.",
            "",
            "The conversation so far:",
        ]
        for turn in turns {
            lines.append("\(turn.speaker == .you ? "Them" : scene.partnerName): \(turn.text)")
        }
        lines += [
            "",
            "How you feel now: pushing (not convinced), weighing (coming round) or agreed.",
            #"Reply with JSON only: {"reply": "what \#(scene.partnerName) says next", "mood": "pushing" | "weighing" | "agreed"}"#,
        ]
        return lines.joined(separator: "\n")
    }

    /// The partner's line and mood, or nil when the reply can't be read.
    public static func parse(_ reply: String) -> (reply: String, mood: PartnerMood)? {
        guard let start = reply.firstIndex(of: "{"), let end = reply.lastIndex(of: "}"), start < end,
              let data = String(reply[start...end]).data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = (object["reply"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty,
              let raw = (object["mood"] as? String)?.lowercased(),
              let mood = PartnerMood(rawValue: raw) else { return nil }
        return (text, mood)
    }
}
