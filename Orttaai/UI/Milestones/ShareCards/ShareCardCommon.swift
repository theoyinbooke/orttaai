// ShareCardCommon.swift
// Orttaai

import SwiftUI

enum ShareCardTemplate: String, CaseIterable, Identifiable {
    case mountain, books, speed, hands, receipt, signal, editorial, medal
    case streak, race, stack, apps, stopwatch, dictionary, night

    var id: String { rawValue }

    var title: String {
        switch self {
        case .mountain: return "Mountain"
        case .books: return "Books"
        case .speed: return "Speed"
        case .hands: return "Hands Free"
        case .receipt: return "Receipt"
        case .signal: return "Signal"
        case .editorial: return "Editorial"
        case .medal: return "Medal"
        case .streak: return "Streak"
        case .race: return "Race"
        case .stack: return "Stack"
        case .apps: return "Apps"
        case .stopwatch: return "Stopwatch"
        case .dictionary: return "Dictionary"
        case .night: return "Night"
        }
    }
}

enum ShareCardSize: String, CaseIterable, Identifiable {
    case portrait, square, story

    var id: String { rawValue }

    var title: String {
        switch self {
        case .portrait: return "Portrait 4:5"
        case .square: return "Square"
        case .story: return "Story 9:16"
        }
    }

    /// Exact pixel size of the exported image.
    var pixels: CGSize {
        switch self {
        case .portrait: return CGSize(width: 1080, height: 1350)
        case .square: return CGSize(width: 1080, height: 1080)
        case .story: return CGSize(width: 1080, height: 1920)
        }
    }

    var isSquare: Bool { self == .square }
}

/// Everything a card shows, worked out once from the person's numbers.
/// Numbers only: never any text they dictated.
struct ShareCardContent {
    let stats: MilestoneStats
    let badge: MilestoneBadge?
    let earnedOn: Date?

    /// The words a card is about: a words badge's own count (1,000 for
    /// 1,000 Words), else everything dictated so far.
    var words: Int {
        if let badge, badge.metric == .words { return badge.threshold }
        return stats.totalWords
    }

    /// Pace for speed cards: the record for speed badges, else the average.
    var pace: Int {
        if badge?.metric == .bestWPM { return stats.bestWPM }
        return stats.averageWPM > 0 ? stats.averageWPM : stats.bestWPM
    }

    var eyebrow: String {
        if let badge { return "MILESTONE · \(badge.name.uppercased())" }
        return "\(words.formatted()) WORDS"
    }

    /// The big number and its label on the Signal card.
    var hero: (value: String, label: String) {
        guard let badge else { return (words.formatted(), "words dictated") }
        switch badge.metric {
        case .words: return (badge.threshold.formatted(), "words dictated")
        case .dictations where badge.threshold == 1: return ("1st", "dictation")
        case .dictations: return (badge.threshold.formatted(), "dictations")
        case .bestStreakDays: return ("\(badge.threshold)", "days in a row")
        case .bestWPM: return ("\(stats.bestWPM)", "words a minute")
        case .minutesSaved: return (MilestoneComparisons.durationText(minutes: badge.threshold), "of typing saved")
        case .distinctApps: return ("\(badge.threshold)", "apps, one voice")
        case .longestDictationSeconds: return ("\(stats.longestDictationMs / 1_000)s", "in one go")
        case .dictionaryWords: return ("\(badge.threshold)", "dictionary words")
        case .nightOwlDictations: return ("After 12", "dictating at night")
        }
    }

    var dateText: String {
        (earnedOn ?? Date()).formatted(.dateTime.month(.wide).day().year())
    }

    /// The badge a Medal card shows: the shared one, else the best earned.
    func medalBadge(unlocked: [MilestoneBadge]) -> MilestoneBadge {
        badge ?? unlocked.max { $0.tier < $1.tier } ?? MilestoneCatalog.badges[0]
    }
}

enum ShareCardStyle {
    static let charcoal = Color(hex: "1C1C1E")
    static let night = Color(hex: "141416")
    static let cream = Color(hex: "F5F3F0")
    static let paper = Color(hex: "EFE8DC")
    static let amber = Color(hex: "D4952A")
    static let gold = Color(hex: "E2B04A")
    static let grey = Color(hex: "A1A1A6")
    static let dim = Color(hex: "8E8E93")
    static let tile = Color(hex: "232325")
    static let line = Color(hex: "3A3A3C")
    static let tagline = "Giving you back both hands."
    static let product = "Voice typing for Mac"
}

/// Mark and name, top left of every card.
struct ShareCardBrand: View {
    var color: Color = ShareCardStyle.amber
    var textColor: Color = ShareCardStyle.cream
    var markHeight: CGFloat = 40

    var body: some View {
        HStack(spacing: 14) {
            OrttaaiBrandMark(color: color)
                .frame(width: markHeight * SignalCursorGlyph.aspectRatio, height: markHeight)
            Text("Orttaai")
                .font(.system(size: markHeight * 0.8, weight: .semibold))
                .foregroundStyle(textColor)
        }
    }
}

/// Tagline left, product right: the line every card ends on.
struct ShareCardFooter: View {
    var color: Color = ShareCardStyle.dim
    var taglineColor: Color = Color(hex: "C7C7CC")
    var trailing: String = ShareCardStyle.product

    var body: some View {
        HStack {
            Text(ShareCardStyle.tagline)
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(taglineColor)
            Spacer()
            Text(trailing)
                .font(.system(size: 24))
                .foregroundStyle(color)
        }
    }
}

/// A card at its exact size; the template picks the design.
struct ShareCardView: View {
    let template: ShareCardTemplate
    let content: ShareCardContent
    let size: ShareCardSize
    var unlocked: [MilestoneBadge] = []

    var body: some View {
        Group {
            switch template {
            case .mountain: MountainShareCard(content: content, size: size)
            case .books: BooksShareCard(content: content, size: size)
            case .speed: SpeedShareCard(content: content, size: size)
            case .hands: HandsShareCard(content: content, size: size)
            case .receipt: ReceiptShareCard(content: content, size: size)
            case .signal: SignalShareCard(content: content, size: size)
            case .editorial: EditorialShareCard(content: content, size: size)
            case .medal: MedalShareCard(content: content, size: size, badge: content.medalBadge(unlocked: unlocked))
            case .streak: StreakShareCard(content: content, size: size)
            case .race: RaceShareCard(content: content, size: size)
            case .stack: StackShareCard(content: content, size: size)
            case .apps: AppsShareCard(content: content, size: size)
            case .stopwatch: StopwatchShareCard(content: content, size: size)
            case .dictionary: DictionaryShareCard(content: content, size: size)
            case .night: NightShareCard(content: content, size: size)
            }
        }
        .frame(width: size.pixels.width, height: size.pixels.height)
        .clipped()
        .environment(\.colorScheme, .dark)
    }
}

/// Renders a card to an image at its exact pixel size.
@MainActor
enum ShareCardRenderer {
    static func image(for card: ShareCardView) -> NSImage? {
        let renderer = ImageRenderer(content: card)
        renderer.scale = 1
        renderer.proposedSize = ProposedViewSize(card.size.pixels)
        guard let cgImage = renderer.cgImage else { return nil }
        return NSImage(cgImage: cgImage, size: card.size.pixels)
    }

    static func pngData(for card: ShareCardView) -> Data? {
        guard let image = image(for: card),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let bitmap = NSBitmapImageRep(cgImage: cgImage)
        return bitmap.representation(using: .png, properties: [:])
    }
}
