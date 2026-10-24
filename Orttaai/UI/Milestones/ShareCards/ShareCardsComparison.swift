// ShareCardsComparison.swift
// Orttaai

import SwiftUI

// MARK: - Mountain

/// "Stood on end, my words are 24 metres tall": a climb from the person's
/// height past landmarks to Kilimanjaro and Everest, on a log scale.
struct MountainShareCard: View {
    let content: ShareCardContent
    let size: ShareCardSize

    private var height: (value: String, unit: String) {
        let metres = MilestoneComparisons.heightMetres(words: content.words)
        if metres >= 1_000 { return (String(format: "%.1f", metres / 1_000), "kilometres") }
        return ("\(Int(metres.rounded()))", "metres")
    }

    private var closingLine: String {
        if let next = MilestoneComparisons.nextLandmark(after: content.words) {
            if next.name == "Kilimanjaro" || next.name == "Everest" {
                return "tall. \(next.name), here I come."
            }
            return "tall. \(next.name) next."
        }
        return "tall. Higher than Everest."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                ShareCardBrand(markHeight: 40)
                Spacer()
                Text(content.eyebrow)
                    .font(.system(size: 22, weight: .bold))
                    .tracking(3)
                    .foregroundStyle(ShareCardStyle.grey)
            }
            .padding(.horizontal, 84)

            VStack(alignment: .leading, spacing: 8) {
                Text("Stood on end, my words are")
                    .font(.system(size: 52, weight: .bold))
                    .foregroundStyle(Color(hex: "C7C7CC"))
                (Text(height.value).foregroundColor(ShareCardStyle.amber) + Text(" \(height.unit)"))
                    .font(.system(size: size.isSquare ? 150 : 190, weight: .black))
                    .tracking(-6)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Text(closingLine)
                    .font(.system(size: 48, weight: .bold))
            }
            .padding(.horizontal, 84)
            .padding(.top, size.isSquare ? 36 : 64)

            Spacer(minLength: 20)

            MountainChart(words: content.words, chartHeight: chartHeight)
                .frame(width: 1080, height: chartHeight)

            HStack(alignment: .bottom) {
                Text("One printed word is about 1.2 cm. Heights on a log scale.")
                    .font(.system(size: 20))
                    .foregroundStyle(ShareCardStyle.dim)
                Spacer()
                Text(ShareCardStyle.tagline)
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(Color(hex: "C7C7CC"))
            }
            .padding(.horizontal, 84)
            .padding(.top, 28)
        }
        .padding(.vertical, 80)
        .foregroundStyle(ShareCardStyle.cream)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(ShareCardStyle.night)
    }

    private var chartHeight: CGFloat {
        switch size {
        case .portrait: return 600
        case .square: return 420
        case .story: return 980
        }
    }
}

private struct MountainChart: View {
    let words: Int
    let chartHeight: CGFloat

    private var ground: CGFloat { chartHeight - 40 }
    private let top: CGFloat = 70

    /// 10 m at the ground line, 10 km at the top.
    private func y(_ metres: Double) -> CGFloat {
        let decades = (log10(min(max(metres, 10), 10_000)) - 1) / 3
        return ground - CGFloat(decades) * (ground - top)
    }

    private func y(_ name: String) -> CGFloat {
        y(MilestoneComparisons.landmarks.first { $0.name == name }?.metres ?? 10)
    }

    var body: some View {
        let g = ground
        let me = y(MilestoneComparisons.heightMetres(words: words))
        let everest = y("Everest"), kili = y("Kilimanjaro"), burj = y("Burj Khalifa")
        let eiffel = y("Eiffel Tower"), liberty = y("Statue of Liberty")
        ZStack(alignment: .topLeading) {
            polygon([(560, g), (700, everest + (g - everest) * 0.55), (750, everest + (g - everest) * 0.62), (860, everest), (930, everest + (g - everest) * 0.35), (1000, everest + (g - everest) * 0.24), (1080, everest + (g - everest) * 0.33), (1080, g)])
                .fill(Color(hex: "202024"))
            polygon([(842, everest + 16), (860, everest), (880, everest + 50), (866, everest + 44), (856, everest + 60), (848, everest + 40)])
                .fill(ShareCardStyle.cream.opacity(0.8))
            polygon([(500, g), (630, kili + (g - kili) * 0.17), (668, kili + 8), (738, kili), (782, kili + 18), (840, kili + (g - kili) * 0.3), (960, g)])
                .fill(Color(hex: "2B2B30"))
            polygon([(668, kili + 8), (738, kili), (782, kili + 18), (766, kili + 46), (744, kili + 26), (722, kili + 50), (698, kili + 30), (660, kili + 46)])
                .fill(ShareCardStyle.cream.opacity(0.92))
            polygon([(472, g), (478, burj + (g - burj) * 0.36), (482, burj), (486, burj + (g - burj) * 0.36), (492, g)])
                .fill(Color(hex: "5A5A60"))
            polygon([(340, g), (352, eiffel + (g - eiffel) * 0.48), (358, eiffel + (g - eiffel) * 0.16), (360, eiffel), (362, eiffel + (g - eiffel) * 0.16), (368, eiffel + (g - eiffel) * 0.48), (380, g), (370, g), (360, g - 26), (350, g)])
                .fill(Color(hex: "5A5A60"))
            let pedestal = liberty + (g - liberty) * 0.5
            polygon([(214, g), (214, pedestal), (238, pedestal), (238, g)])
                .fill(Color(hex: "5A5A60"))
            polygon([(220, pedestal), (222, liberty + (g - liberty) * 0.2), (226, liberty + (g - liberty) * 0.1), (228, liberty), (232, liberty + (g - liberty) * 0.1), (232, pedestal)])
                .fill(Color(hex: "5A5A60"))

            Path { path in
                path.move(to: CGPoint(x: 140, y: me))
                path.addLine(to: CGPoint(x: 1040, y: me))
            }
            .stroke(ShareCardStyle.amber.opacity(0.55), style: StrokeStyle(lineWidth: 3, lineCap: .round, dash: [2, 12]))

            RoundedRectangle(cornerRadius: 3)
                .fill(ShareCardStyle.amber)
                .frame(width: 44, height: max(18, g - me))
                .offset(x: 92, y: min(me, g - 18))

            Path { path in
                path.move(to: CGPoint(x: 40, y: g))
                path.addLine(to: CGPoint(x: 1040, y: g))
            }
            .stroke(ShareCardStyle.line, lineWidth: 3)

            label("ME", MilestoneComparisons.heightText(words: words), x: 84, y: min(me, g - 18) - 64, highlight: true)
            label("Statue of Liberty", "93 m · \(words(for: "Statue of Liberty"))", x: 160, y: liberty - 70)
            label("Eiffel Tower", "330 m · \(words(for: "Eiffel Tower"))", x: 300, y: eiffel - 70)
            label("Burj Khalifa", "828 m · \(words(for: "Burj Khalifa"))", x: 418, y: burj - 70)
            label("Kilimanjaro", "5,895 m · \(words(for: "Kilimanjaro"))", x: 520, y: kili - 74)
            label("Everest", "\(words(for: "Everest")) words", x: 900, y: everest - 62)
        }
        .frame(width: 1080, height: chartHeight, alignment: .topLeading)
    }

    private func words(for name: String) -> String {
        (MilestoneComparisons.landmarks.first { $0.name == name }?.wordsToReach ?? 0).formatted()
    }

    private func polygon(_ points: [(CGFloat, CGFloat)]) -> Path {
        Path { path in
            guard let first = points.first else { return }
            path.move(to: CGPoint(x: first.0, y: first.1))
            for point in points.dropFirst() { path.addLine(to: CGPoint(x: point.0, y: point.1)) }
            path.closeSubpath()
        }
    }

    private func label(_ title: String, _ detail: String, x: CGFloat, y: CGFloat, highlight: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: highlight ? 26 : 20, weight: highlight ? .heavy : .bold))
                .foregroundStyle(highlight ? ShareCardStyle.amber : ShareCardStyle.cream)
            Text(detail)
                .font(.system(size: 18))
                .foregroundStyle(ShareCardStyle.grey)
        }
        .fixedSize()
        .offset(x: x, y: max(0, y))
    }
}

// MARK: - Books

/// Books for the words dictated. Below one novel, the person's pages beside
/// The Great Gatsby filling up; past it, a pile of novels, then War and Peace.
struct BooksShareCard: View {
    let content: ShareCardContent
    let size: ShareCardSize

    private static let gatsby = 47_000
    private static let novel = 90_000
    private static let warAndPeace = 587_000

    private var bookCount: Int {
        min(8, max(1, Int((Double(content.words) / Double(Self.novel) * 1.5).rounded(.up))))
    }

    private var headline: Text {
        let words = content.words
        let accent = Color(hex: "9A6315")
        if words >= Self.warAndPeace {
            return Text("I've out-written ") + Text("War and Peace.").italic().foregroundColor(accent)
        }
        if words >= Self.novel * 2 {
            let novels = words / Self.novel
            return Text("I've dictated ") + Text("\(novels) novels.").italic().foregroundColor(accent)
        }
        if words >= Self.gatsby {
            return Text("I've dictated a ") + Text("whole novel.").italic().foregroundColor(accent)
        }
        let pages = MilestoneComparisons.pages(words: words)
        return Text("I've dictated \(pages.formatted()) ") + Text(pages == 1 ? "page." : "pages.").italic().foregroundColor(accent)
    }

    private var subline: String {
        let words = content.words
        let count = words.formatted()
        if words >= Self.warAndPeace {
            return "\(count) words, more than War and Peace's 587,000, and I didn't type a page of it."
        }
        if words >= Self.novel * 2 {
            return "\(count) words: \(words / Self.novel) average-length novels, and I didn't type a page of them."
        }
        if words >= Self.gatsby {
            return "\(count) words. That's longer than The Great Gatsby, and I didn't type a page of it."
        }
        let percent = max(1, Int((Double(words) / Double(Self.gatsby) * 100).rounded()))
        return "\(count) words, \(percent)% of the way to The Great Gatsby, and I didn't type a page of it."
    }

    /// The book the middle figure compares against.
    private var yardstick: (words: String, label: String) {
        if content.words >= Self.novel * 2 { return ("587,000", "words in War and Peace") }
        if content.words >= Self.gatsby { return ("90,000", "words in an average novel") }
        return ("47,000", "words in The Great Gatsby")
    }

    var body: some View {
        let pages = MilestoneComparisons.pages(words: content.words)
        let artHeight: CGFloat = size == .story ? 620 : (size.isSquare ? 250 : 390)
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                ShareCardBrand(color: ShareCardStyle.charcoal, textColor: ShareCardStyle.charcoal, markHeight: 40)
                Spacer()
                Text(content.eyebrow)
                    .font(.system(size: 22, weight: .bold))
                    .tracking(3)
                    .foregroundStyle(Color(hex: "6B5A43"))
            }

            headline
                .font(.system(size: size.isSquare ? 96 : 116, design: .serif))
                .lineSpacing(-8)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, size.isSquare ? 36 : 52)

            Text(subline)
                .font(.system(size: 34))
                .foregroundStyle(Color(hex: "48484A"))
                .lineSpacing(6)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 20)

            Spacer(minLength: 16)
            Group {
                if content.words < Self.gatsby {
                    PagesBesideBook(pages: pages, fraction: Double(content.words) / Double(Self.gatsby))
                } else {
                    BookPile(count: bookCount)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: artHeight)
            Spacer(minLength: 16)

            HStack(spacing: 0) {
                bookStat(pages.formatted(), "pages, at 250 words a page")
                Rectangle().fill(Color(hex: "C9BFAE")).frame(width: 1)
                bookStat(yardstick.words, yardstick.label).padding(.leading, 20)
                Rectangle().fill(Color(hex: "C9BFAE")).frame(width: 1)
                bookStat(MilestoneComparisons.durationText(minutes: MilestoneComparisons.typingMinutes(words: content.words)), "to type it at 40 words a minute").padding(.leading, 20)
            }
            .frame(height: 120)
            .padding(.top, 26)
            .overlay(alignment: .top) { Rectangle().fill(ShareCardStyle.charcoal).frame(height: 2) }

            ShareCardFooter(color: Color(hex: "5A5045"), taglineColor: ShareCardStyle.charcoal)
                .padding(.top, 40)
        }
        .padding(84)
        .foregroundStyle(ShareCardStyle.charcoal)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(ShareCardStyle.paper)
    }

    private func bookStat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(value)
                .font(.system(size: 60, design: .serif))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(label)
                .font(.system(size: 21))
                .foregroundStyle(Color(hex: "5A5045"))
        }
        .padding(.top, 24)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A small stack of the person's pages beside The Great Gatsby standing
/// upright, filled to how far they've come.
private struct PagesBesideBook: View {
    let pages: Int
    let fraction: Double

    var body: some View {
        GeometryReader { geometry in
            let height = geometry.size.height
            let bookHeight = height - 70
            HStack(alignment: .bottom, spacing: 120) {
                VStack(spacing: 18) {
                    VStack(spacing: 3) {
                        ForEach(0..<min(max(pages, 1), 24), id: \.self) { index in
                            RoundedRectangle(cornerRadius: 2)
                                .fill(Color(hex: "FBF8F2"))
                                .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(ShareCardStyle.charcoal.opacity(0.55), lineWidth: 1.5))
                                .frame(width: 300, height: 7)
                                .offset(x: CGFloat([0, 6, -4, 3, -7, 5, -2][index % 7]))
                        }
                    }
                    Text("my \(pages.formatted()) page\(pages == 1 ? "" : "s")")
                        .font(.system(size: 24, weight: .semibold))
                }
                VStack(spacing: 18) {
                    ZStack(alignment: .bottom) {
                        RoundedRectangle(cornerRadius: 12)
                            .fill(ShareCardStyle.amber)
                            .frame(height: max(10, bookHeight * min(1, fraction)))
                        RoundedRectangle(cornerRadius: 12)
                            .strokeBorder(ShareCardStyle.charcoal, style: StrokeStyle(lineWidth: 3, dash: [10, 8]))
                    }
                    .frame(width: 150, height: bookHeight)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    Text("The Great Gatsby · \(max(1, Int((fraction * 100).rounded())))%")
                        .font(.system(size: 24, weight: .semibold))
                }
            }
            .frame(width: geometry.size.width, height: height, alignment: .bottom)
        }
    }
}

private struct BookPile: View {
    let count: Int

    private static let specs: [(width: CGFloat, height: CGFloat, fill: String, ink: String, inset: CGFloat)] = [
        (640, 70, "1C1C1E", "F5F3F0", -20), (600, 58, "D4952A", "1C1C1E", 10), (660, 64, "3A3A3C", "F5F3F0", -40),
        (580, 52, "FBF8F2", "1C1C1E", 30), (620, 66, "C9895A", "1C1C1E", -10), (560, 54, "2C2C2E", "F5F3F0", 40),
        (600, 60, "E2B04A", "1C1C1E", 0), (620, 56, "8E8E93", "1C1C1E", -30),
    ]

    var body: some View {
        GeometryReader { geometry in
            let books = Array(Self.specs.prefix(count))
            let total = books.reduce(0) { $0 + $1.height + 2 }
            let scale = min(1, geometry.size.height / max(total + 20, 1))
            VStack(spacing: 2 * scale) {
                Spacer(minLength: 0)
                ForEach(Array(books.enumerated().reversed()), id: \.offset) { index, spec in
                    book(spec, scale: scale)
                        .overlay(alignment: .topLeading) {
                            if index == books.count - 1 {
                                Path { path in
                                    path.move(to: .zero)
                                    path.addLine(to: CGPoint(x: 0, y: 50))
                                    path.addLine(to: CGPoint(x: 14, y: 38))
                                    path.addLine(to: CGPoint(x: 28, y: 50))
                                    path.addLine(to: CGPoint(x: 28, y: 0))
                                    path.closeSubpath()
                                }
                                .fill(ShareCardStyle.amber)
                                .frame(width: 28, height: 50)
                                .offset(x: spec.width * scale * 0.68, y: 6)
                            }
                        }
                        .offset(x: spec.inset * scale)
                }
                Ellipse()
                    .fill(Color.black.opacity(0.12))
                    .frame(width: 720 * scale, height: 14)
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func book(_ spec: (width: CGFloat, height: CGFloat, fill: String, ink: String, inset: CGFloat), scale: CGFloat) -> some View {
        let width = spec.width * scale, height = spec.height * scale
        return ZStack {
            RoundedRectangle(cornerRadius: 9)
                .fill(Color(hex: spec.fill))
                .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(spec.fill == "FBF8F2" ? ShareCardStyle.charcoal : Color.clear, lineWidth: 2))
            HStack {
                Rectangle().fill(Color(hex: spec.ink).opacity(0.28)).frame(width: 6)
                    .padding(.leading, 36 * scale)
                Spacer()
                Capsule().fill(Color(hex: spec.ink).opacity(0.4)).frame(width: 180 * scale, height: 9)
                Spacer()
                Rectangle().fill(Color(hex: spec.ink).opacity(0.28)).frame(width: 6)
                RoundedRectangle(cornerRadius: 3).fill(Color(hex: "FBF8F2"))
                    .frame(width: 12)
                    .padding(.vertical, 6)
                    .padding(.trailing, 6)
            }
        }
        .frame(width: width, height: height)
    }
}

// MARK: - Speedometer

/// The person's pace on a dial from handwriting to an auctioneer.
struct SpeedShareCard: View {
    let content: ShareCardContent
    let size: ShareCardSize

    var body: some View {
        let pace = content.pace
        let typing = MilestoneComparisons.multiple(of: pace, over: MilestoneComparisons.typingWPM)
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                ShareCardBrand(markHeight: 40)
                Spacer()
                Text(content.badge?.name.uppercased() ?? "MY PACE")
                    .font(.system(size: 22, weight: .bold))
                    .tracking(3)
                    .foregroundStyle(ShareCardStyle.amber)
            }
            .padding(.horizontal, 84)

            Group {
                if Double(pace) > MilestoneComparisons.typingWPM {
                    Text("My voice is ") + Text("\(typing)×").foregroundColor(ShareCardStyle.amber) + Text(" faster than my keyboard.")
                } else {
                    Text("I dictate at ") + Text("\(pace)").foregroundColor(ShareCardStyle.amber) + Text(" words a minute.")
                }
            }
            .font(.system(size: size.isSquare ? 52 : 58, weight: .heavy))
            .lineSpacing(4)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 84)
            .padding(.top, size.isSquare ? 40 : 68)

            Spacer(minLength: 10)
            SpeedDial(pace: pace)
                .frame(width: 1080, height: 640)
                .scaleEffect(size.isSquare ? 0.78 : 1)
                .frame(height: size.isSquare ? 500 : 640)
            Spacer(minLength: 10)

            HStack(spacing: 24) {
                speedTile("\(MilestoneComparisons.multiple(of: pace, over: MilestoneComparisons.handwritingWPM))×", "faster than writing by hand")
                speedTile(MilestoneComparisons.keyPressesText(words: content.words), "key presses I didn't make")
            }
            .padding(.horizontal, 84)

            ShareCardFooter()
                .padding(.horizontal, 84)
                .padding(.top, 40)
        }
        .padding(.vertical, 80)
        .foregroundStyle(ShareCardStyle.cream)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(ShareCardStyle.charcoal)
    }

    private func speedTile(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(value)
                .font(.system(size: 56, weight: .heavy))
                .foregroundStyle(ShareCardStyle.amber)
            Text(label)
                .font(.system(size: 24))
                .foregroundStyle(Color(hex: "C7C7CC"))
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 22).fill(ShareCardStyle.tile))
        .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(ShareCardStyle.line, lineWidth: 1))
    }
}

private struct SpeedDial: View {
    let pace: Int

    private let center = CGPoint(x: 540, y: 560)
    private let radius: CGFloat = 400
    private var maxWPM: Double { max(250, Double(pace) + 20) }

    private func point(_ wpm: Double, _ r: CGFloat) -> CGPoint {
        let angle = Double.pi * (1 - min(wpm, maxWPM) / maxWPM)
        return CGPoint(x: center.x + r * CGFloat(cos(angle)), y: center.y - r * CGFloat(sin(angle)))
    }

    private var arc: Path {
        Path { path in
            path.addArc(center: center, radius: radius, startAngle: .degrees(180), endAngle: .degrees(360), clockwise: false)
        }
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            arc.stroke(Color(hex: "2C2C30"), style: StrokeStyle(lineWidth: 44, lineCap: .round))
            arc.trim(from: 0, to: min(1, Double(pace) / maxWPM))
                .stroke(ShareCardStyle.amber, style: StrokeStyle(lineWidth: 44, lineCap: .round))
            Path { path in
                for wpm in stride(from: 0.0, through: 250, by: 25) {
                    let major = Int(wpm) % 50 == 0
                    path.move(to: point(wpm, major ? 352 : 360))
                    path.addLine(to: point(wpm, 372))
                }
            }
            .stroke(Color(hex: "55555A"), style: StrokeStyle(lineWidth: 3, lineCap: .round))
            ForEach([0, 50, 100, 150, 200, 250], id: \.self) { wpm in
                Text("\(wpm)")
                    .font(.system(size: 20))
                    .foregroundStyle(ShareCardStyle.dim)
                    .position(point(Double(wpm), 324))
            }
            marker("Handwriting", MilestoneComparisons.handwritingWPM, labelAt: CGPoint(x: 150, y: 618))
            marker("Typing", MilestoneComparisons.typingWPM, labelAt: CGPoint(x: 112, y: 316))
            marker("Conversation", MilestoneComparisons.conversationWPM, labelAt: CGPoint(x: 760, y: 128))
            marker("Auctioneer", MilestoneComparisons.auctioneerWPM, labelAt: CGPoint(x: 940, y: 618))
            Path { path in
                path.move(to: point(Double(pace), 450))
                path.addLine(to: point(Double(pace) - 3, 418))
                path.addLine(to: point(Double(pace) + 3, 418))
                path.closeSubpath()
            }
            .fill(ShareCardStyle.amber)
            VStack(spacing: 4) {
                Text("\(pace)")
                    .font(.system(size: 210, weight: .black))
                    .tracking(-8)
                Text("words a minute, out loud")
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(Color(hex: "C7C7CC"))
            }
            .position(x: 540, y: 430)
        }
        .frame(width: 1080, height: 640, alignment: .topLeading)
    }

    private func marker(_ name: String, _ wpm: Double, labelAt: CGPoint) -> some View {
        ZStack(alignment: .topLeading) {
            Circle()
                .fill(ShareCardStyle.cream)
                .overlay(Circle().strokeBorder(ShareCardStyle.charcoal, lineWidth: 4))
                .frame(width: 22, height: 22)
                .position(point(wpm, radius))
            VStack(spacing: 2) {
                Text(name).font(.system(size: 24, weight: .bold))
                Text("\(Int(wpm)) WPM").font(.system(size: 20)).foregroundStyle(ShareCardStyle.grey)
            }
            .fixedSize()
            .position(labelAt)
        }
    }
}

// MARK: - Hands Free

/// Typing time handed back, with both hands raised.
struct HandsShareCard: View {
    let content: ShareCardContent
    let size: ShareCardSize

    var body: some View {
        let saved = content.stats.minutesSaved
        let typing = MilestoneComparisons.typingMinutes(words: content.words)
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                ShareCardBrand(markHeight: 40)
                Spacer()
                Text("HANDS FREE")
                    .font(.system(size: 22, weight: .bold))
                    .tracking(3)
                    .foregroundStyle(ShareCardStyle.amber)
            }

            Group {
                if saved > 0 {
                    Text(MilestoneComparisons.durationText(minutes: saved)).foregroundColor(ShareCardStyle.amber) + Text("\nwith both hands free.")
                } else {
                    Text("Both hands free\n") + Text("while I write.").foregroundColor(ShareCardStyle.amber)
                }
            }
            .font(.system(size: size.isSquare ? 80 : 92, weight: .black))
            .tracking(-2)
            .padding(.top, size.isSquare ? 36 : 64)

            Spacer(minLength: 10)
            RaisedHands()
                .frame(width: 912, height: 430)
                .scaleEffect(size.isSquare ? 0.62 : (size == .story ? 1.2 : 1))
                .frame(maxWidth: .infinity)
                .frame(height: size.isSquare ? 270 : (size == .story ? 560 : 430))
            Spacer(minLength: 10)

            HStack(spacing: 18) {
                handsTile(MilestoneComparisons.durationText(minutes: typing), "to type \(content.words.formatted()) words", accent: false)
                handsTile(MilestoneComparisons.durationText(minutes: content.stats.speakingMinutes), "to say them instead", accent: false)
                handsTile(MilestoneComparisons.timeBackEquivalent(minutes: saved).replacingOccurrences(of: "a ", with: "1 "), "given back to me", accent: true)
            }

            HStack(alignment: .bottom) {
                Text("Giving you back\nboth hands.")
                    .font(.system(size: 44, weight: .heavy))
                Spacer()
                Text("\(ShareCardStyle.product)\nTyping time at 40 words a minute")
                    .font(.system(size: 22))
                    .foregroundStyle(ShareCardStyle.dim)
                    .multilineTextAlignment(.trailing)
            }
            .padding(.top, 40)
        }
        .padding(84)
        .foregroundStyle(ShareCardStyle.cream)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color(hex: "18181A"))
    }

    private func handsTile(_ value: String, _ label: String, accent: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(value)
                .font(.system(size: 44, weight: .heavy))
                .foregroundStyle(accent ? ShareCardStyle.amber : ShareCardStyle.cream)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
            Text(label)
                .font(.system(size: 21))
                .foregroundStyle(Color(hex: "C7C7CC"))
                .lineLimit(2)
        }
        .padding(24)
        .frame(maxWidth: .infinity, minHeight: 150, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 22).fill(ShareCardStyle.tile))
        .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(accent ? ShareCardStyle.amber : ShareCardStyle.line, lineWidth: 1))
    }
}

private struct RaisedHands: View {
    var body: some View {
        ZStack {
            hand.rotationEffect(.degrees(-10)).offset(x: -150)
            hand.scaleEffect(x: -1, y: 1).rotationEffect(.degrees(10)).offset(x: 150)
            HStack(alignment: .bottom, spacing: 6) {
                Capsule().fill(ShareCardStyle.amber).frame(width: 12, height: 26)
                Capsule().fill(ShareCardStyle.amber).frame(width: 12, height: 38)
                Capsule().fill(ShareCardStyle.amber).frame(width: 12, height: 52)
                Capsule().fill(ShareCardStyle.amber).frame(width: 5, height: 60)
            }
            .offset(y: -10)
            ForEach([-1.0, 1.0], id: \.self) { side in
                ZStack {
                    Arc(radius: 60).stroke(ShareCardStyle.line, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    Arc(radius: 100).stroke(ShareCardStyle.line, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                }
                .frame(width: 220, height: 220)
                .scaleEffect(x: side, y: 1)
                .offset(x: side * 330, y: -80)
            }
        }
        .frame(width: 912, height: 430)
    }

    private var hand: some View {
        let stroke = ShareCardStyle.amber, fill = Color(hex: "2C2C30")
        func part(_ w: CGFloat, _ h: CGFloat, _ x: CGFloat, _ y: CGFloat, _ r: CGFloat, angle: Double = 0) -> some View {
            RoundedRectangle(cornerRadius: r)
                .fill(fill)
                .overlay(RoundedRectangle(cornerRadius: r).strokeBorder(stroke, lineWidth: 5))
                .frame(width: w, height: h)
                .rotationEffect(.degrees(angle))
                .offset(x: x, y: y)
        }
        return ZStack {
            part(34, 120, 70, -10, 17, angle: 38)
            part(32, 150, -60, -110, 16)
            part(34, 190, -23, -130, 17)
            part(34, 196, 15, -130, 17)
            part(32, 168, 52, -112, 16)
            part(148, 150, -4, -20, 56)
            part(108, 40, -4, 80, 12)
        }
        .frame(width: 260, height: 400)
        .offset(y: 30)
    }
}

/// A short arc on the outer side of a raised hand, like a wave.
private struct Arc: Shape {
    let radius: CGFloat

    func path(in rect: CGRect) -> Path {
        Path { path in
            path.addArc(center: CGPoint(x: rect.midX + radius, y: rect.midY), radius: radius, startAngle: .degrees(160), endAngle: .degrees(210), clockwise: false)
        }
    }
}
