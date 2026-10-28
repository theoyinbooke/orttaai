// CoachPreferences.swift
// Orttaai

import CoachCore
import Foundation

extension Notification.Name {
    /// Posted when Coach is switched on or off, or an app's choice changes.
    nonisolated static let coachPreferencesDidChange = Notification.Name("Orttaai.coachPreferencesDidChange")
}

/// What the person chose for Coach, kept in UserDefaults.
nonisolated enum CoachPreferences {
    static let enabledKey = "coachEnabled"
    static let overridesKey = "coachAppOverrides"
    static let firstRunDoneKey = "coachFirstRunDone"

    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
    }

    /// App key (`CoachAppCatalog.key`) → the person's choice.
    static var overrides: [String: CoachAppRule] {
        guard let data = UserDefaults.standard.string(forKey: overridesKey)?.data(using: .utf8),
              let raw = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return raw.compactMapValues(CoachAppRule.init(rawValue:))
    }

    static var offKeys: Set<String> {
        Set(overrides.filter { $0.value == .off }.map(\.key))
    }

    static func setRule(_ rule: CoachAppRule?, forKey key: String) {
        var all = overrides
        all[key] = rule
        let raw = all.mapValues(\.rawValue)
        if let data = try? JSONEncoder().encode(raw), let text = String(data: data, encoding: .utf8) {
            UserDefaults.standard.set(text, forKey: overridesKey)
        }
        NotificationCenter.default.post(name: .coachPreferencesDidChange, object: nil)
    }

    static func setEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: enabledKey)
        NotificationCenter.default.post(name: .coachPreferencesDidChange, object: nil)
    }

    /// The rule in force for an app: the person's choice, else the table.
    static func rule(for app: CoachAppUsage, overrides: [String: CoachAppRule]) -> CoachAppRule {
        if let rule = overrides[app.key] { return rule }
        let mode = CoachAppCatalog.builtInMode(bundleID: app.bundleID, appName: app.appName)
        return CoachAppRule(rawValue: mode.rawValue) ?? .elsewhere
    }
}
