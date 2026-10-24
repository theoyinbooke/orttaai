// MilestoneCopy.swift
// Orttaai

import Foundation

/// The sentence under a badge in its celebration and toast, written from the
/// person's own numbers so each one says what the milestone means.
nonisolated enum MilestoneCopy {
    static func celebrationLine(for badge: MilestoneBadge, stats: MilestoneStats) -> String {
        switch badge.metric {
        case .words where badge.id == "first-words", .dictations where badge.id == "first-words":
            return "Your first dictation is in. Welcome to talking instead of typing."
        case .words:
            let words = stats.totalWords
            let pages = MilestoneComparisons.pages(words: words)
            let height = MilestoneComparisons.heightText(words: words)
            if let book = MilestoneComparisons.longestBookPassed(words: words) {
                return "\(words.formatted()) words: longer than \(book.title), and \(height) tall stood on end."
            }
            return "\(words.formatted()) words: \(pages.formatted()) pages of a book, and \(height) tall stood on end."
        case .dictations:
            return "\(stats.dictations.formatted()) dictations, every word spoken instead of typed."
        case .bestStreakDays:
            return "\(stats.bestStreakDays) days in a row with a dictation."
        case .bestWPM:
            let typing = MilestoneComparisons.multiple(of: stats.bestWPM, over: MilestoneComparisons.typingWPM)
            return "\(stats.bestWPM) words a minute, \(typing)× faster than typing."
        case .minutesSaved:
            let saved = MilestoneComparisons.durationText(minutes: stats.minutesSaved)
            let equivalent = MilestoneComparisons.timeBackEquivalent(minutes: stats.minutesSaved)
            return "\(saved) of typing back, with both hands free. About \(equivalent)."
        case .distinctApps:
            return "Orttaai has typed for you in \(stats.distinctApps) apps."
        case .longestDictationSeconds:
            return "One dictation ran over a minute. Hands free the whole time."
        case .dictionaryWords:
            return "Your dictionary has \(stats.dictionaryWords) words, so names come out your way."
        case .nightOwlDictations:
            return "Dictating after midnight. Your keyboard got the night off."
        }
    }
}
