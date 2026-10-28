// CoachScoring.swift
// CoachCore
//
// A rep's score from its checks, the judge's one-question prompt and how its
// reply is read, and the guard that keeps a coach's note to the facts.

import Foundation

public enum JudgeAnswer: String, Codable, Sendable, CaseIterable {
    case yes
    case partly
    case no

    public var points: Double {
        switch self {
        case .yes: return 1
        case .partly: return 0.5
        case .no: return 0
        }
    }
}

/// How one check went. A nil answer couldn't be told and isn't scored.
public struct CheckResult: Codable, Sendable, Equatable, Identifiable {
    public var check: CoachCheck
    public var answer: JudgeAnswer?
    /// The judge's confidence, 0 to 1; nil for counted checks.
    public var confidence: Double?

    public var id: String { check.id }

    public init(check: CoachCheck, answer: JudgeAnswer?, confidence: Double? = nil) {
        self.check = check
        self.answer = answer
        self.confidence = confidence
    }

    /// A counted check, from the attempt's counts.
    public static func counted(_ count: CoachCount, _ m: DictationMeasures) -> CheckResult {
        CheckResult(check: .counted(count), answer: count.isMet(m).map { $0 ? .yes : .no })
    }
}

public enum CoachScore {
    /// 1 + 4 × points ÷ answered checks, to one decimal; nil when nothing
    /// could be answered.
    public static func score(_ results: [CheckResult]) -> Double? {
        let answered = results.compactMap(\.answer)
        guard !answered.isEmpty else { return nil }
        let points = answered.reduce(0) { $0 + $1.points }
        return ((1 + 4 * points / Double(answered.count)) * 10).rounded() / 10
    }

    /// A skill counts a rep towards mastery at 4 or more with its own check met.
    public static let masteryScore = 4.0
    public static let repsToMaster = 3
}

/// The judge gets one question per call and must answer in JSON.
public enum CoachJudgePrompt {
    public static let jsonSchema = """
    {"type":"object","properties":{"answer":{"type":"string","enum":["yes","partly","no"]},"confidence":{"type":"number","minimum":0,"maximum":1}},"required":["answer","confidence"]}
    """

    public static func prompt(question: CoachQuestion, text: String, context: String?) -> String {
        prompt(questionText: question.question, text: text, context: context)
    }

    public static func prompt(questionText: String, text: String, context: String?) -> String {
        var lines = [
            "You judge one thing about a short piece of speech that was dictated.",
            "Answer only the question, strictly. Partly means it does some of it.",
            "",
        ]
        if let context, !context.isEmpty {
            lines.append("What the speaker was asked to do: \(context)")
            lines.append("")
        }
        lines.append("The speech, between the markers:")
        lines.append("<<<")
        lines.append(text)
        lines.append(">>>")
        lines.append("")
        lines.append("Question: \(questionText)")
        lines.append(#"Reply with JSON only: {"answer": "yes" | "partly" | "no", "confidence": a number from 0 to 1}"#)
        return lines.joined(separator: "\n")
    }

    /// The answer and confidence, or nil when the reply can't be read.
    public static func parse(_ reply: String) -> (answer: JudgeAnswer, confidence: Double)? {
        guard let start = reply.firstIndex(of: "{"), let end = reply.lastIndex(of: "}"), start < end,
              let data = String(reply[start...end]).data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = (object["answer"] as? String)?.lowercased().trimmingCharacters(in: .whitespaces),
              let answer = JudgeAnswer(rawValue: raw) else { return nil }
        let confidence: Double
        if let number = object["confidence"] as? NSNumber {
            confidence = min(1, max(0, number.doubleValue))
        } else if let text = object["confidence"] as? String, let value = Double(text) {
            confidence = min(1, max(0, value))
        } else {
            confidence = 0.5
        }
        return (answer, confidence)
    }
}

/// Keeps a model's note to what Coach told it, as Orttakey's CoachWriter does.
public enum CoachNoteGuard {
    public static let maxCharacters = 280

    /// Numbers a note may use: each figure whole and to one decimal, plus a
    /// few small counting words' digits.
    public static func allowedNumbers(from figures: [Double]) -> Set<String> {
        var allowed: Set<String> = ["1", "2", "3"]
        for figure in figures {
            allowed.insert(String(Int(figure.rounded())))
            allowed.insert(String(format: "%.1f", figure))
        }
        return allowed
    }

    public static func cleaned(_ note: String) -> String {
        note.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"“”"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func accepts(_ note: String, allowed: Set<String>) -> Bool {
        let note = cleaned(note)
        guard !note.isEmpty, note.count <= maxCharacters else { return false }
        let numbers = note.matches(of: /\d+(?:\.\d+)?/).map { String($0.output) }
        return numbers.allSatisfy { allowed.contains($0) }
    }
}
