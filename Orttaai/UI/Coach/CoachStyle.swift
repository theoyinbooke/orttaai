// CoachStyle.swift
// Orttaai
//
// Coach's look: Orttaai's tokens on a deeper ground, 24 pt surfaces and
// rounded display numbers, so it reads as a space of its own.

import CoachCore
import SwiftUI

enum CoachStyle {
    static let ground = Color(hex: "161517")
    static let rail = Color(hex: "121113")
    static let surface = Color(hex: "222124")
    static let surfaceRaised = Color(hex: "2A292C")
    /// The warm surface for the one thing to do now.
    static let warm = Color(hex: "2A241C")
    static let warmBorder = Color.Orttaai.accent.opacity(0.32)
    static let line = Color.white.opacity(0.07)
    static let ink = Color(hex: "F4F1EC")
    static let ink2 = Color(hex: "D9D5CF")
    static let ink3 = Color(hex: "A29E99")
    static let muted = Color(hex: "8F8B86")
    static let gain = Color(hex: "86D7A0")
    static let warmInk = Color(hex: "E8B062")
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
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(Color(hex: "1B1917"))
            .padding(.horizontal, 20)
            .frame(height: 44)
            .background(Capsule().fill(Color.Orttaai.accent.opacity(configuration.isPressed ? 0.8 : 1)))
            .contentShape(Capsule())
    }
}

struct CoachSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(CoachStyle.ink)
            .padding(.horizontal, 18)
            .frame(height: 44)
            .background(Capsule().fill(Color.white.opacity(configuration.isPressed ? 0.12 : 0.06)))
            .overlay(Capsule().stroke(Color.white.opacity(0.12), lineWidth: 1))
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
