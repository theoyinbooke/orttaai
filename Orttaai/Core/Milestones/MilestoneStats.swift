// MilestoneStats.swift
// Orttaai

import Foundation

/// What the milestone engine needs from one dictation: counts and times,
/// never the text itself.
nonisolated struct MilestoneDictation: Sendable, Equatable {
    let createdAt: Date
    let words: Int
    let recordingMs: Int
    let appName: String?

    init(createdAt: Date, words: Int, recordingMs: Int, appName: String?) {
        self.createdAt = createdAt
        self.words = words
        self.recordingMs = recordingMs
        self.appName = appName
    }

    /// Whitespace-separated words, the same count the dashboard shows.
    static func wordCount(of text: String) -> Int {
        text.split(whereSeparator: \.isWhitespace).count
    }
}

/// Running totals behind every badge. `compute` replays dictations oldest
/// first, so it also knows when each badge's threshold was first crossed.
nonisolated struct MilestoneStats: Sendable, Equatable {
    var totalWords = 0
    var dictations = 0
    var speakingMs = 0
    var bestWPM = 0
    var bestStreakDays = 0
    /// Days in the streak still running today or yesterday; 0 once broken.
    var currentStreakDays = 0
    var distinctApps = 0
    var longestDictationMs = 0
    var nightOwlDictations = 0
    var dictionaryWords = 0
    var firstDictationAt: Date?

    /// A dictation must have this many words and seconds before its pace
    /// counts, so a clipped two-word note can't set a speed record.
    static let minimumWordsForPace = 10
    static let minimumMsForPace = 3_000
    /// Local hours that count as after midnight for Night Owl.
    static let nightOwlHours = 0..<5

    /// Typing the same words at 40 WPM, minus the time spent speaking them.
    var minutesSaved: Int {
        let typingMinutes = Double(totalWords) / MilestoneComparisons.typingWPM
        let speakingMinutes = Double(speakingMs) / 60_000
        return max(0, Int((typingMinutes - speakingMinutes).rounded(.down)))
    }

    var speakingMinutes: Int {
        Int((Double(speakingMs) / 60_000).rounded())
    }

    var averageWPM: Int {
        guard speakingMs > 0 else { return 0 }
        return Int((Double(totalWords) / (Double(speakingMs) / 60_000)).rounded())
    }

    func value(for metric: MilestoneMetric) -> Int {
        switch metric {
        case .words: return totalWords
        case .dictations: return dictations
        case .bestStreakDays: return bestStreakDays
        case .bestWPM: return bestWPM
        case .minutesSaved: return minutesSaved
        case .distinctApps: return distinctApps
        case .longestDictationSeconds: return longestDictationMs / 1_000
        case .nightOwlDictations: return nightOwlDictations
        case .dictionaryWords: return dictionaryWords
        }
    }

    struct Result: Sendable, Equatable {
        let stats: MilestoneStats
        /// Badge id → when its threshold was first crossed.
        let crossings: [String: Date]
    }

    static func compute(
        dictations: [MilestoneDictation],
        dictionaryEntryDates: [Date],
        badges: [MilestoneBadge] = MilestoneCatalog.badges,
        calendar: Calendar = .current,
        now: Date = Date()
    ) -> Result {
        var stats = MilestoneStats()
        var crossings: [String: Date] = [:]
        var apps = Set<String>()
        var lastDay: Date?
        var run = 0

        func record(at date: Date) {
            for badge in badges where crossings[badge.id] == nil && badge.metric != .dictionaryWords {
                if stats.value(for: badge.metric) >= badge.threshold {
                    crossings[badge.id] = date
                }
            }
        }

        for dictation in dictations.sorted(by: { $0.createdAt < $1.createdAt }) {
            stats.dictations += 1
            stats.totalWords += max(0, dictation.words)
            stats.speakingMs += max(0, dictation.recordingMs)
            stats.longestDictationMs = max(stats.longestDictationMs, dictation.recordingMs)
            if stats.firstDictationAt == nil { stats.firstDictationAt = dictation.createdAt }

            if dictation.words >= minimumWordsForPace, dictation.recordingMs >= minimumMsForPace {
                let pace = Double(dictation.words) / (Double(dictation.recordingMs) / 60_000)
                stats.bestWPM = max(stats.bestWPM, Int(pace.rounded()))
            }

            if let app = dictation.appName?.trimmingCharacters(in: .whitespacesAndNewlines), !app.isEmpty {
                apps.insert(app.lowercased())
                stats.distinctApps = apps.count
            }

            if nightOwlHours.contains(calendar.component(.hour, from: dictation.createdAt)) {
                stats.nightOwlDictations += 1
            }

            let day = calendar.startOfDay(for: dictation.createdAt)
            if let lastDay, day != lastDay {
                let gap = calendar.dateComponents([.day], from: lastDay, to: day).day ?? 0
                run = gap == 1 ? run + 1 : 1
            } else if lastDay == nil {
                run = 1
            }
            lastDay = day
            stats.bestStreakDays = max(stats.bestStreakDays, run)

            record(at: dictation.createdAt)
        }

        if let lastDay {
            let sinceLast = calendar.dateComponents([.day], from: lastDay, to: calendar.startOfDay(for: now)).day ?? 0
            stats.currentStreakDays = sinceLast <= 1 ? run : 0
        }

        let entryDates = dictionaryEntryDates.sorted()
        stats.dictionaryWords = entryDates.count
        for badge in badges where badge.metric == .dictionaryWords && badge.threshold > 0 && entryDates.count >= badge.threshold {
            crossings[badge.id] = entryDates[badge.threshold - 1]
        }

        return Result(stats: stats, crossings: crossings)
    }
}
