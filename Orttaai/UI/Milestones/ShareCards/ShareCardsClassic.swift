// ShareCardsClassic.swift
// Orttaai

import SwiftUI

// MARK: - Receipt

/// A dictation receipt on amber: what was spoken, what it would have cost to
/// type, and a stamp for the milestone.
struct ReceiptShareCard: View {
    let content: ShareCardContent
    let size: ShareCardSize

    private var lines: [(String, String)] {
        let rows = content.receiptLines
        guard size.isSquare else { return rows }
        return rows.filter { $0.0 != "PAGES OF A BOOK" && $0.0 != "HEIGHT, STOOD UP" }
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                VStack(spacing: 12) {
                    OrttaaiBrandMark(color: ShareCardStyle.charcoal)
                        .frame(width: 60 * SignalCursorGlyph.aspectRatio, height: 60)
                    Text("ORTTAAI").font(mono(40, .heavy)).tracking(7)
                    Text("DICTATION RECEIPT").font(mono(22)).tracking(2.6)
                    Text("No. \(String(format: "%04d", content.stats.dictations)) · \(content.dateText.uppercased())")
                        .font(mono(20))
                        .foregroundStyle(Color(hex: "5A5A5E"))
                }
                dashed.padding(.top, 30).padding(.bottom, 22)
                ForEach(lines, id: \.0) { line in
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(line.0).fixedSize()
                        DottedLeader()
                        Text(line.1).fontWeight(.bold).fixedSize()
                    }
                    .font(mono(26))
                    .padding(.vertical, 12)
                }
                dashed.padding(.vertical, 22)
                HStack(alignment: .firstTextBaseline) {
                    Text("TIME BACK").font(mono(34, .heavy))
                    Spacer()
                    Text("\(content.minutesSavedOnCard.formatted()) MIN").font(mono(64, .heavy))
                }
                Text("vs typing the same words at 40 WPM")
                    .font(mono(22))
                    .foregroundStyle(Color(hex: "5A5A5E"))
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(content.badge.map { "MILESTONE: \($0.name.uppercased())" } ?? "MY STATS SO FAR")
                    .font(mono(26, .heavy))
                    .tracking(2)
                    .padding(.horizontal, 22)
                    .padding(.vertical, 12)
                    .overlay(Rectangle().strokeBorder(ShareCardStyle.charcoal, lineWidth: 3))
                    .rotationEffect(.degrees(-3))
                    .padding(.top, 28)
                if !size.isSquare {
                    barcode.padding(.top, 30)
                }
                Text("BOTH HANDS BACK. THANK YOU FOR TALKING.")
                    .font(mono(20))
                    .tracking(1.2)
                    .padding(.top, 18)
                Text("Processed on this Mac. Nothing was sent.")
                    .font(mono(18))
                    .foregroundStyle(Color(hex: "5A5A5E"))
                    .padding(.top, 6)
            }
            .foregroundStyle(ShareCardStyle.charcoal)
            .padding(.horizontal, 64)
            .padding(.top, size.isSquare ? 40 : 60)
            .padding(.bottom, 34)
            .frame(width: 780)
            .background(Color(hex: "FBF8F2"))
            .overlay(alignment: .bottom) {
                ZigZag().fill(Color(hex: "FBF8F2")).frame(height: 20).offset(y: 20)
            }
            .rotationEffect(.degrees(-1.5))
            .shadow(color: ShareCardStyle.charcoal.opacity(0.35), radius: 30, y: 26)

            Spacer(minLength: 20)
            HStack(spacing: 14) {
                OrttaaiBrandMark(color: ShareCardStyle.charcoal)
                    .frame(width: 34 * SignalCursorGlyph.aspectRatio, height: 34)
                Text("Orttaai").font(.system(size: 30, weight: .bold))
                Text("· \(ShareCardStyle.tagline)").font(.system(size: 24, weight: .medium)).opacity(0.75)
            }
            .foregroundStyle(ShareCardStyle.charcoal)
        }
        .padding(.top, size.isSquare ? 48 : 84)
        .padding(.bottom, size.isSquare ? 44 : 64)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(ShareCardStyle.amber)
    }

    private func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }

    private var dashed: some View {
        Line()
            .stroke(ShareCardStyle.charcoal, style: StrokeStyle(lineWidth: 3, dash: [10, 8]))
            .frame(height: 3)
    }

    private var barcode: some View {
        HStack(alignment: .bottom, spacing: 5) {
            ForEach(0..<48, id: \.self) { index in
                RoundedRectangle(cornerRadius: 2)
                    .fill(ShareCardStyle.charcoal)
                    .frame(width: [3, 6, 3, 9, 3, 6][index % 6], height: 40 + 44 * abs(sin(Double(index) * 0.9)))
            }
        }
        .frame(height: 84, alignment: .bottom)
    }
}

private struct DottedLeader: View {
    var body: some View {
        Line()
            .stroke(Color(hex: "9A9A9E"), style: StrokeStyle(lineWidth: 3, lineCap: .round, dash: [0.1, 9]))
            .frame(height: 3)
            .offset(y: -6)
    }
}

private struct Line: Shape {
    func path(in rect: CGRect) -> Path {
        Path { path in
            path.move(to: CGPoint(x: rect.minX, y: rect.midY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        }
    }
}

private struct ZigZag: Shape {
    func path(in rect: CGRect) -> Path {
        Path { path in
            path.move(to: CGPoint(x: rect.minX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
            var x = rect.maxX
            var down = true
            while x > rect.minX {
                x -= 13
                path.addLine(to: CGPoint(x: max(rect.minX, x), y: down ? rect.maxY : rect.minY + 2))
                down.toggle()
            }
            path.closeSubpath()
        }
    }
}

// MARK: - Signal

/// The big number, the brand mark large and faint behind it, three stats.
struct SignalShareCard: View {
    let content: ShareCardContent
    let size: ShareCardSize

    var body: some View {
        let hero = content.hero
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                ShareCardBrand(markHeight: 54)
                Spacer()
                Text("MILESTONE")
                    .font(.system(size: 22, weight: .bold))
                    .tracking(2.2)
                    .foregroundStyle(ShareCardStyle.amber)
                    .padding(.horizontal, 26)
                    .frame(height: 52)
                    .overlay(Capsule().strokeBorder(ShareCardStyle.amber, lineWidth: 2))
            }
            Spacer()
            Text(hero.value)
                .font(.system(size: size.isSquare ? 200 : 260, weight: .black))
                .tracking(-10)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .monospacedDigit()
            Text(hero.label)
                .font(.system(size: 64, weight: .bold))
                .padding(.top, 14)
            Text(content.supportLine)
                .font(.system(size: 32))
                .fixedSize(horizontal: false, vertical: true)
                .foregroundStyle(ShareCardStyle.grey)
                .padding(.top, 14)

            HStack(alignment: .top) {
                ForEach(Array(content.supportingStats.enumerated()), id: \.offset) { index, stat in
                    signalStat(stat.value, stat.label, accent: index == 2)
                }
            }
            .padding(.top, 36)
            .overlay(alignment: .top) { Rectangle().fill(ShareCardStyle.line).frame(height: 2) }
            .padding(.top, size.isSquare ? 40 : 72)

            ShareCardFooter()
                .padding(.top, size.isSquare ? 40 : 64)
        }
        .padding(88)
        .foregroundStyle(ShareCardStyle.cream)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(alignment: .bottomTrailing) {
            OrttaaiBrandMark(color: ShareCardStyle.amber)
                .frame(width: 560, height: 560 / SignalCursorGlyph.aspectRatio)
                .opacity(0.12)
                .offset(x: 70, y: size.isSquare ? -300 : -470)
        }
        .background(ShareCardStyle.charcoal)
    }

    private func signalStat(_ value: String, _ label: String, accent: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(value)
                .font(.system(size: 56, weight: .heavy))
                .foregroundStyle(accent ? ShareCardStyle.amber : ShareCardStyle.cream)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(label)
                .font(.system(size: 24))
                .foregroundStyle(ShareCardStyle.grey)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Editorial

/// Cream, serif, one sentence.
struct EditorialShareCard: View {
    let content: ShareCardContent
    let size: ShareCardSize

    var body: some View {
        let headline = content.headline
        let stats = content.supportingStats
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(content.eyebrow)
                Spacer()
                Text(content.dateText.uppercased()).foregroundStyle(Color(hex: "6E6E73"))
            }
            .font(.system(size: 22, weight: .semibold))
            .tracking(3)
            Rectangle().fill(ShareCardStyle.charcoal).frame(height: 3).padding(.top, 22)

            (Text(headline.lead) + Text(headline.emphasis).italic().foregroundColor(Color(hex: "9A6315")) + Text(headline.tail))
                .font(.system(size: size.isSquare ? 92 : 112, design: .serif))
                .lineSpacing(-6)
                .padding(.top, size.isSquare ? 48 : 88)

            HStack(spacing: 16) {
                Capsule().fill(ShareCardStyle.amber).frame(width: 72, height: 6)
                Text(content.supportLine)
                    .font(.system(size: 30))
                    .foregroundStyle(Color(hex: "48484A"))
            }
            .padding(.top, 48)

            Spacer()

            HStack(spacing: 0) {
                ForEach(Array(stats.enumerated()), id: \.offset) { index, stat in
                    if index > 0 {
                        Rectangle().fill(Color(hex: "C7C3BC")).frame(width: 1)
                    }
                    editorialStat(stat.value, stat.label).padding(.leading, index > 0 ? 24 : 0)
                }
            }
            .frame(height: 130)
            .overlay(alignment: .top) { Rectangle().fill(ShareCardStyle.charcoal).frame(height: 2) }

            HStack {
                ShareCardBrand(color: ShareCardStyle.charcoal, textColor: ShareCardStyle.charcoal, markHeight: 44)
                Spacer()
                Text(ShareCardStyle.tagline)
                    .font(.system(size: 22))
                    .foregroundStyle(Color(hex: "5A5A5E"))
            }
            .padding(.top, 56)
        }
        .padding(96)
        .foregroundStyle(ShareCardStyle.charcoal)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(ShareCardStyle.cream)
    }

    private func editorialStat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(value)
                .font(.system(size: 66, design: .serif))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(label)
                .font(.system(size: 22))
                .foregroundStyle(Color(hex: "5A5A5E"))
        }
        .padding(.top, 28)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Medal

/// The badge large, with rays and rings around it.
struct MedalShareCard: View {
    let content: ShareCardContent
    let size: ShareCardSize
    let badge: MilestoneBadge

    var body: some View {
        let tier = badge.tier.color
        let badgeSize: CGFloat = size.isSquare ? 340 : 440
        VStack(spacing: 0) {
            ShareCardBrand(markHeight: 37)
            Spacer(minLength: 20)
            ZStack {
                ForEach([300.0, 380, 460, 540], id: \.self) { radius in
                    Circle()
                        .stroke(Color(hex: "2E2E31"), lineWidth: 2)
                        .frame(width: radius * 2 * badgeSize / 440, height: radius * 2 * badgeSize / 440)
                }
                ForEach(0..<24, id: \.self) { index in
                    let long = index % 2 == 0
                    Capsule()
                        .fill(tier.opacity(0.5))
                        .frame(width: long ? 5 : 3, height: (long ? 44 : 22) * badgeSize / 440)
                        .offset(y: -(long ? 262 : 252) * badgeSize / 440)
                        .rotationEffect(.degrees(Double(index) * 15))
                }
                MilestoneBadgeView(badge: badge, state: .unlocked(Date()), size: badgeSize)
            }
            .frame(width: 1080, height: badgeSize + 60)
            Spacer(minLength: 20)
            Text("BADGE UNLOCKED")
                .font(.system(size: 26, weight: .bold))
                .tracking(5)
                .foregroundStyle(tier)
            Text(badge.name)
                .font(.system(size: 112, weight: .black))
                .tracking(-3)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .padding(.top, 16)
            Text("\(badge.rule) · \(content.dateText)")
                .font(.system(size: 36))
                .foregroundStyle(Color(hex: "C7C7CC"))
                .padding(.top, 18)
            Spacer(minLength: 20)
            Text("\(ShareCardStyle.tagline) Your voice never leaves your Mac.")
                .font(.system(size: 24))
                .foregroundStyle(ShareCardStyle.dim)
        }
        .padding(88)
        .foregroundStyle(ShareCardStyle.cream)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(ShareCardStyle.charcoal)
        .clipped()
    }
}
