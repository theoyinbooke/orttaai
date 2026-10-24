// MilestoneComparisons.swift
// Orttaai

import Foundation

/// Turns word counts and speeds into things people can picture: how tall the
/// words would stand, how many pages they fill, how much faster speaking is.
/// Each card states the assumption it uses.
nonisolated enum MilestoneComparisons {
    /// One word printed in 12-point type, with its space, is about 1.2 cm.
    static let metresPerWord = 0.012
    static let wordsPerPage = 250
    /// An average English word is 4.7 letters, plus a space.
    static let keyPressesPerWord = 5.7
    static let typingWPM = 40.0
    static let handwritingWPM = 13.0
    static let conversationWPM = 150.0
    static let auctioneerWPM = 250.0

    struct Landmark: Sendable, Equatable {
        let name: String
        let metres: Double

        /// To the nearest 250 words, or 1,000 past 100,000.
        var wordsToReach: Int {
            let words = metres / MilestoneComparisons.metresPerWord
            let step = words >= 100_000 ? 1_000.0 : 250.0
            return Int((words / step).rounded() * step)
        }
    }

    static let landmarks: [Landmark] = [
        Landmark(name: "Statue of Liberty", metres: 93),
        Landmark(name: "Eiffel Tower", metres: 330),
        Landmark(name: "Burj Khalifa", metres: 828),
        Landmark(name: "Kilimanjaro", metres: 5_895),
        Landmark(name: "Everest", metres: 8_849),
    ]

    struct Book: Sendable, Equatable {
        let title: String
        let words: Int
    }

    static let books: [Book] = [
        Book(title: "The Great Gatsby", words: 47_000),
        Book(title: "an average novel", words: 90_000),
        Book(title: "War and Peace", words: 587_000),
    ]

    static func heightMetres(words: Int) -> Double {
        Double(max(0, words)) * metresPerWord
    }

    /// "24 m", "1.6 km".
    static func heightText(words: Int) -> String {
        let metres = heightMetres(words: words)
        if metres >= 1_000 {
            return String(format: "%.1f km", metres / 1_000)
        }
        return "\(Int(metres.rounded())) m"
    }

    static func lastLandmark(passedBy words: Int) -> Landmark? {
        landmarks.last { words >= $0.wordsToReach }
    }

    static func nextLandmark(after words: Int) -> Landmark? {
        landmarks.first { words < $0.wordsToReach }
    }

    /// A storey is about 3 metres.
    static func storeys(words: Int) -> Int {
        Int((heightMetres(words: words) / 3).rounded())
    }

    static func pages(words: Int) -> Int {
        Int((Double(max(0, words)) / Double(wordsPerPage)).rounded())
    }

    static func keyPresses(words: Int) -> Int {
        Int((Double(max(0, words)) * keyPressesPerWord).rounded())
    }

    /// "~11,400": an estimate, so to the nearest hundred.
    static func keyPressesText(words: Int) -> String {
        let presses = keyPresses(words: words)
        let rounded = presses >= 1_000 ? Int((Double(presses) / 100).rounded()) * 100 : presses
        return "~\(rounded.formatted())"
    }

    static func typingMinutes(words: Int) -> Int {
        Int((Double(max(0, words)) / typingWPM).rounded())
    }

    /// How many times faster than `baseline` a pace is, to one decimal
    /// below 10 ("4.5") and whole above it ("14").
    static func multiple(of wpm: Int, over baseline: Double) -> String {
        guard wpm > 0 else { return "0" }
        let value = Double(wpm) / baseline
        if value >= 10 { return String(Int(value.rounded())) }
        let rounded = (value * 10).rounded() / 10
        return rounded == rounded.rounded() ? String(Int(rounded)) : String(format: "%.1f", rounded)
    }

    /// The longest book the words already outrun, if any.
    static func longestBookPassed(words: Int) -> Book? {
        books.last { words >= $0.words }
    }

    /// "39 min", "1 hour", "2 h 5 min", "21 hours".
    static func durationText(minutes: Int) -> String {
        if minutes < 60 { return "\(minutes) min" }
        let hours = minutes / 60
        let rest = minutes % 60
        if hours >= 10 || rest == 0 {
            let whole = Int((Double(minutes) / 60).rounded())
            return whole == 1 ? "1 hour" : "\(whole) hours"
        }
        return "\(hours) h \(rest) min"
    }

    /// A screen-time equivalent of the time given back.
    static func timeBackEquivalent(minutes: Int) -> String {
        switch minutes {
        case ..<15: return "a coffee break"
        case ..<75: return "a TV episode"
        case ..<180: return "a feature film"
        case ..<600: return "a working day"
        default: return "\(max(2, minutes / 480)) working days"
        }
    }
}
