// ShareCardStory.swift
// Orttaai

import Foundation

/// What a milestone is about, which decides the card designs offered for it
/// and what they say. Each kind has its own picture plus the shared designs,
/// all telling that milestone's story with its own number.
enum ShareCardKind: Equatable {
    case progress, firstWords, words, streak, speed, timeSaved, dictations, apps, marathon, dictionary, nightOwl

    init(badge: MilestoneBadge?) {
        guard let badge else { self = .progress; return }
        if badge.id == "first-words" { self = .firstWords; return }
        switch badge.metric {
        case .words: self = .words
        case .dictations: self = .dictations
        case .bestStreakDays: self = .streak
        case .bestWPM: self = .speed
        case .minutesSaved: self = .timeSaved
        case .distinctApps: self = .apps
        case .longestDictationSeconds: self = .marathon
        case .dictionaryWords: self = .dictionary
        case .nightOwlDictations: self = .nightOwl
        }
    }

    /// The designs for this kind, its own picture first.
    var templates: [ShareCardTemplate] {
        switch self {
        case .progress: return [.mountain, .books, .speed, .hands, .receipt, .signal, .editorial, .medal]
        case .firstWords: return [.signal, .editorial, .receipt, .medal]
        case .words: return [.mountain, .books, .editorial, .receipt, .signal, .medal]
        case .streak: return [.streak, .signal, .editorial, .medal]
        case .speed: return [.speed, .race, .signal, .editorial, .medal]
        case .timeSaved: return [.hands, .receipt, .signal, .editorial, .medal]
        case .dictations: return [.stack, .receipt, .signal, .editorial, .medal]
        case .apps: return [.apps, .signal, .editorial, .medal]
        case .marathon: return [.stopwatch, .signal, .editorial, .medal]
        case .dictionary: return [.dictionary, .signal, .editorial, .medal]
        case .nightOwl: return [.night, .signal, .editorial, .medal]
        }
    }
}

/// A number and what it counts, for the row of stats on a card.
struct ShareStat: Hashable {
    let value: String
    let label: String
}

extension ShareCardContent {
    var kind: ShareCardKind { ShareCardKind(badge: badge) }

    /// The milestone's own threshold, or the running total for progress.
    var milestoneValue: Int {
        guard let badge else { return stats.totalWords }
        return badge.metric == .bestWPM ? stats.bestWPM : badge.threshold
    }

    /// Editorial's sentence: plain, then the italic part, then plain.
    var headline: (lead: String, emphasis: String, tail: String) {
        let total = stats.totalWords.formatted()
        switch kind {
        case .progress:
            return ("I spoke \(total) words to my Mac and typed ", "none", " of them.")
        case .firstWords:
            return ("My first words to my Mac, and ", "not one key", " pressed.")
        case .words:
            return ("I've spoken ", "\(words.formatted()) words", " to my Mac instead of typing them.")
        case .streak:
            return ("I talked to my Mac ", "\(milestoneValue) days", " in a row.")
        case .speed:
            return ("I dictate at ", "\(stats.bestWPM) words a minute", ", faster than I can type.")
        case .timeSaved:
            return ("Talking gave me back ", MilestoneComparisons.durationText(minutes: milestoneValue), " of typing.")
        case .dictations:
            return ("I've made ", "\(milestoneValue.formatted()) dictations", ", every word spoken instead of typed.")
        case .apps:
            return ("One voice, ", "\(milestoneValue) apps", ". Orttaai types wherever I am.")
        case .marathon:
            return ("I talked for ", Self.secondsText(stats.longestDictationMs / 1_000), " in one go.")
        case .dictionary:
            return ("My Mac knows ", "\(milestoneValue) words", " the way I spell them.")
        case .nightOwl:
            return ("After midnight, my ", "keyboard", " got the night off.")
        }
    }

    /// One plain line under the headline.
    var supportLine: String {
        switch kind {
        case .progress, .words:
            return "\(MilestoneComparisons.pages(words: words).formatted()) pages of a book. \(MilestoneComparisons.heightText(words: words)) of words, stood on end."
        case .firstWords:
            return "Started \(dateText). Talking instead of typing from here on."
        case .streak:
            return "A dictation every day, and the keyboard got a rest."
        case .speed:
            let typing = MilestoneComparisons.multiple(of: stats.bestWPM, over: MilestoneComparisons.typingWPM)
            let writing = MilestoneComparisons.multiple(of: stats.bestWPM, over: MilestoneComparisons.handwritingWPM)
            return "\(typing)× typing at 40 words a minute, \(writing)× writing by hand."
        case .timeSaved:
            return "About \(MilestoneComparisons.timeBackEquivalent(minutes: milestoneValue)), with both hands free."
        case .dictations:
            return "About \(wordsPerDictation) words each, spoken at the cursor."
        case .apps:
            return "Wherever the cursor is, my voice works."
        case .marathon:
            return "One long dictation, hands free the whole time."
        case .dictionary:
            return "Names and terms come out right, every time."
        case .nightOwl:
            return "\(stats.nightOwlDictations.formatted()) dictation\(stats.nightOwlDictations == 1 ? "" : "s") after 12 a.m."
        }
    }

    /// Three numbers about this milestone; the last is drawn in amber.
    var supportingStats: [ShareStat] {
        let dictations = ShareStat(value: stats.dictations.formatted(), label: "dictations")
        let totalWords = ShareStat(value: stats.totalWords.formatted(), label: "words so far")
        let saved = ShareStat(value: MilestoneComparisons.durationText(minutes: stats.minutesSaved), label: "of typing saved")
        switch kind {
        case .progress:
            return [totalWords, ShareStat(value: pace > 0 ? "\(pace)" : "–", label: "words a minute"), saved]
        case .firstWords:
            return [
                ShareStat(value: (earnedOn ?? Date()).formatted(.dateTime.month(.abbreviated).day()), label: "first dictation"),
                dictations, totalWords,
            ]
        case .words:
            return [
                ShareStat(value: MilestoneComparisons.pages(words: words).formatted(), label: "pages of a book"),
                ShareStat(value: MilestoneComparisons.keyPressesText(words: words), label: "keys I didn't press"),
                ShareStat(value: MilestoneComparisons.durationText(minutes: MilestoneComparisons.typingMinutes(words: words)), label: "to type them"),
            ]
        case .streak:
            return [
                ShareStat(value: "\(stats.bestStreakDays)", label: "best streak, days"),
                ShareStat(value: "\(stats.currentStreakDays)", label: "days running now"),
                dictations,
            ]
        case .speed:
            return [
                ShareStat(value: "\(stats.bestWPM)", label: "best words a minute"),
                ShareStat(value: stats.averageWPM > 0 ? "\(stats.averageWPM)" : "–", label: "on average"),
                ShareStat(value: "\(MilestoneComparisons.multiple(of: stats.bestWPM, over: MilestoneComparisons.typingWPM))×", label: "faster than typing"),
            ]
        case .timeSaved:
            return [totalWords, ShareStat(value: MilestoneComparisons.durationText(minutes: stats.speakingMinutes), label: "spent speaking"), saved]
        case .dictations:
            return [
                ShareStat(value: milestoneValue.formatted(), label: "dictations"),
                ShareStat(value: "\(wordsPerDictation)", label: "words each"),
                totalWords,
            ]
        case .apps:
            return [ShareStat(value: "\(stats.distinctApps)", label: "apps so far"), dictations, totalWords]
        case .marathon:
            return [
                ShareStat(value: Self.secondsText(stats.longestDictationMs / 1_000), label: "longest dictation"),
                ShareStat(value: stats.averageWPM > 0 ? "\(stats.averageWPM)" : "–", label: "words a minute"),
                dictations,
            ]
        case .dictionary:
            return [ShareStat(value: "\(stats.dictionaryWords)", label: "words in it now"), dictations, totalWords]
        case .nightOwl:
            return [ShareStat(value: stats.nightOwlDictations.formatted(), label: "after midnight"), dictations, totalWords]
        }
    }

    /// The receipt's lines, led by this milestone's own number.
    var receiptLines: [(String, String)] {
        let lead: (String, String)?
        switch kind {
        case .dictations: lead = ("DICTATIONS", milestoneValue.formatted())
        case .timeSaved: lead = ("TIME SAVED", MilestoneComparisons.durationText(minutes: milestoneValue).uppercased())
        case .firstWords: lead = ("FIRST DICTATION", (earnedOn ?? Date()).formatted(.dateTime.month(.abbreviated).day()).uppercased())
        default: lead = nil
        }
        let rows: [(String, String)] = [
            ("WORDS SPOKEN", words.formatted()),
            ("PAGES OF A BOOK", MilestoneComparisons.pages(words: words).formatted()),
            ("HEIGHT, STOOD UP", MilestoneComparisons.heightText(words: words).uppercased()),
            ("KEYS NOT PRESSED", MilestoneComparisons.keyPressesText(words: words)),
            ("TIME SPEAKING", "\(speakingMinutes) MIN"),
            ("TIME TYPING IT", "\(MilestoneComparisons.typingMinutes(words: words).formatted()) MIN"),
        ]
        return (lead.map { [$0] } ?? []) + rows
    }

    /// Minutes saved for the words on the card: the milestone's words for a
    /// words badge, else everything so far.
    var minutesSavedOnCard: Int {
        guard kind == .words else { return stats.minutesSaved }
        return max(0, MilestoneComparisons.typingMinutes(words: words) - speakingMinutes)
    }

    /// Time spent speaking the words on the card, at the person's pace.
    var speakingMinutes: Int {
        guard kind == .words, stats.averageWPM > 0 else { return stats.speakingMinutes }
        return Int((Double(words) / Double(stats.averageWPM)).rounded())
    }

    var wordsPerDictation: Int {
        stats.dictations > 0 ? Int((Double(stats.totalWords) / Double(stats.dictations)).rounded()) : 0
    }

    /// "48 s", "1 min 12 s".
    static func secondsText(_ seconds: Int) -> String {
        if seconds < 60 { return "\(seconds) s" }
        let rest = seconds % 60
        return rest == 0 ? "\(seconds / 60) min" : "\(seconds / 60) min \(rest) s"
    }
}
