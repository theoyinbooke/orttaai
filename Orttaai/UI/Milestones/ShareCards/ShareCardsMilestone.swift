// ShareCardsMilestone.swift
// Orttaai

import SwiftUI

/// The layout the milestone pictures share: brand and milestone at the top,
/// a headline, the picture, three numbers, the footer.
private struct MilestoneCardLayout<Headline: View, Picture: View>: View {
    let content: ShareCardContent
    let size: ShareCardSize
    var background: Color = ShareCardStyle.charcoal
    @ViewBuilder let headline: () -> Headline
    @ViewBuilder let picture: (CGFloat) -> Picture

    private var pictureHeight: CGFloat {
        switch size {
        case .portrait: return 560
        case .square: return 360
        case .story: return 980
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                ShareCardBrand(markHeight: 40)
                Spacer()
                Text(content.badge?.name.uppercased() ?? "MILESTONE")
                    .font(.system(size: 22, weight: .bold))
                    .tracking(3)
                    .foregroundStyle(ShareCardStyle.amber)
            }

            headline()
                .font(.system(size: size.isSquare ? 72 : 84, weight: .black))
                .tracking(-2)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, size.isSquare ? 32 : 56)

            Spacer(minLength: 16)
            picture(pictureHeight)
                .frame(maxWidth: .infinity)
                .frame(height: pictureHeight)
            Spacer(minLength: 16)

            HStack(spacing: 18) {
                ForEach(Array(content.supportingStats.enumerated()), id: \.offset) { index, stat in
                    MilestoneStatTile(stat: stat, accent: index == 2)
                }
            }

            ShareCardFooter()
                .padding(.top, size.isSquare ? 28 : 40)
        }
        .padding(84)
        .foregroundStyle(ShareCardStyle.cream)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(background)
    }
}

private struct MilestoneStatTile: View {
    let stat: ShareStat
    let accent: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(stat.value)
                .font(.system(size: 46, weight: .heavy))
                .foregroundStyle(accent ? ShareCardStyle.amber : ShareCardStyle.cream)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
            Text(stat.label)
                .font(.system(size: 21))
                .foregroundStyle(Color(hex: "C7C7CC"))
                .lineLimit(2)
        }
        .padding(24)
        .frame(maxWidth: .infinity, minHeight: 140, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 22).fill(Color.white.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(accent ? ShareCardStyle.amber : ShareCardStyle.line, lineWidth: 1))
    }
}

private func amber(_ text: String) -> Text {
    Text(text).foregroundColor(ShareCardStyle.amber)
}

// MARK: - Streak

/// The streak's days as a calendar of flames.
struct StreakShareCard: View {
    let content: ShareCardContent
    let size: ShareCardSize

    var body: some View {
        let days = max(1, content.milestoneValue)
        MilestoneCardLayout(content: content, size: size) {
            amber("\(days) days") + Text("\nin a row.")
        } picture: { height in
            StreakGrid(days: days, height: height)
        }
    }
}

private struct StreakGrid: View {
    let days: Int
    let height: CGFloat

    var body: some View {
        let columns = days <= 35 ? 7 : 10
        let rows = Int((Double(days) / Double(columns)).rounded(.up))
        let gap: CGFloat = days <= 35 ? 16 : 10
        let cell = min((912 - gap * CGFloat(columns - 1)) / CGFloat(columns), (height - gap * CGFloat(rows - 1)) / CGFloat(rows), 116)
        VStack(spacing: gap) {
            ForEach(0..<rows, id: \.self) { row in
                HStack(spacing: gap) {
                    ForEach(0..<columns, id: \.self) { column in
                        let index = row * columns + column
                        dayCell(filled: index < days, last: index == days - 1, size: cell)
                    }
                }
            }
        }
    }

    private func dayCell(filled: Bool, last: Bool, size: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
            .fill(filled ? ShareCardStyle.amber.opacity(last ? 1 : 0.85) : Color.white.opacity(0.04))
            .overlay(
                RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                    .strokeBorder(filled ? Color.clear : ShareCardStyle.line, lineWidth: 2)
            )
            .overlay {
                if filled {
                    Image(systemName: last ? "flame.fill" : "flame")
                        .font(.system(size: size * 0.42, weight: .semibold))
                        .foregroundStyle(ShareCardStyle.charcoal)
                }
            }
            .frame(width: size, height: size)
    }
}

// MARK: - Race

/// The person's best pace in a line-up from handwriting to an auctioneer.
struct RaceShareCard: View {
    let content: ShareCardContent
    let size: ShareCardSize

    var body: some View {
        let pace = content.stats.bestWPM
        MilestoneCardLayout(content: content, size: size) {
            Text("I out-talk my keyboard ") + amber("\(MilestoneComparisons.multiple(of: pace, over: MilestoneComparisons.typingWPM))×") + Text(".")
        } picture: { height in
            RaceBars(pace: pace, height: height)
        }
    }
}

private struct RaceBars: View {
    let pace: Int
    let height: CGFloat

    private var entries: [(name: String, wpm: Int, me: Bool)] {
        let others: [(String, Double)] = [
            ("Handwriting", MilestoneComparisons.handwritingWPM),
            ("Typing", MilestoneComparisons.typingWPM),
            ("Conversation", MilestoneComparisons.conversationWPM),
            ("Auctioneer", MilestoneComparisons.auctioneerWPM),
        ]
        return (others.map { ($0.0, Int($0.1), false) } + [("Me, talking", pace, true)])
            .sorted { $0.1 < $1.1 }
    }

    var body: some View {
        let top = Double(max(250, pace))
        let rowHeight = min(96, height / 5 - 14)
        VStack(alignment: .leading, spacing: 14) {
            ForEach(entries, id: \.name) { entry in
                HStack(spacing: 22) {
                    Text(entry.name)
                        .font(.system(size: 28, weight: entry.me ? .heavy : .semibold))
                        .foregroundStyle(entry.me ? ShareCardStyle.amber : Color(hex: "C7C7CC"))
                        .frame(width: 230, alignment: .leading)
                    GeometryReader { proxy in
                        RoundedRectangle(cornerRadius: rowHeight * 0.28, style: .continuous)
                            .fill(entry.me ? ShareCardStyle.amber : Color(hex: "3A3A3E"))
                            .frame(width: max(rowHeight, proxy.size.width * Double(entry.wpm) / top))
                            .overlay(alignment: .trailing) {
                                Text("\(entry.wpm)")
                                    .font(.system(size: 30, weight: .heavy))
                                    .foregroundStyle(entry.me ? ShareCardStyle.charcoal : ShareCardStyle.cream)
                                    .padding(.trailing, 18)
                                    .fixedSize()
                            }
                    }
                    .frame(height: rowHeight)
                }
            }
            Text("Words a minute")
                .font(.system(size: 20))
                .foregroundStyle(ShareCardStyle.dim)
                .padding(.leading, 252)
        }
    }
}

// MARK: - Stack

/// Dictations piled up, the count on the top one.
struct StackShareCard: View {
    let content: ShareCardContent
    let size: ShareCardSize

    var body: some View {
        let count = content.milestoneValue
        MilestoneCardLayout(content: content, size: size) {
            amber("\(count.formatted()) dictations") + Text(",\nnot one typed.")
        } picture: { height in
            DictationPile(count: count, height: height)
        }
    }
}

private struct DictationPile: View {
    let count: Int
    let height: CGFloat

    var body: some View {
        let layers = min(9, max(3, Int(log10(Double(max(count, 1))) * 3) + 2))
        let cardHeight = min(220, height * 0.42)
        let step = (height - cardHeight) / CGFloat(layers)
        ZStack(alignment: .top) {
            ForEach(0..<layers, id: \.self) { index in
                let depth = CGFloat(layers - 1 - index)
                RoundedRectangle(cornerRadius: 30, style: .continuous)
                    .fill(index == layers - 1 ? ShareCardStyle.tile : Color(hex: "202022"))
                    .overlay(
                        RoundedRectangle(cornerRadius: 30, style: .continuous)
                            .strokeBorder(index == layers - 1 ? ShareCardStyle.amber : ShareCardStyle.line, lineWidth: 2)
                    )
                    .frame(width: 720 - depth * 26, height: cardHeight)
                    .offset(y: CGFloat(index) * step)
                    .rotationEffect(.degrees(index == layers - 1 ? 0 : Double(index % 2 == 0 ? -1.5 : 1.5)))
            }
            HStack(spacing: 28) {
                WaveGlyph()
                    .frame(width: 150, height: cardHeight * 0.45)
                VStack(alignment: .leading, spacing: 4) {
                    Text("No. \(count.formatted())")
                        .font(.system(size: 54, weight: .black))
                        .foregroundStyle(ShareCardStyle.cream)
                    Text("spoken, at the cursor")
                        .font(.system(size: 24))
                        .foregroundStyle(ShareCardStyle.grey)
                }
            }
            .frame(width: 720, height: cardHeight)
            .offset(y: CGFloat(layers - 1) * step)
        }
        .frame(height: height, alignment: .top)
    }
}

private struct WaveGlyph: View {
    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            ForEach([0.35, 0.7, 1.0, 0.55, 0.85, 0.4, 0.65], id: \.self) { level in
                Capsule()
                    .fill(ShareCardStyle.amber)
                    .frame(width: 12)
                    .frame(maxHeight: .infinity)
                    .scaleEffect(y: level)
            }
        }
    }
}

// MARK: - Apps

/// One voice reaching a tile for each app, with no app names.
struct AppsShareCard: View {
    let content: ShareCardContent
    let size: ShareCardSize

    var body: some View {
        let apps = max(content.milestoneValue, content.stats.distinctApps)
        MilestoneCardLayout(content: content, size: size) {
            Text("One voice.\n") + amber("\(apps) apps.")
        } picture: { height in
            AppConstellation(apps: apps, height: height)
        }
    }
}

private struct AppConstellation: View {
    let apps: Int
    let height: CGFloat

    var body: some View {
        let shown = min(apps, 10)
        let radius = min(390, height / 2 - 70)
        let tile = min(170, radius * 0.55)
        let center = CGPoint(x: 456, y: height / 2)
        ZStack {
            ForEach(0..<shown, id: \.self) { index in
                let point = position(index, of: shown, radius: radius, center: center)
                Path { path in
                    path.move(to: center)
                    path.addLine(to: point)
                }
                .stroke(ShareCardStyle.amber.opacity(0.35), style: StrokeStyle(lineWidth: 3, dash: [2, 12]))
                RoundedRectangle(cornerRadius: tile * 0.26, style: .continuous)
                    .fill(Color(hex: ["2C2C30", "34312C", "2A2D33"][index % 3]))
                    .overlay(
                        RoundedRectangle(cornerRadius: tile * 0.26, style: .continuous)
                            .strokeBorder(ShareCardStyle.line, lineWidth: 2)
                    )
                    .overlay {
                        // A text field with the cursor in it: no app names.
                        HStack(spacing: tile * 0.05) {
                            Capsule().fill(Color(hex: "6E6E73")).frame(width: tile * 0.34, height: tile * 0.07)
                            Capsule().fill(ShareCardStyle.amber).frame(width: tile * 0.06, height: tile * 0.34)
                        }
                    }
                    .frame(width: tile, height: tile)
                    .position(point)
            }
            if apps > shown {
                Text("+\(apps - shown)")
                    .font(.system(size: 34, weight: .heavy))
                    .foregroundStyle(ShareCardStyle.amber)
                    .position(x: center.x, y: center.y + radius + 10)
            }
            Circle()
                .fill(ShareCardStyle.amber)
                .frame(width: tile * 1.3, height: tile * 1.3)
                .overlay {
                    Image(systemName: "mic.fill")
                        .font(.system(size: tile * 0.5, weight: .semibold))
                        .foregroundStyle(ShareCardStyle.charcoal)
                }
                .shadow(color: ShareCardStyle.amber.opacity(0.4), radius: 30)
                .position(center)
        }
        .frame(width: 912, height: height)
    }

    private func position(_ index: Int, of count: Int, radius: CGFloat, center: CGPoint) -> CGPoint {
        let angle = -Double.pi / 2 + Double(index) / Double(count) * 2 * .pi
        return CGPoint(x: center.x + radius * 1.1 * CGFloat(cos(angle)), y: center.y + radius * CGFloat(sin(angle)))
    }
}

// MARK: - Stopwatch

/// The longest dictation on a stopwatch.
struct StopwatchShareCard: View {
    let content: ShareCardContent
    let size: ShareCardSize

    var body: some View {
        let seconds = content.stats.longestDictationMs / 1_000
        MilestoneCardLayout(content: content, size: size) {
            Text("I talked for ") + amber(ShareCardContent.secondsText(seconds)) + Text(" in one go.")
        } picture: { height in
            Stopwatch(seconds: seconds, diameter: min(height - 40, 620))
        }
    }
}

private struct Stopwatch: View {
    let seconds: Int
    let diameter: CGFloat

    var body: some View {
        let laps = seconds / 60
        let rest = Double(seconds % 60) / 60
        ZStack {
            Capsule()
                .fill(Color(hex: "3A3A3E"))
                .frame(width: diameter * 0.16, height: diameter * 0.1)
                .offset(y: -diameter * 0.56)
            Circle().fill(ShareCardStyle.tile)
            Circle().strokeBorder(Color(hex: "3A3A3E"), lineWidth: diameter * 0.035)
            Circle()
                .trim(from: 0, to: laps > 0 && rest == 0 ? 1 : rest)
                .stroke(ShareCardStyle.amber, style: StrokeStyle(lineWidth: diameter * 0.035, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .padding(diameter * 0.0175)
            ForEach(0..<60, id: \.self) { tick in
                Capsule()
                    .fill(tick % 5 == 0 ? ShareCardStyle.cream : Color(hex: "55555A"))
                    .frame(width: tick % 5 == 0 ? 5 : 3, height: tick % 5 == 0 ? diameter * 0.05 : diameter * 0.03)
                    .offset(y: -diameter * 0.4)
                    .rotationEffect(.degrees(Double(tick) * 6))
            }
            VStack(spacing: 6) {
                Text(String(format: "%d:%02d", seconds / 60, seconds % 60))
                    .font(.system(size: diameter * 0.24, weight: .black, design: .rounded))
                    .monospacedDigit()
                Text(laps > 0 ? "\(laps) full lap\(laps == 1 ? "" : "s") of the dial" : "seconds")
                    .font(.system(size: diameter * 0.045))
                    .foregroundStyle(ShareCardStyle.grey)
            }
        }
        .frame(width: diameter, height: diameter)
    }
}

// MARK: - Dictionary

/// A dictionary page with an entry for each word, kept private as bars.
struct DictionaryShareCard: View {
    let content: ShareCardContent
    let size: ShareCardSize

    var body: some View {
        MilestoneCardLayout(content: content, size: size) {
            Text("My Mac spells ") + amber("\(content.milestoneValue) words") + Text(" my way.")
        } picture: { height in
            DictionaryPage(count: max(content.milestoneValue, content.stats.dictionaryWords), height: height)
        }
    }
}

private struct DictionaryPage: View {
    let count: Int
    let height: CGFloat

    var body: some View {
        let entries = min(count, Int((height - 150) / 52))
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("My dictionary")
                    .font(.system(size: 40, weight: .semibold, design: .serif))
                Spacer()
                Text("\(count) entries")
                    .font(.system(size: 22, design: .serif))
                    .italic()
                    .foregroundStyle(Color(hex: "6E6E73"))
            }
            Rectangle().fill(ShareCardStyle.charcoal).frame(height: 2).padding(.vertical, 18)
            VStack(alignment: .leading, spacing: 22) {
                ForEach(0..<max(entries, 0), id: \.self) { index in
                    HStack(spacing: 14) {
                        Capsule()
                            .fill(ShareCardStyle.charcoal)
                            .frame(width: CGFloat([150, 210, 120, 180, 240, 140][index % 6]), height: 16)
                        Image(systemName: "checkmark")
                            .font(.system(size: 18, weight: .bold))
                            .foregroundStyle(Color(hex: "9A6315"))
                        Capsule()
                            .fill(Color(hex: "C7C3BC"))
                            .frame(width: CGFloat([300, 220, 360, 260, 200, 320][index % 6]), height: 12)
                    }
                    .frame(height: 30)
                }
            }
            Spacer(minLength: 0)
            Text("Words kept private. Only the count is shared.")
                .font(.system(size: 20, design: .serif))
                .italic()
                .foregroundStyle(Color(hex: "6E6E73"))
        }
        .foregroundStyle(ShareCardStyle.charcoal)
        .padding(.horizontal, 56)
        .padding(.vertical, 44)
        .frame(width: 820, height: height, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 10).fill(ShareCardStyle.cream))
        .overlay(alignment: .trailing) {
            VStack(spacing: 6) {
                ForEach(["A", "F", "K", "P", "U", "Z"], id: \.self) { letter in
                    Text(letter)
                        .font(.system(size: 20, weight: .bold, design: .serif))
                        .foregroundStyle(ShareCardStyle.charcoal)
                        .frame(width: 40, height: 52)
                        .background(RoundedRectangle(cornerRadius: 6).fill(ShareCardStyle.amber))
                }
            }
            .offset(x: 30)
        }
        .rotationEffect(.degrees(-1.2))
        .shadow(color: .black.opacity(0.4), radius: 24, y: 18)
    }
}

// MARK: - Night

/// A moon over a quiet keyboard, after midnight.
struct NightShareCard: View {
    let content: ShareCardContent
    let size: ShareCardSize

    var body: some View {
        MilestoneCardLayout(content: content, size: size, background: Color(hex: "10131C")) {
            Text("After midnight,\nmy keyboard got ") + amber("the night off.")
        } picture: { height in
            NightSky(height: height)
        }
    }
}

private struct NightSky: View {
    let height: CGFloat

    private static let stars: [(x: CGFloat, y: CGFloat, r: CGFloat)] = [
        (60, 0.12, 4), (180, 0.3, 3), (300, 0.08, 5), (420, 0.22, 3), (760, 0.1, 4),
        (860, 0.32, 3), (620, 0.05, 3), (90, 0.5, 3), (880, 0.6, 4), (520, 0.4, 2),
    ]

    var body: some View {
        ZStack {
            ForEach(Array(Self.stars.enumerated()), id: \.offset) { _, star in
                Circle()
                    .fill(ShareCardStyle.cream.opacity(0.8))
                    .frame(width: star.r * 2, height: star.r * 2)
                    .position(x: star.x, y: star.y * height)
            }
            let moon = min(230, height * 0.4)
            let clock = min(300, height * 0.4)
            let keyboard = min(190, height * 0.34)
            Circle()
                .fill(ShareCardStyle.gold)
                .frame(width: moon, height: moon)
                .mask {
                    Rectangle()
                        .overlay(Circle().frame(width: moon * 0.87, height: moon * 0.87).offset(x: moon * 0.3, y: -moon * 0.22).blendMode(.destinationOut))
                        .compositingGroup()
                }
                .shadow(color: ShareCardStyle.gold.opacity(0.45), radius: 50)
                .position(x: 680, y: moon / 2 + 10)
            ClockFace()
                .frame(width: clock, height: clock)
                .position(x: 260, y: clock / 2 + 10)
            KeyboardAsleep()
                .frame(width: 760, height: keyboard)
                .position(x: 456, y: height - keyboard / 2)
        }
        .frame(width: 912, height: height)
    }
}

private struct ClockFace: View {
    var body: some View {
        GeometryReader { proxy in
            let side = proxy.size.width
            ZStack {
                Circle().fill(Color(hex: "1B2030"))
                Circle().strokeBorder(Color(hex: "3A4058"), lineWidth: side * 0.03)
                ForEach(0..<12, id: \.self) { hour in
                    Capsule()
                        .fill(Color(hex: "8088A0"))
                        .frame(width: 4, height: side * 0.07)
                        .offset(y: -side * 0.38)
                        .rotationEffect(.degrees(Double(hour) * 30))
                }
                hand(length: 0.24, width: 10, degrees: 37)
                hand(length: 0.34, width: 6, degrees: 72)
                Circle().fill(ShareCardStyle.amber).frame(width: side * 0.07, height: side * 0.07)
            }
            .frame(width: side, height: side)
        }
    }

    private func hand(length: CGFloat, width: CGFloat, degrees: Double) -> some View {
        GeometryReader { proxy in
            let side = proxy.size.width
            Capsule()
                .fill(ShareCardStyle.amber)
                .frame(width: width, height: side * length)
                .offset(y: -side * length / 2)
                .rotationEffect(.degrees(degrees))
                .frame(width: side, height: side)
        }
    }
}

private struct KeyboardAsleep: View {
    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let key = (width - 60 - 11 * 10) / 12
            let keyHeight = min(key * 0.8, (proxy.size.height - 80) / 3)
            ZStack(alignment: .topTrailing) {
                VStack(spacing: 10) {
                    ForEach(0..<3, id: \.self) { _ in
                        HStack(spacing: 10) {
                            ForEach(0..<12, id: \.self) { _ in
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(Color(hex: "1E2232"))
                                    .frame(width: key, height: keyHeight)
                            }
                        }
                    }
                }
                .padding(30)
                .background(RoundedRectangle(cornerRadius: 26).fill(Color(hex: "161A26")))
                .overlay(RoundedRectangle(cornerRadius: 26).strokeBorder(Color(hex: "2A3044"), lineWidth: 2))
                Text("z z z")
                    .font(.system(size: 40, weight: .heavy, design: .rounded))
                    .foregroundStyle(ShareCardStyle.gold.opacity(0.8))
                    .offset(x: -20, y: -56)
            }
        }
    }
}
