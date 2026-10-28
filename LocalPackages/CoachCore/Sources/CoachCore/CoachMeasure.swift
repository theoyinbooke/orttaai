// CoachMeasure.swift
// CoachCore
//
// The six things Coach watches, how each reads one dictation, what counts
// as meeting it, and how a group of dictations scores on the voice shape.

import Foundation

public enum CoachMeasure: String, CaseIterable, Codable, Sendable, Identifiable {
    case fillers
    case phrases
    case pace
    case sentences
    case repeats
    case clarity

    public var id: String { rawValue }

    /// The voice shape's axis label.
    public var axisTitle: String {
        switch self {
        case .fillers: return "Fewer fillers"
        case .phrases: return "Clean phrases"
        case .pace: return "Steady pace"
        case .sentences: return "Short sentences"
        case .repeats: return "No repeats"
        case .clarity: return "Said it clearly"
        }
    }

    /// The habit's name.
    public var habitTitle: String {
        switch self {
        case .fillers: return "Fewer ums and uhs"
        case .phrases: return "Fewer filler phrases"
        case .pace: return "A steadier pace"
        case .sentences: return "Shorter sentences"
        case .repeats: return "No words said twice"
        case .clarity: return "Say it right first time"
        }
    }

    /// What meeting it means, for a dictation.
    public var hitTitle: String {
        switch self {
        case .fillers: return "1 um or uh per 100 words or fewer"
        case .phrases: return "1 filler phrase per 100 words or fewer"
        case .pace: return "160 words a minute or slower"
        case .sentences: return "Sentences of 14 words or fewer"
        case .repeats: return "No word said twice"
        case .clarity: return "Polish changed 15% or less"
        }
    }

    public var unit: String {
        switch self {
        case .fillers, .phrases, .repeats: return "per 100 words"
        case .pace: return "words a minute"
        case .sentences: return "words a sentence"
        case .clarity: return "rewritten"
        }
    }

    /// Fewer is better for every measure; pace counts down from fast.
    public var lowerIsBetter: Bool { true }

    // MARK: One dictation

    /// The measure for one dictation, or nil when it can't be told.
    public func value(of m: DictationMeasures) -> Double? {
        switch self {
        case .fillers:
            guard m.rawKnown, m.words >= 5 else { return nil }
            return Double(m.umUh) / Double(m.words) * 100
        case .phrases:
            guard m.rawKnown, m.words >= 5 else { return nil }
            return Double(m.phraseFillers) / Double(m.words) * 100
        case .pace:
            return m.wpm.map(Double.init)
        case .sentences:
            guard m.rawKnown else { return nil }
            return m.medianSentence.map(Double.init)
        case .repeats:
            guard m.rawKnown, m.words >= 5 else { return nil }
            return Double(m.repeats) / Double(m.words) * 100
        case .clarity:
            return m.polishChangeRatio
        }
    }

    /// Whether a dictation's value meets the measure.
    public func isHit(_ value: Double) -> Bool {
        switch self {
        case .fillers, .phrases: return value <= 1.0
        case .pace: return value <= 160
        case .sentences: return value <= 14
        case .repeats: return value == 0
        case .clarity: return value <= 0.15
        }
    }

    public func isHit(_ m: DictationMeasures) -> Bool? {
        value(of: m).map(isHit)
    }

    // MARK: Many dictations

    /// Dictations needed before an axis is drawn.
    public static let minimumSamples = 8

    /// 0 to 1 on the voice shape, 1 best; nil until there's enough to tell.
    public func axisScore(_ s: CoachSummary) -> Double? {
        func clamp(_ x: Double) -> Double { min(1, max(0, x)) }
        switch self {
        case .fillers:
            guard s.rawDictations >= Self.minimumSamples else { return nil }
            return clamp(1 - s.umUhRate / 5)
        case .phrases:
            guard s.rawDictations >= Self.minimumSamples else { return nil }
            return clamp(1 - s.phraseRate / 4)
        case .pace:
            guard s.pacedDictations >= Self.minimumSamples, let pace = s.pace else { return nil }
            let p = Double(pace)
            if p < 130 { return clamp(1 - (130 - p) / 60) }
            if p > 160 { return clamp(1 - (p - 160) / 60) }
            return 1
        case .sentences:
            guard s.rawDictations >= Self.minimumSamples, let median = s.medianSentence else { return nil }
            return median <= 14 ? 1 : clamp(1 - Double(median - 14) / 16)
        case .repeats:
            guard s.rawDictations >= Self.minimumSamples else { return nil }
            return clamp(1 - s.repeatRate / 2)
        case .clarity:
            guard s.clarityDictations >= Self.minimumSamples else { return nil }
            return clamp(1 - s.polishFixShare)
        }
    }

    /// The figure shown for a group of dictations, in `unit`.
    public func figure(_ s: CoachSummary) -> Double? {
        switch self {
        case .fillers: return s.rawDictations > 0 ? s.umUhRate : nil
        case .phrases: return s.rawDictations > 0 ? s.phraseRate : nil
        case .pace: return s.pace.map(Double.init)
        case .sentences: return s.medianSentence.map(Double.init)
        case .repeats: return s.rawDictations > 0 ? s.repeatRate : nil
        case .clarity: return s.clarityDictations > 0 ? s.polishFixShare : nil
        }
    }
}

/// Counts over many dictations, as Orttakey's CoachStats adds them up.
public struct CoachSummary: Sendable, Equatable {
    public var dictations: Int
    public var words: Int
    /// Words in dictations whose raw transcript is known.
    public var rawWords: Int
    public var rawDictations: Int
    public var umUh: Int
    public var phraseFillers: Int
    public var repeats: Int
    public var pacedDictations: Int
    public var pace: Int?
    /// The pace a quarter of dictations run above.
    public var fastPace: Int?
    public var medianSentence: Int?
    public var longestSentence: Int?
    public var clarityDictations: Int
    public var polishFixes: Int

    public init(_ all: [DictationMeasures]) {
        dictations = all.count
        words = all.reduce(0) { $0 + $1.words }
        let raw = all.filter(\.rawKnown)
        rawDictations = raw.count
        rawWords = raw.reduce(0) { $0 + $1.words }
        umUh = raw.reduce(0) { $0 + $1.umUh }
        phraseFillers = raw.reduce(0) { $0 + $1.phraseFillers }
        repeats = raw.reduce(0) { $0 + $1.repeats }
        let paces = all.compactMap(\.wpm).sorted()
        pacedDictations = paces.count
        pace = paces.isEmpty ? nil : paces[paces.count / 2]
        fastPace = paces.count < 4 ? nil : paces[paces.count * 3 / 4]
        let lengths = raw.flatMap(\.sentenceLengths).sorted()
        medianSentence = lengths.isEmpty ? nil : lengths[lengths.count / 2]
        longestSentence = lengths.last
        let ratios = all.compactMap(\.polishChangeRatio)
        clarityDictations = ratios.count
        polishFixes = ratios.filter { $0 > 0.15 }.count
    }

    /// um and uh per 100 words.
    public var umUhRate: Double { rawWords == 0 ? 0 : Double(umUh) / Double(rawWords) * 100 }
    public var phraseRate: Double { rawWords == 0 ? 0 : Double(phraseFillers) / Double(rawWords) * 100 }
    public var repeatRate: Double { rawWords == 0 ? 0 : Double(repeats) / Double(rawWords) * 100 }
    /// Share of dictations Polish rewrote by more than 15%.
    public var polishFixShare: Double { clarityDictations == 0 ? 0 : Double(polishFixes) / Double(clarityDictations) }
}

/// What to work on next, most needed first. Fillers, sentences and pace use
/// Orttakey's scores; phrases, repeats and Polish fixes are weighed below
/// them. One change from Orttakey: sentences need a long typical sentence,
/// not just one long one, since over four weeks of heavy dictation a single
/// 40-word sentence almost always turns up.
public enum CoachFocus {
    public static let umUhGoal = 1.0

    public static func needs(_ s: CoachSummary) -> [(measure: CoachMeasure, score: Double)] {
        var needs: [(CoachMeasure, Double)] = []
        let enough = s.rawDictations >= CoachMeasure.minimumSamples
        if enough, s.umUhRate > umUhGoal { needs.append((.fillers, s.umUhRate / umUhGoal)) }
        let median = Double(s.medianSentence ?? 0)
        let longest = Double(s.longestSentence ?? 0)
        if enough, median > 14 { needs.append((.sentences, 0.9 * max(median / 14, longest / 40))) }
        if s.pacedDictations >= CoachMeasure.minimumSamples, let fast = s.fastPace, fast > 160 {
            needs.append((.pace, 0.8 * Double(fast) / 160))
        }
        if enough, s.phraseRate > 1.0 { needs.append((.phrases, 0.85 * s.phraseRate)) }
        if enough, s.repeatRate > 0.5 { needs.append((.repeats, 0.7 * s.repeatRate / 0.5)) }
        if s.clarityDictations >= CoachMeasure.minimumSamples, s.polishFixShare > 0.3 {
            needs.append((.clarity, 0.7 * s.polishFixShare / 0.3))
        }
        return needs.sorted { $0.1 > $1.1 }.map { (measure: $0.0, score: $0.1) }
    }
}
