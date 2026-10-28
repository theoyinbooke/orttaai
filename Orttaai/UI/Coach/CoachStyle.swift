// CoachStyle.swift
// Orttaai
//
// Coach's look: Orttaai's tokens on a deeper ground, 24 pt surfaces and
// rounded display numbers, so it reads as a space of its own.

import AppKit
import CoachCore
import SwiftUI

enum CoachStyle {
    static let ground = Color.orttaai(light: "F5F3F0", dark: "161517")
    /// Coach's rail is dark in both looks, like the main sidebar.
    static let rail = Color(hex: "121113")
    static let surface = Color.orttaai(light: "FFFFFF", dark: "222124")
    static let surfaceRaised = Color.orttaai(light: "F3EEE6", dark: "2A292C")
    /// The warm surface for the one thing to do now.
    static let warm = Color.orttaai(light: "FBF0DD", dark: "2A241C")
    static let warmBorder = Color.Orttaai.accent.opacity(0.32)
    static let line = wash(0.07)
    static let ink = Color.orttaai(light: "1C1C1E", dark: "F4F1EC")
    static let ink2 = Color.orttaai(light: "3F3B37", dark: "D9D5CF")
    static let ink3 = Color.orttaai(light: "5E5A55", dark: "A29E99")
    static let muted = Color.orttaai(light: "6B665F", dark: "8F8B86")
    static let gain = Color.orttaai(light: "2F7A4A", dark: "86D7A0")
    static let warmInk = Color.orttaai(light: "8A5A0F", dark: "E8B062")

    /// A see-through tint for edges, tracks and quiet fills: white on the
    /// dark look, a soft black on the light one.
    static func wash(_ opacity: Double) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor.white.withAlphaComponent(opacity)
                : NSColor.black.withAlphaComponent(opacity * 0.9)
        })
    }
    static let radius: CGFloat = 24

    static func display(_ size: CGFloat) -> Font {
        .system(size: size, weight: .semibold, design: .rounded)
    }

    static let eyebrow = Font.system(size: 12, weight: .semibold)
    static let label = Font.system(size: 13)
}

extension View {
    /// A Coach surface: 24 pt corners, a hairline edge.
    func coachSurface(_ fill: Color = CoachStyle.surface, border: Color = CoachStyle.line) -> some View {
        background(RoundedRectangle(cornerRadius: CoachStyle.radius, style: .continuous).fill(fill))
            .overlay(RoundedRectangle(cornerRadius: CoachStyle.radius, style: .continuous).stroke(border, lineWidth: 1))
    }
}

/// "COACH", "PROOF": the small amber word above a page title.
struct CoachEyebrow: View {
    let text: String

    var body: some View {
        Text(text.uppercased())
            .font(CoachStyle.eyebrow)
            .tracking(1)
            .foregroundStyle(Color.Orttaai.accent)
    }
}

struct CoachPrimaryButtonStyle: ButtonStyle {
    /// Smaller, for buttons inside a card.
    var compact = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: compact ? 13 : 14, weight: .semibold))
            .foregroundStyle(Color.orttaai(light: "FFFFFF", dark: "1B1917"))
            .padding(.horizontal, compact ? 16 : 20)
            .frame(height: compact ? 32 : 44)
            .background(Capsule().fill(Color.Orttaai.accent.opacity(configuration.isPressed ? 0.8 : 1)))
            .contentShape(Capsule())
    }
}

struct CoachSecondaryButtonStyle: ButtonStyle {
    /// Smaller, for buttons inside a card.
    var compact = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: compact ? 13 : 14, weight: .semibold))
            .foregroundStyle(CoachStyle.ink)
            .padding(.horizontal, compact ? 14 : 18)
            .frame(height: compact ? 32 : 44)
            .background(Capsule().fill(CoachStyle.wash(configuration.isPressed ? 0.12 : 0.06)))
            .overlay(Capsule().stroke(CoachStyle.wash(0.12), lineWidth: 1))
            .contentShape(Capsule())
    }
}

/// A small coloured status label.
struct CoachTag: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 10)
            .frame(height: 24)
            .background(Capsule().fill(color.opacity(0.16)))
    }
}

extension HabitStatus {
    var title: String {
        switch self {
        case .watching: return "Watching"
        case .working: return "Working"
        case .notMoving: return "Not moving"
        }
    }

    var color: Color {
        switch self {
        case .watching: return CoachStyle.ink2
        case .working: return CoachStyle.gain
        case .notMoving: return CoachStyle.warmInk
        }
    }
}

enum CoachFormat {
    /// A measure's figure in its unit, short.
    static func figure(_ value: Double?, _ measure: CoachMeasure) -> String {
        guard let value else { return "–" }
        switch measure {
        case .fillers, .phrases, .repeats: return String(format: "%.1f", value)
        case .pace, .sentences: return "\(Int(value.rounded()))"
        case .clarity: return "\(Int((value * 100).rounded()))%"
        }
    }

    static func percent(_ share: Double?) -> String {
        guard let share else { return "–" }
        return "\(Int((share * 100).rounded()))%"
    }

    static func points(_ drift: Double) -> String {
        let value = Int((drift * 100).rounded())
        return value > 0 ? "+\(value)%" : "\(value)%"
    }

    static func modeLabel(_ mode: CoachMode?) -> String {
        mode?.title ?? "Everywhere"
    }
}
