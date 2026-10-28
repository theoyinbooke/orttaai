// DashboardCard.swift
// Orttaai

import SwiftUI

/// How cards are drawn where they're shown. Home keeps its classic cards;
/// the other sections use the rounded ones from Coach's style.
enum CardShape {
    case classic
    case rounded

    var radius: CGFloat {
        switch self {
        case .classic: return CornerRadius.card
        case .rounded: return CornerRadius.roundedCard
        }
    }
}

extension EnvironmentValues {
    @Entry var cardShape: CardShape = .classic
}

struct DashboardCardModifier: ViewModifier {
    @Environment(\.cardShape) private var shape

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: shape.radius, style: .continuous)
                    .fill(Color.Orttaai.bgSecondary)
            )
            .overlay(
                RoundedRectangle(cornerRadius: shape.radius, style: .continuous)
                    .stroke(Color.Orttaai.border, lineWidth: BorderWidth.standard)
            )
        // No drop shadow: on the dark background it barely showed, and a
        // blurred shadow on every card had to be recomputed while scrolling.
    }
}

/// The one card on a page that holds the thing that matters most, warm in
/// both looks.
struct WarmCardModifier: ViewModifier {
    @Environment(\.cardShape) private var shape

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: shape.radius, style: .continuous)
                    .fill(Color.orttaai(light: "FBF0DD", dark: "2A241C"))
            )
            .overlay(
                RoundedRectangle(cornerRadius: shape.radius, style: .continuous)
                    .stroke(Color.Orttaai.accent.opacity(0.35), lineWidth: BorderWidth.standard)
            )
    }
}

/// Clips to the card's corners where it's shown.
struct CardClipModifier: ViewModifier {
    @Environment(\.cardShape) private var shape

    func body(content: Content) -> some View {
        content.clipShape(RoundedRectangle(cornerRadius: shape.radius, style: .continuous))
    }
}

extension View {
    func dashboardCard() -> some View {
        modifier(DashboardCardModifier())
    }

    func warmCard() -> some View {
        modifier(WarmCardModifier())
    }

    func cardClip() -> some View {
        modifier(CardClipModifier())
    }
}
