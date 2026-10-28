// CoachPersona.swift
// CoachCore
//
// The coaches. Each changes how feedback is worded, never the score: the
// checks and numbers are the same whoever coaches you.

import Foundation

public enum CoachPersona: String, CaseIterable, Codable, Sendable, Identifiable {
    case mentor
    case editor
    case socratic
    case sergeant
    case peer

    public var id: String { rawValue }

    public var name: String {
        switch self {
        case .mentor: return "Mentor"
        case .editor: return "Editor"
        case .socratic: return "Socratic"
        case .sergeant: return "Drill sergeant"
        case .peer: return "Peer"
        }
    }

    public var trait: String {
        switch self {
        case .mentor: return "Warm, encouraging"
        case .editor: return "Direct, short"
        case .socratic: return "Asks, never tells"
        case .sergeant: return "Strict, holds the line"
        case .peer: return "Casual, a friend"
        }
    }

    /// How the coach model should write.
    public var style: String {
        switch self {
        case .mentor: return "warm and encouraging: name one real strength first, then one specific next step"
        case .editor: return "direct and brief, like a good editor: what worked in a few words, then the one fix"
        case .socratic: return "Socratic: ask one question that leads the speaker to the fix, without stating it"
        case .sergeant: return "strict and brisk, like a drill sergeant who respects effort: no praise unless earned, one firm order"
        case .peer: return "casual and friendly, like a colleague who's on your side"
        }
    }

    /// What the coach says to a rep, used when there's no coach model or its
    /// note didn't pass the guard.
    public func line(skill: String, met: Bool?, missing: String?) -> String {
        let fix = missing.map { $0.prefix(1).lowercased() + $0.dropFirst() }
        switch (self, met) {
        case (.mentor, true?):
            return fix.map { "That's the one for \(skill.lowercased()). Next time, add this too: \($0)." } ?? "That's the one. \(skill) was clear all the way through."
        case (.mentor, _):
            return "Good start. Keep at \(skill.lowercased()); it's the one thing to bring in next time."
        case (.editor, true?):
            return fix.map { "\(skill): done. Still missing: \($0)." } ?? "\(skill): done. Nothing to cut."
        case (.editor, _):
            return "\(skill) didn't land. Fix that first."
        case (.socratic, true?):
            return fix.map { "You nailed \(skill.lowercased()). What would it take to also say \($0)?" } ?? "You nailed it. What made this one different from your usual?"
        case (.socratic, _):
            return "If someone heard only your first sentence, would they know what you need?"
        case (.sergeant, true?):
            return fix.map { "\(skill): acceptable. Now add: \($0). Again." } ?? "\(skill): done. Do it again, the same way."
        case (.sergeant, _):
            return "\(skill) missing. Again, and lead with it."
        case (.peer, true?):
            return fix.map { "Nice, \(skill.lowercased()) landed. I'd just add \($0)." } ?? "Nice one. That's exactly it."
        case (.peer, _):
            return "Close! Just work \(skill.lowercased()) in and you're there."
        }
    }

    /// How the coach reacts to the same rep, for choosing one.
    public var sample: String {
        line(skill: "Say what done looks like", met: true, missing: "Task stated first")
    }

    /// The prompt for a coach model's note on a rep.
    public func notePrompt(skill: CoachSkill, results: [CheckResult], facts: [String], score: Double?) -> String {
        let checks = results.map { result -> String in
            let answer = result.answer?.rawValue ?? "not known"
            return "- \(result.check.label): \(answer)" + (result.check == skill.check ? " (this skill)" : "")
        }
        var lines = [
            "You are a speaking coach. Your style is \(style).",
            "Write one or two short sentences of feedback on a practice attempt, speaking to the person as \"you\".",
            "The skill they practised: \(skill.title).",
            "How the attempt did on each check:",
        ]
        lines += checks
        if let score { lines.append("Score: \(String(format: "%.1f", score)) out of 5.") }
        if !facts.isEmpty {
            lines.append("Counted facts you may use:")
            lines += facts.map { "- \($0)" }
        }
        lines += [
            "Only use numbers listed above. Never quote the attempt. No emoji. At most 240 characters.",
            "Reply with the feedback only.",
        ]
        return lines.joined(separator: "\n")
    }
}
