// Colors.swift
// Uttrai

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

// MARK: - SwiftUI Color Tokens

extension Color {
    enum Uttrai {
        // Backgrounds
        static let bgPrimary = Color(hex: "1C1C1E")
        static let bgSecondary = Color(hex: "2C2C2E")
        static let bgTertiary = Color(hex: "3A3A3C")

        // Text
        static let textPrimary = Color(hex: "F5F3F0")
        static let textSecondary = Color(hex: "A1A1A6")
        static let textTertiary = Color(hex: "636366")

        // Accent
        static let accent = Color(hex: "D4952A")
        static let accentSubtle = Color(hex: "D4952A").opacity(0.12)
        static let accentHover = Color(hex: "D4952A").opacity(0.80)
        static let accentPressed = Color(hex: "D4952A").opacity(0.60)
        static let accentRing = Color(hex: "D4952A").opacity(0.40)

        // Borders
        static let border = Color(hex: "38383A")

        // Semantic
        static let success = Color(hex: "34C759")
        static let successSubtle = Color(hex: "34C759").opacity(0.12)
        static let warning = Color(hex: "FF9F0A")
        static let warningSubtle = Color(hex: "FF9F0A").opacity(0.12)
        static let error = Color(hex: "FF453A")
        static let errorSubtle = Color(hex: "FF453A").opacity(0.12)
    }
}

// MARK: - AppKit NSColor Tokens

extension NSColor {
    enum Uttrai {
        static let bgPrimary = NSColor(hex: "1C1C1E")
        static let bgSecondary = NSColor(hex: "2C2C2E")
        static let bgTertiary = NSColor(hex: "3A3A3C")
        static let textPrimary = NSColor(hex: "F5F3F0")
        static let textSecondary = NSColor(hex: "A1A1A6")
        static let textTertiary = NSColor(hex: "636366")
        static let accent = NSColor(hex: "D4952A")
        static let border = NSColor(hex: "38383A")
        static let success = NSColor(hex: "34C759")
        static let warning = NSColor(hex: "FF9F0A")
        static let error = NSColor(hex: "FF453A")
    }
}
