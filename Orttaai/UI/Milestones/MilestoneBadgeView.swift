// MilestoneBadgeView.swift
// Orttaai

import SwiftUI

extension MilestoneTier {
    var color: Color {
        switch self {
        case .bronze: return Color(hex: "C9895A")
        case .silver: return Color(hex: "C3C7CF")
        case .gold: return Color(hex: "E2B04A")
        }
    }

    var title: String {
        switch self {
        case .bronze: return "Bronze"
        case .silver: return "Silver"
        case .gold: return "Gold"
        }
    }
}

/// A badge: an outer ring (the tier colour once earned, an amber progress arc
/// while in progress), a dotted tier ring, and the badge's symbol.
struct MilestoneBadgeView: View {
    let badge: MilestoneBadge
    let state: MilestoneBadgeState
    var size: CGFloat = 72

    var body: some View {
        ZStack {
            Circle()
                .fill(Color(hex: "26262A"))
            Circle()
                .strokeBorder(Color.Orttaai.bgTertiary, lineWidth: size * 0.025)
            outerRing
            Circle()
                .inset(by: size * 0.105)
                .stroke(tierColor, style: StrokeStyle(lineWidth: size * 0.05, dash: tickDash))
                .opacity(ticksOpacity)
            Circle()
                .fill(Color.Orttaai.bgPrimary)
                .padding(size * 0.175)
            Image(systemName: badge.symbol)
                .font(.system(size: size * 0.27, weight: .medium))
                .foregroundStyle(iconColor)
        }
        .frame(width: size, height: size)
        .opacity(isLocked ? 0.75 : 1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(badge.name)
    }

    @ViewBuilder
    private var outerRing: some View {
        let width = size * 0.033
        switch state {
        case .unlocked:
            Circle()
                .inset(by: width / 2)
                .stroke(badge.tier.color, lineWidth: width)
        case .inProgress(_, let fraction):
            Circle()
                .inset(by: width / 2)
                .trim(from: 0, to: fraction)
                .stroke(Color.Orttaai.accent, style: StrokeStyle(lineWidth: width, lineCap: .round))
                .rotationEffect(.degrees(-90))
        case .locked:
            EmptyView()
        }
    }

    private var isLocked: Bool { state == .locked }

    /// 40 ticks that divide the ring exactly, so no tick doubles up where
    /// the stroke starts and ends.
    private var tickDash: [CGFloat] {
        let circumference = 2 * .pi * (size / 2 - size * 0.105)
        let period = circumference / 40
        return [period * 0.25, period * 0.75]
    }

    private var tierColor: Color {
        state.isUnlocked ? badge.tier.color : Color.Orttaai.accent
    }

    private var ticksOpacity: Double {
        switch state {
        case .unlocked: return 1
        case .inProgress: return 0.15
        case .locked: return 0
        }
    }

    private var iconColor: Color {
        switch state {
        case .unlocked: return badge.tier.color
        case .inProgress: return Color(hex: "E8B45A")
        case .locked: return Color.Orttaai.textTertiary
        }
    }
}

extension MilestoneBadge {
    /// "2,005 of 5,000", "39 of 60 min", "1 of 3 days".
    func progressText(current: Int) -> String {
        let current = current.formatted()
        let target = threshold.formatted()
        switch metric {
        case .minutesSaved: return "\(current) of \(target) min"
        case .bestStreakDays: return "\(current) of \(target) days"
        case .bestWPM: return "\(current) of \(target) WPM"
        case .longestDictationSeconds: return "\(current) of \(target) s"
        case .dictionaryWords: return "\(current) of \(target) words"
        case .distinctApps: return "\(current) of \(target) apps"
        default: return "\(current) of \(target)"
        }
    }
}
