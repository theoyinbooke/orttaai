// MilestoneCatalog.swift
// Orttaai

import Foundation

/// The five groups the Milestones page lays badges out in.
nonisolated enum MilestoneFamily: String, CaseIterable, Sendable {
    case words
    case streaks
    case speedAndTime
    case dictations
    case special

    var title: String {
        switch self {
        case .words: return "Words"
        case .streaks: return "Streaks"
        case .speedAndTime: return "Speed & time"
        case .dictations: return "Dictations"
        case .special: return "Special"
        }
    }

    var note: String {
        switch self {
        case .words: return "Total words dictated"
        case .streaks: return "Days in a row with a dictation"
        case .speedAndTime: return "Pace, and typing time you got back"
        case .dictations: return "Times you held the key and spoke"
        case .special: return "How and where you dictate"
        }
    }
}

nonisolated enum MilestoneTier: Int, Comparable, Sendable {
    case bronze
    case silver
    case gold

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// The number a badge is measured on. Every one comes from data Orttaai
/// already keeps; none reads what was said.
nonisolated enum MilestoneMetric: Sendable {
    case words
    case dictations
    /// The longest run of local days with a dictation, ever.
    case bestStreakDays
    case bestWPM
    case minutesSaved
    case distinctApps
    case longestDictationSeconds
    case nightOwlDictations
    case dictionaryWords
}

nonisolated struct MilestoneBadge: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    /// What it takes, in a few words ("10 dictionary words").
    let rule: String
    let family: MilestoneFamily
    let tier: MilestoneTier
    /// SF Symbol drawn in the middle of the badge.
    let symbol: String
    let metric: MilestoneMetric
    let threshold: Int
}

nonisolated enum MilestoneCatalog {
    static let badges: [MilestoneBadge] = [
        badge("first-words", "First Words", "Your first dictation", .words, .bronze, "waveform", .dictations, 1),
        badge("words-1k", "1,000 Words", "About 4 pages", .words, .bronze, "text.alignleft", .words, 1_000),
        badge("words-5k", "5,000 Words", "A long essay", .words, .silver, "text.alignleft", .words, 5_000),
        badge("words-10k", "10,000 Words", "A short story", .words, .silver, "text.alignleft", .words, 10_000),
        badge("words-50k", "50,000 Words", "A novel draft", .words, .gold, "book.closed", .words, 50_000),
        badge("words-100k", "100,000 Words", "A full novel", .words, .gold, "books.vertical", .words, 100_000),
        badge("words-1m", "A Million Words", "A lifetime of typing", .words, .gold, "crown", .words, 1_000_000),

        badge("streak-3", "3-Day Streak", "3 days running", .streaks, .bronze, "flame", .bestStreakDays, 3),
        badge("streak-7", "7-Day Streak", "A full week", .streaks, .silver, "flame", .bestStreakDays, 7),
        badge("streak-30", "30-Day Streak", "A month of talking", .streaks, .gold, "flame", .bestStreakDays, 30),
        badge("streak-100", "100-Day Streak", "A habit for good", .streaks, .gold, "flame.fill", .bestStreakDays, 100),

        badge("quick-talker", "Quick Talker", "150 WPM in a dictation", .speedAndTime, .gold, "bolt", .bestWPM, 150),
        badge("lightning", "Lightning", "200 WPM in a dictation", .speedAndTime, .gold, "bolt.fill", .bestWPM, 200),
        badge("hour-saved", "An Hour Saved", "1 hour of typing back", .speedAndTime, .bronze, "clock", .minutesSaved, 60),
        badge("ten-hours-saved", "Ten Hours Saved", "10 hours of typing back", .speedAndTime, .silver, "clock.badge.checkmark", .minutesSaved, 600),

        badge("dictations-10", "Ten Dictations", "10 dictations", .dictations, .bronze, "square.stack", .dictations, 10),
        badge("dictations-50", "50 Dictations", "50 dictations", .dictations, .silver, "square.stack.3d.up", .dictations, 50),
        badge("dictations-500", "500 Dictations", "500 dictations", .dictations, .gold, "square.stack.3d.up.fill", .dictations, 500),

        badge("three-apps", "Three Apps", "Dictated in 3 apps", .special, .bronze, "square.grid.2x2", .distinctApps, 3),
        badge("marathon", "Marathon", "One dictation over a minute", .special, .silver, "stopwatch", .longestDictationSeconds, 60),
        badge("wordsmith", "Wordsmith", "10 dictionary words", .special, .silver, "character.book.closed", .dictionaryWords, 10),
        badge("night-owl", "Night Owl", "Dictated after midnight", .special, .bronze, "moon", .nightOwlDictations, 1),
    ]

    static func badge(withID id: String) -> MilestoneBadge? {
        badges.first { $0.id == id }
    }

    private static func badge(
        _ id: String,
        _ name: String,
        _ rule: String,
        _ family: MilestoneFamily,
        _ tier: MilestoneTier,
        _ symbol: String,
        _ metric: MilestoneMetric,
        _ threshold: Int
    ) -> MilestoneBadge {
        MilestoneBadge(id: id, name: name, rule: rule, family: family, tier: tier, symbol: symbol, metric: metric, threshold: threshold)
    }
}
