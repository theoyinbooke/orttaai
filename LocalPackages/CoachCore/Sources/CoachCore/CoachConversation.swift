// CoachConversation.swift
// CoachCore
//
// What a scene needs to feel like talking, not taking turns at a form: the
// partner's reply as a chat it can stream, its mood as a separate quick
// question, sentences handed on as soon as each is complete, and a turn that
// ends when you pause.

import Foundation

public enum ChatRole: String, Sendable {
    case system
    case user
    case assistant
}

public struct ChatLine: Sendable, Equatable {
    public var role: ChatRole
    public var content: String

    public init(_ role: ChatRole, _ content: String) {
        self.role = role
        self.content = content
    }
}

extension CoachPartnerPrompt {
    /// The scene as a chat: the partner's brief, then its lines as the
    /// assistant's and yours as the user's. The reply is plain speech, so it
    /// can be spoken while it's still being written.
    public static func chat(scene: CoachScene, turns: [SceneTurn]) -> [ChatLine] {
        var lines = [
            ChatLine(.system, [
                scene.partnerBrief,
                "Stay in character as \(scene.partnerName). Speak in one to three short sentences, as in conversation. Never mention being an AI model or a roleplay.",
                "Reply with only what \(scene.partnerName) says: no name, no quotation marks, no stage directions.",
            ].joined(separator: "\n")),
            // Chat templates expect the person to speak first.
            ChatLine(.user, "(The conversation starts.)"),
        ]
        for turn in turns {
            lines.append(ChatLine(turn.speaker == .partner ? .assistant : .user, turn.text))
        }
        return lines
    }

    public static let moodSchema = """
    {"type":"object","properties":{"mood":{"type":"string","enum":["pushing","weighing","agreed"]}},"required":["mood"]}
    """

    /// How the partner feels after its last line, asked separately so it
    /// never holds up the reply.
    public static func moodPrompt(scene: CoachScene, turns: [SceneTurn]) -> String {
        var lines = [
            "\(scene.partnerName) is \(scene.partnerRole.prefix(1).lowercased() + scene.partnerRole.dropFirst()) in this conversation:",
            "",
        ]
        for turn in turns {
            lines.append("\(turn.speaker == .you ? "Them" : scene.partnerName): \(turn.text)")
        }
        lines += [
            "",
            "After \(scene.partnerName)'s last line, how does \(scene.partnerName) feel: pushing (not convinced), weighing (coming round) or agreed?",
            #"Reply with JSON only: {"mood": "pushing" | "weighing" | "agreed"}"#,
        ]
        return lines.joined(separator: "\n")
    }

    public static func parseMood(_ reply: String) -> PartnerMood? {
        guard let start = reply.firstIndex(of: "{"), let end = reply.lastIndex(of: "}"), start < end,
              let data = String(reply[start...end]).data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = (object["mood"] as? String)?.lowercased() else { return nil }
        return PartnerMood(rawValue: raw)
    }

    static let quotes = CharacterSet(charactersIn: "\"“”")

    /// A reply as it streams in, without a speaker name the model added
    /// anyway. Only ever removes from the start, so text that grows stays
    /// in step with what has already been handed on.
    public static func withoutName(_ reply: String, partnerName: String) -> String {
        let text = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.lowercased().hasPrefix(partnerName.lowercased() + ":") else { return text }
        return String(text.dropFirst(partnerName.count + 1)).trimmingCharacters(in: .whitespaces)
    }

    /// The finished reply: no speaker name, and no quotation marks wrapping
    /// the whole of it. Quotes around a phrase inside it stay.
    public static func cleaned(_ reply: String, partnerName: String) -> String {
        let text = withoutName(reply, partnerName: partnerName)
        guard let first = text.unicodeScalars.first, quotes.contains(first) else { return text }
        let inner = text.unicodeScalars.dropFirst()
        // Wrapped only when the first closing quote is the last character.
        guard let close = inner.firstIndex(where: { quotes.contains($0) }), inner.index(after: close) == inner.endIndex else {
            return text
        }
        return String(String.UnicodeScalarView(inner.dropLast())).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A sentence ready to be spoken: stray quotation marks at its ends add nothing.
    public static func spoken(_ sentence: String) -> String {
        sentence.trimmingCharacters(in: quotes).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Hands on each sentence of a reply as soon as it's complete, from text that
/// grows as it streams in.
public struct SentenceStream: Sendable {
    private var handedOn = 0

    public init() {}

    /// New complete sentences in `text`, the whole reply so far.
    public mutating func feed(_ text: String) -> [String] {
        let characters = Array(text)
        var sentences: [String] = []
        var start = handedOn
        var index = handedOn
        while index < characters.count {
            let character = characters[index]
            let next = index + 1 < characters.count ? characters[index + 1] : nil
            // A sentence ends at . ? ! once a space follows, so "3.5" and "e.g." mid-word wait.
            if ".?!".contains(character), let next, next == " " || next == "\n" {
                let sentence = String(characters[start...index]).trimmingCharacters(in: .whitespacesAndNewlines)
                if sentence.count > 1 { sentences.append(sentence) }
                start = index + 1
            }
            index += 1
        }
        handedOn = start
        return sentences
    }

    /// Whatever is left once the reply is complete.
    public mutating func finish(_ text: String) -> String? {
        let characters = Array(text)
        guard handedOn < characters.count else { return nil }
        let rest = String(characters[handedOn...]).trimmingCharacters(in: .whitespacesAndNewlines)
        handedOn = characters.count
        return rest.isEmpty ? nil : rest
    }
}

/// Decides when you've finished speaking, from the microphone's level: it
/// learns the room's quiet first, waits for you to start, and ends the turn
/// after a pause.
public struct TurnDetector: Sendable {
    public enum Event: Equatable, Sendable {
        case none
        case started
        case ended
        case gaveUp
    }

    public var pause: TimeInterval
    public var patience: TimeInterval
    private let calibration: TimeInterval = 0.3
    private var startedAt: TimeInterval?
    private var floorSamples: [Float] = []
    private var threshold: Float = 0.08
    private var lastLoud: TimeInterval?
    private var loudSince: TimeInterval?
    private var done = false
    public private(set) var heardSpeech = false

    /// - Parameters:
    ///   - pause: Quiet that ends a turn once you've spoken.
    ///   - patience: How long to wait for you to start before giving up.
    public init(pause: TimeInterval = 0.8, patience: TimeInterval = 12) {
        self.pause = pause
        self.patience = patience
    }

    /// One level reading, 0 to 1, at `time` seconds.
    /// Reports `.ended` or `.gaveUp` once, then nothing more.
    public mutating func feed(level: Float, at time: TimeInterval) -> Event {
        guard !done else { return .none }
        if startedAt == nil { startedAt = time }
        let elapsed = time - (startedAt ?? time)
        if elapsed < calibration {
            floorSamples.append(level)
            let floor = floorSamples.sorted()[floorSamples.count / 2]
            threshold = max(0.08, floor * 3 + 0.03)
            return .none
        }
        if level >= threshold {
            loudSince = loudSince ?? time
            lastLoud = time
            // A short click isn't speech; a fifth of a second of sound is.
            if !heardSpeech, let since = loudSince, time - since >= 0.2 {
                heardSpeech = true
                return .started
            }
        } else {
            loudSince = nil
        }
        if heardSpeech, let lastLoud, time - lastLoud >= pause {
            done = true
            return .ended
        }
        if !heardSpeech, elapsed >= patience {
            done = true
            return .gaveUp
        }
        return .none
    }
}
