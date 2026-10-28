// CoachAxis.swift
// CoachCore
//
// An axis of the voice shape: a counted measure, or a question the judge
// answers about each dictation. Each way of talking has its own six; the
// all-modes shape keeps the six counted ones so it compares across them.

import Foundation

public enum CoachAxis: Hashable, Sendable, Identifiable {
    case measure(CoachMeasure)
    case question(CoachQuestion)

    public var id: String {
        switch self {
        case .measure(let m): return m.rawValue
        case .question(let q): return "q:" + q.rawValue
        }
    }

    public var title: String {
        switch self {
        case .measure(let m): return m.axisTitle
        case .question(let q): return q.axisTitle
        }
    }

    public var isJudged: Bool {
        if case .question = self { return true }
        return false
    }

    public var question: CoachQuestion? {
        if case .question(let q) = self { return q }
        return nil
    }

    /// The six axes for a way of talking, judged first. nil, and
    /// "elsewhere", get the six counted measures.
    public static func axes(for mode: CoachMode?) -> [CoachAxis] {
        switch mode {
        case .ai?:
            return [.question(.taskFirst), .question(.context), .question(.finishLine), .question(.oneAsk), .measure(.clarity), .measure(.pace)]
        case .people?:
            return [.question(.askFirst), .question(.whenWhy), .question(.tone), .measure(.sentences), .measure(.clarity), .measure(.pace)]
        case .writing?:
            return [.question(.pointFirst), .question(.oneIdea), .question(.summary), .question(.plainWords), .measure(.fillers), .measure(.sentences)]
        case .elsewhere?, nil:
            return CoachMeasure.allCases.map(CoachAxis.measure)
        }
    }

    /// The judged questions on a way of talking's shape.
    public static func questions(for mode: CoachMode?) -> [CoachQuestion] {
        axes(for: mode).compactMap(\.question)
    }
}

extension CoachQuestion {
    /// The voice shape's axis label.
    public var axisTitle: String {
        switch self {
        case .taskFirst: return "Task first"
        case .context: return "Context"
        case .filesAndErrors: return "Specifics"
        case .finishLine: return "Finish line"
        case .oneAsk: return "One ask"
        case .colleague: return "Easy to follow"
        case .askFirst: return "Ask first"
        case .whenWhy: return "When and why"
        case .tone: return "Tone"
        case .pointFirst: return "Point first"
        case .oneIdea: return "One idea"
        case .summary: return "Summary"
        case .plainWords: return "Plain words"
        }
    }
}
