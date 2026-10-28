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
    static let judgeGradesKey = "coachJudgeGrades"
    static let partnerModelKey = "coachPartnerModel"
    static let handsFreeKey = "coachHandsFree"
    /// Model setup was finished or put off, so it doesn't open by itself again.
    static let modelSetupSeenKey = "coachModelSetupSeen"

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

    /// In a spoken scene, your turn starts when the partner stops talking
    /// and ends when you pause, with no button.
    static var handsFree: Bool {
        UserDefaults.standard.object(forKey: handsFreeKey) as? Bool ?? true
    }

    /// Whether the coach's note is read aloud after a rep.
    static var readsAloud: Bool {
        UserDefaults.standard.object(forKey: readAloudKey) as? Bool ?? false
    }

    /// How each model did on Coach's judge check, by model name.
    static var judgeGrades: [String: JudgeGrade] {
        guard let data = UserDefaults.standard.data(forKey: judgeGradesKey),
              let grades = try? JSONDecoder().decode([String: JudgeGrade].self, from: data) else { return [:] }
        return grades
    }

    /// A model's grade against the examples in use now.
    static func judgeGrade(for model: String) -> JudgeGrade? {
        judgeGrades[model].flatMap { $0.isCurrent ? $0 : nil }
    }

    static func saveJudgeGrade(_ grade: JudgeGrade) {
        var all = judgeGrades
        all[grade.model] = grade
        if let data = try? JSONEncoder().encode(all) {
            UserDefaults.standard.set(data, forKey: judgeGradesKey)
        }
        NotificationCenter.default.post(name: .coachPreferencesDidChange, object: nil)
    }

    /// The most accurate model that passed, then the fastest.
    static var bestPassingJudge: JudgeGrade? {
        judgeGrades.values
            .filter { $0.isCurrent && $0.passes }
            .max { ($0.accuracy, -($0.msPerAnswer ?? .max)) < ($1.accuracy, -($1.msPerAnswer ?? .max)) }
    }

    /// The rule in force for an app: the person's choice, else the table.
    static func rule(for app: CoachAppUsage, overrides: [String: CoachAppRule]) -> CoachAppRule {
        if let rule = overrides[app.key] { return rule }
        let mode = CoachAppCatalog.builtInMode(bundleID: app.bundleID, appName: app.appName)
        return CoachAppRule(rawValue: mode.rawValue) ?? .elsewhere
    }
}
