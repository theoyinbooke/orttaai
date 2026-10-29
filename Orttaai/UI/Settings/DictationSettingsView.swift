// DictationSettingsView.swift
// Orttaai

import SwiftUI
import KeyboardShortcuts
import AppKit

/// How recording starts and stops, plus the spoken language.
struct DictationSettingsView: View {
    @AppStorage("maxRecordingDuration") private var maxRecordingDuration = 90
    @AppStorage("handsFreeModeEnabled") private var handsFreeModeEnabled = true
    @AppStorage("handsFreeSilenceStopEnabled") private var handsFreeSilenceStopEnabled = true
    @AppStorage("handsFreeSilenceStopSeconds") private var handsFreeSilenceStopSeconds = 4.0
    @AppStorage("handsFreeMaxRecordingDuration") private var handsFreeMaxRecordingDuration = 600
    @AppStorage("rightOptionDictationEnabled") private var rightOptionDictationEnabled = false
    @State private var hasInputMonitoring = RightOptionTapMonitor.hasInputMonitoringAccess
    @AppStorage("dictationLanguage") private var dictationLanguage = "en"
    @AppStorage("lowLatencyModeEnabled") private var lowLatencyModeEnabled = false
    @State private var languageSwitchStatus: String?
    @State private var languageSwitchError: String?

    static let supportedLanguages: [(code: String, name: String)] = [
        ("en", "English"),
        ("es", "Spanish"),
        ("fr", "French"),
        ("de", "German"),
        ("ja", "Japanese"),
        ("zh", "Chinese"),
        ("ko", "Korean"),
        ("pt", "Portuguese"),
        ("it", "Italian"),
        ("nl", "Dutch"),
        ("ru", "Russian"),
        ("ar", "Arabic"),
        ("hi", "Hindi"),
        ("auto", "Auto-detect"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            recordingCard
            languageCard
        }
        .task(id: rightOptionDictationEnabled) {
            // Watch for the permission while the key is on but not allowed,
            // so the notice clears by itself once it's granted.
            while rightOptionDictationEnabled, !Task.isCancelled {
                hasInputMonitoring = RightOptionTapMonitor.hasInputMonitoringAccess
                if hasInputMonitoring { break }
                try? await Task.sleep(for: .seconds(1.5))
            }
        }
        .onChange(of: dictationLanguage) { _, newValue in
            if lowLatencyModeEnabled, newValue == "auto" {
                dictationLanguage = "en"
                return
            }
            switchToLanguageOptimizedModelIfNeeded()
        }
    }

    private var recordingCard: some View {
        SettingsCard("Recording") {
            SettingsRow(
                title: "Push to Talk Shortcut",
                info: handsFreeModeEnabled
                    ? "Hold to dictate and release to insert. A quick tap starts a hands-free recording instead."
                    : "Hold to dictate and release to insert."
            ) {
                ShortcutRecorderField(name: .pushToTalk)
            }

            SettingsDivider()

            SettingsToggleRow(
                title: "Tap Right Option to Dictate",
                info: "Tap the Right Option key once to start talking, and tap it again to insert the text. Typing ⌥ characters and ⌥ shortcuts still work as usual. Needs Input Monitoring.",
                isOn: $rightOptionDictationEnabled
            )

            if rightOptionDictationEnabled, !hasInputMonitoring {
                SettingsRow(title: "Input Monitoring") {
                    Button("Allow…") {
                        _ = CGRequestListenEventAccess()
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .buttonStyle(OrttaaiButtonStyle(.secondary, size: .small))
                }

                SettingsNotice(
                    kind: .warning,
                    message: "Turn on Orttaai under Privacy & Security › Input Monitoring. The key starts working as soon as it's allowed."
                )
            }

            SettingsDivider()

            SettingsToggleRow(
                title: "Hands-Free Dictation",
                info: "Tap the shortcut to start, and tap again to stop, instead of holding it. The pill's mic button also records hands-free.",
                isOn: $handsFreeModeEnabled
            )

            if handsFreeModeEnabled {
                SettingsDivider()

                SettingsRow(
                    title: "Stop After Silence",
                    info: "Ends a hands-free recording once you stop talking for this long. It only starts counting after it hears you speak. Off means it runs until you stop it."
                ) {
                    OrttaaiSegmentedControl(
                        title: "Stop After Silence",
                        selection: silenceStopSelection,
                        options: silenceStopOptions
                    )
                }

                SettingsDivider()

                SettingsRow(
                    title: "Hands-Free Limit",
                    info: "The longest a hands-free recording can run. The pill counts down the final 20 seconds."
                ) {
                    OrttaaiSegmentedControl(
                        title: "Hands-Free Limit",
                        selection: $handsFreeMaxRecordingDuration,
                        options: Self.presetOptions(
                            [300, 600, 900, 1800],
                            current: handsFreeMaxRecordingDuration,
                            in: AppSettings.handsFreeMaxRecordingDurationRange,
                            label: Self.minutesLabel
                        )
                    )
                }
            }

            SettingsDivider()

            SettingsRow(
                title: "Push-to-Talk Limit",
                info: "The longest you can hold to talk in one go. The pill counts down the final 20 seconds."
            ) {
                OrttaaiSegmentedControl(
                    title: "Push-to-Talk Limit",
                    selection: $maxRecordingDuration,
                    options: Self.presetOptions(
                        [30, 60, 90, 120, 300],
                        current: maxRecordingDuration,
                        in: AppSettings.pushToTalkMaxRecordingDurationRange,
                        label: Self.secondsLabel
                    )
                )
            }
        }
    }

    private var languageCard: some View {
        SettingsCard("Language") {
            SettingsRow(
                title: "Dictation Language",
                info: lowLatencyModeEnabled
                    ? "The language you speak. Auto-detect is unavailable while Low Latency Mode is on (Model › Speech)."
                    : "The language you speak. Auto-detect handles any language but is slower."
            ) {
                OrttaaiDropdown(
                    selection: $dictationLanguage,
                    options: languageOptions,
                    width: SettingsLayout.controlWidth
                )
            }

            if let languageSwitchStatus {
                SettingsNotice(kind: .info, message: languageSwitchStatus)
            }

            if let languageSwitchError {
                SettingsNotice(kind: .error, message: languageSwitchError) {
                    self.languageSwitchError = nil
                }
            }
        }
    }

    private var languageOptions: [OrttaaiDropdown<String>.Option] {
        Self.supportedLanguages
            .filter { !(lowLatencyModeEnabled && $0.code == "auto") }
            .map { .init($0.code, $0.name) }
    }

    /// nil means silence stop is off.
    private var silenceStopSelection: Binding<Double?> {
        Binding(
            get: { handsFreeSilenceStopEnabled ? handsFreeSilenceStopSeconds : nil },
            set: { newValue in
                if let newValue {
                    handsFreeSilenceStopSeconds = newValue
                    handsFreeSilenceStopEnabled = true
                } else {
                    handsFreeSilenceStopEnabled = false
                }
            }
        )
    }

    private var silenceStopOptions: [OrttaaiSegmentedControl<Double?>.Option] {
        var seconds: [Double] = [2, 4, 6, 8, 10]
        let current = max(1.0, min(10.0, handsFreeSilenceStopSeconds))
        if handsFreeSilenceStopEnabled, !seconds.contains(current) {
            seconds.append(current)
            seconds.sort()
        }
        return [.init(nil, "Off")] + seconds.map { .init($0, Self.silenceLabel($0)) }
    }

    /// Preset choices plus the stored value when it is a custom one, so a
    /// value set before the presets existed is still shown as selected.
    static func presetOptions(
        _ presets: [Int],
        current: Int,
        in range: ClosedRange<Int>,
        label: (Int) -> String
    ) -> [OrttaaiSegmentedControl<Int>.Option] {
        var values = presets
        if range.contains(current), !values.contains(current) {
            values.append(current)
            values.sort()
        }
        return values.map { .init($0, label($0)) }
    }

    static func secondsLabel(_ seconds: Int) -> String {
        seconds >= 120 && seconds % 60 == 0 ? "\(seconds / 60) min" : "\(seconds)s"
    }

    static func minutesLabel(_ seconds: Int) -> String {
        seconds % 60 == 0 ? "\(seconds / 60) min" : String(format: "%.1f min", Double(seconds) / 60)
    }

    static func silenceLabel(_ seconds: Double) -> String {
        seconds.rounded() == seconds ? "\(Int(seconds))s" : String(format: "%.1fs", seconds)
    }

    /// Keeps Small on its English-only checkpoint for English and on the
    /// multilingual one otherwise, reloading the model when that changes.
    private func switchToLanguageOptimizedModelIfNeeded() {
        let settings = AppSettings()
        let target = settings.effectiveSelectedModelId
        guard target != settings.selectedModelId else { return }

        guard let manager = ModelManager.shared else {
            settings.applyLanguageOptimizedSmallModelSelection()
            return
        }

        languageSwitchError = nil
        languageSwitchStatus = "Switching to \(ModelManager.formatDisplayName(target)) for this language…"
        Task {
            do {
                try await manager.switchModel(toModelId: target)
                settings.selectedModelId = target
            } catch {
                languageSwitchError = "Couldn't switch models: \(error.localizedDescription)"
            }
            languageSwitchStatus = nil
        }
    }
}
