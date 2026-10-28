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
    static let personasKey = "coachPersonas"
    static let coachModelKey = "coachModel"
    static let judgeModelKey = "coachJudgeModel"
    static let readAloudKey = "coachReadAloud"

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

    /// The coach for each way of talking; Mentor unless chosen.
    static var personas: [CoachMode: CoachPersona] {
        guard let data = UserDefaults.standard.string(forKey: personasKey)?.data(using: .utf8),
              let raw = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        var result: [CoachMode: CoachPersona] = [:]
        for (mode, persona) in raw {
            if let mode = CoachMode(rawValue: mode), let persona = CoachPersona(rawValue: persona) { result[mode] = persona }
        }
        return result
    }

    static func persona(for mode: CoachMode?) -> CoachPersona {
        personas[mode ?? .elsewhere] ?? personas[.ai] ?? .mentor
    }

    static func setPersona(_ persona: CoachPersona, for mode: CoachMode) {
        var all = personas
        all[mode] = persona
        let raw = Dictionary(uniqueKeysWithValues: all.map { ($0.key.rawValue, $0.value.rawValue) })
        if let data = try? JSONEncoder().encode(raw), let text = String(data: data, encoding: .utf8) {
            UserDefaults.standard.set(text, forKey: personasKey)
        }
        NotificationCenter.default.post(name: .coachPreferencesDidChange, object: nil)
    }

    /// Whether the coach's note is read aloud after a rep.
    static var readsAloud: Bool {
        UserDefaults.standard.object(forKey: readAloudKey) as? Bool ?? false
    }

    /// The rule in force for an app: the person's choice, else the table.
    static func rule(for app: CoachAppUsage, overrides: [String: CoachAppRule]) -> CoachAppRule {
        if let rule = overrides[app.key] { return rule }
        let mode = CoachAppCatalog.builtInMode(bundleID: app.bundleID, appName: app.appName)
        return CoachAppRule(rawValue: mode.rawValue) ?? .elsewhere
    }
}
