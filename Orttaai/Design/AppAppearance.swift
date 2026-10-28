// AppAppearance.swift
// Orttaai

import AppKit

/// Light, dark, or whatever the Mac is set to, for every Orttaai window.
/// The recording pill and toasts stay dark wherever they float.
enum AppAppearance: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    static let key = "appearance"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return "Match Mac"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    static var current: AppAppearance {
        UserDefaults.standard.string(forKey: key).flatMap(AppAppearance.init(rawValue:)) ?? .system
    }

    /// Nil follows the Mac.
    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }

    @MainActor
    static func apply(_ appearance: AppAppearance = current) {
        NSApp.appearance = appearance.nsAppearance
    }
}
