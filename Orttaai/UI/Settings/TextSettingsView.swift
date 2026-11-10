// TextSettingsView.swift
// Orttaai

import SwiftUI
import AppKit

/// What happens to the words after they are transcribed.
struct TextSettingsView: View {
    @AppStorage("spokenFormattingEnabled") private var spokenFormattingEnabled = true
    @AppStorage("autoParagraphsEnabled") private var autoParagraphsEnabled = true
    @AppStorage("fuzzyDictionaryEnabled") private var fuzzyDictionaryEnabled = true
    @AppStorage("disfluencyCleanupEnabled") private var disfluencyCleanupEnabled = true
    @AppStorage("editCommandsEnabled") private var editCommandsEnabled = true
    @AppStorage("editWithDictationKeyEnabled") private var editWithDictationKeyEnabled = true
    @AppStorage("rightCommandEditEnabled") private var rightCommandEditEnabled = false
    @State private var hasInputMonitoring = ModifierTapMonitor.hasInputMonitoringAccess

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
                    info: "Corrects near-miss spellings of your dictionary words, like Tematope for Temitope. English only. Needs Dictionary Replacements on in Memory.",
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
                    info: "Select text, press the edit shortcut, and say how to change it, like \u{201C}make this more formal\u{201D}. With nothing selected, the edit shortcut works on your last dictation. Uses the local model on Ollama or LM Studio set in Model › AI Features. S1-mini can only polish.",
                    isOn: $editCommandsEnabled
                )

                if editCommandsEnabled {
                    SettingsDivider()

                    SettingsToggleRow(
                        title: "Edit with the Dictation Shortcut",
                        info: "Select text, press your dictation shortcut, and say an instruction like \u{201C}make this shorter\u{201D} or \u{201C}fix the grammar\u{201D}. Anything else you say replaces the selection, as before. English only, and only in apps that let Orttaai read the selection; elsewhere use the edit shortcut.",
                        isOn: $editWithDictationKeyEnabled
                    )

                    SettingsDivider()

                    SettingsToggleRow(
                        title: "Tap Right Command to Edit",
                        info: "Tap the Right Command key, say how to change the selected text (or your last dictation, when nothing is selected), and tap it again to apply. \u{2318} shortcuts still work as usual. Needs Input Monitoring.",
                        isOn: $rightCommandEditEnabled
                    )

                    if rightCommandEditEnabled, !hasInputMonitoring {
                        SettingsRow(title: "Input Monitoring") {
                            Button("Allow\u{2026}") {
                                _ = CGRequestListenEventAccess()
                                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
                                    NSWorkspace.shared.open(url)
                                }
                            }
                            .buttonStyle(OrttaaiButtonStyle(.secondary, size: .small))
                        }

                        SettingsNotice(
                            kind: .warning,
                            message: "Turn on Orttaai under Privacy & Security \u{203A} Input Monitoring. The key starts working as soon as it's allowed."
                        )
                    }

                    SettingsDivider()

                    SettingsRow(title: "Edit Shortcut") {
                        ShortcutRecorderField(name: .editCommand)
                    }
                }
            }
        }
        .task(id: rightCommandEditEnabled) {
            // Watch for the permission while the key is on but not allowed,
            // so the notice clears by itself once it's granted.
            while rightCommandEditEnabled, !Task.isCancelled {
                hasInputMonitoring = ModifierTapMonitor.hasInputMonitoringAccess
                if hasInputMonitoring { break }
                try? await Task.sleep(for: .seconds(1.5))
            }
        }
    }
}
