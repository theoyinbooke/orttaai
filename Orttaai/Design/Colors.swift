// Colors.swift
// Orttaai

import SwiftUI
import AppKit

// MARK: - Hex Initializer

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: .init(charactersIn: "#"))
        let scanner = Scanner(string: hex)
        var rgb: UInt64 = 0
        scanner.scanHexInt64(&rgb)
        self.init(
            red: Double((rgb >> 16) & 0xFF) / 255,
            green: Double((rgb >> 8) & 0xFF) / 255,
            blue: Double(rgb & 0xFF) / 255
        )
    }
}

extension NSColor {
    convenience init(hex: String) {
        let hex = hex.trimmingCharacters(in: .init(charactersIn: "#"))
        let scanner = Scanner(string: hex)
        var rgb: UInt64 = 0
        scanner.scanHexInt64(&rgb)
        self.init(
            red: CGFloat((rgb >> 16) & 0xFF) / 255,
            green: CGFloat((rgb >> 8) & 0xFF) / 255,
            blue: CGFloat(rgb & 0xFF) / 255,
            alpha: 1.0
        )
    }
}

// MARK: - Colour Tokens
//
// Each token has a light and a dark value and follows the appearance it's
// drawn in: the window's, set app-wide by Settings › Appearance. The
// AppKit tokens are the source; the SwiftUI ones wrap them.

extension NSColor {
    /// A colour for each look.
    static func orttaai(light: String, dark: String) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(hex: dark) : NSColor(hex: light)
        }
    }

    enum Orttaai {
        // Backgrounds: the window's ground, cards on it, and wells inside cards.
        static let bgPrimary = NSColor.orttaai(light: "F5F3F0", dark: "1C1C1E")
        static let bgSecondary = NSColor.orttaai(light: "FFFFFF", dark: "2C2C2E")
        static let bgTertiary = NSColor.orttaai(light: "EAE4DA", dark: "3A3A3C")

        // Text
        static let textPrimary = NSColor.orttaai(light: "1C1C1E", dark: "F5F3F0")
        static let textSecondary = NSColor.orttaai(light: "5E5A55", dark: "A1A1A6")
        static let textTertiary = NSColor.orttaai(light: "6B665F", dark: "636366")

        // Accent. Light uses a deeper gold, so text on it (bgPrimary) and the
        // gold itself as text both stay readable on cream.
        static let accent = NSColor.orttaai(light: "9A6210", dark: "D4952A")

        static let border = NSColor.orttaai(light: "E2DCD2", dark: "38383A")

        // Semantic
        static let success = NSColor.orttaai(light: "2F7A4A", dark: "34C759")
        static let warning = NSColor.orttaai(light: "A65A00", dark: "FF9F0A")
        static let error = NSColor.orttaai(light: "C2412F", dark: "FF453A")
    }
}

extension Color {
    /// A one-off colour with a value for each look.
    static func orttaai(light: String, dark: String) -> Color {
        Color(nsColor: .orttaai(light: light, dark: dark))
    }

    enum Orttaai {
        // Backgrounds
        static let bgPrimary = Color(nsColor: NSColor.Orttaai.bgPrimary)
        static let bgSecondary = Color(nsColor: NSColor.Orttaai.bgSecondary)
        static let bgTertiary = Color(nsColor: NSColor.Orttaai.bgTertiary)

        // Text
        static let textPrimary = Color(nsColor: NSColor.Orttaai.textPrimary)
        static let textSecondary = Color(nsColor: NSColor.Orttaai.textSecondary)
        static let textTertiary = Color(nsColor: NSColor.Orttaai.textTertiary)

        // Accent
        static let accent = Color(nsColor: NSColor.Orttaai.accent)
        static let accentSubtle = accent.opacity(0.12)
        static let accentHover = accent.opacity(0.80)
        static let accentPressed = accent.opacity(0.60)
        static let accentRing = accent.opacity(0.40)

        // Borders
        static let border = Color(nsColor: NSColor.Orttaai.border)

        // Semantic
        static let success = Color(nsColor: NSColor.Orttaai.success)
        static let successSubtle = success.opacity(0.12)
        static let warning = Color(nsColor: NSColor.Orttaai.warning)
        static let warningSubtle = warning.opacity(0.12)
        static let error = Color(nsColor: NSColor.Orttaai.error)
        static let errorSubtle = error.opacity(0.12)
    }
}
