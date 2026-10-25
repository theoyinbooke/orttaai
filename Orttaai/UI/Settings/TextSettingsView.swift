// TextSettingsView.swift
// Orttaai

import SwiftUI

/// What happens to the words after they are transcribed.
struct TextSettingsView: View {
    @AppStorage("spokenFormattingEnabled") private var spokenFormattingEnabled = true
    @AppStorage("autoParagraphsEnabled") private var autoParagraphsEnabled = true
    @AppStorage("fuzzyDictionaryEnabled") private var fuzzyDictionaryEnabled = true
    @AppStorage("disfluencyCleanupEnabled") private var disfluencyCleanupEnabled = true
    @AppStorage("editCommandsEnabled") private var editCommandsEnabled = true

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            SettingsCard("Cleanup") {
                SettingsToggleRow(
                    title: "Spoken Formatting",
                    info: "Turns spoken commands like \u{201C}new line\u{201D} and \u{201C}new paragraph\u{201D} into real breaks, and \u{201C}first, \u{2026} second, \u{2026}\u{201D}, \u{201C}number one\u{201D} or \u{201C}bullet point\u{201D} into lists.",
                    isOn: $spokenFormattingEnabled
                )

                SettingsDivider()

                SettingsToggleRow(
                    title: "Automatic Paragraphs",
                    info: "Splits a long dictation into paragraphs where you move to a new point. Never in Terminal and other command-line apps.",
                    isOn: $autoParagraphsEnabled
                )

                SettingsDivider()

                SettingsToggleRow(
                    title: "Fuzzy Dictionary Matching",
                    info: "Corrects near-miss spellings of your dictionary words, like Tematope for Temitope.",
                    isOn: $fuzzyDictionaryEnabled
                )

                SettingsDivider()

                SettingsToggleRow(
                    title: "Remove Fillers and Stutters",
                    info: "Removes um and uh, collapses repeats like \u{201C}the the\u{201D} and \u{201C}we don\u{2019}t we don\u{2019}t\u{201D}, and capitalizes a lowercase i. English only.",
                    isOn: $disfluencyCleanupEnabled
                )
            }

            SettingsCard("Voice Editing") {
                SettingsToggleRow(
                    title: "Edit Selection with Voice",
                    info: "Select text, press the edit shortcut, and say how to change it, like \u{201C}make this more formal\u{201D}. Uses the polish model set in Model › AI Features.",
                    isOn: $editCommandsEnabled
                )

                if editCommandsEnabled {
                    SettingsDivider()

                    SettingsRow(title: "Edit Shortcut") {
                        ShortcutRecorderField(name: .editCommand)
                    }
                }
            }
        }
    }
}
