// CoachSettingsView.swift
// Orttaai

import CoachCore
import SwiftUI

/// Coach on or off, and which way of talking each app counts as.
struct CoachSettingsView: View {
    @ObservedObject private var center = CoachCenter.shared
    @AppStorage(CoachPreferences.enabledKey) private var enabled = true
    @AppStorage(CoachPreferences.overridesKey) private var overridesJSON = ""
    @AppStorage(CoachPreferences.firstRunDoneKey) private var firstRunDone = false

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            SettingsCard("Coach") {
                SettingsToggleRow(
                    title: "Coach",
                    info: "Counts fillers, pace and sentence length in your dictations, on this Mac, and checks whether habits you start stick. It stores numbers only.",
                    isOn: Binding(get: { enabled }, set: { CoachPreferences.setEnabled($0) })
                )
                SettingsDivider()
                SettingsRow(title: "Setup", info: "Shows Coach's first-run steps again the next time you open it.") {
                    Button("Run Again") { firstRunDone = false }
                        .disabled(!firstRunDone)
                }
            }

            SettingsCard(
                "Apps",
                info: "Coach groups your dictations by the app they went to. Move an app to another way of talking, or switch it off so Coach never reads it."
            ) {
                let apps = (center.snapshot?.apps ?? []).filter { !$0.key.isEmpty }
                if apps.isEmpty {
                    SettingsFootnote("Apps appear here after your first dictations.")
                } else {
                    ForEach(Array(apps.enumerated()), id: \.element.id) { index, app in
                        if index > 0 { SettingsDivider() }
                        SettingsRow(title: app.displayName) {
                            Picker(app.displayName, selection: binding(for: app)) {
                                ForEach(CoachAppRule.allCases, id: \.self) { rule in
                                    Text(title(for: rule)).tag(rule)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                            .fixedSize()
                        }
                    }
                }
            }
            .disabled(!enabled)
        }
        .task { await center.refresh() }
    }

    private func binding(for app: CoachAppUsage) -> Binding<CoachAppRule> {
        Binding(
            get: {
                _ = overridesJSON
                return CoachPreferences.rule(for: app, overrides: CoachPreferences.overrides)
            },
            set: { center.setRule($0, for: app) }
        )
    }

    private func title(for rule: CoachAppRule) -> String {
        switch rule {
        case .off: return "Off"
        default: return rule.mode?.title ?? rule.rawValue
        }
    }
}
