// ReadyStepView.swift
// Orttaai

import SwiftUI
import Foundation
import CoreAudio
import KeyboardShortcuts
import os

struct ReadyStepView: View {
    var onStart: (() -> Void)?
    @AppStorage("selectedAudioDeviceID") private var selectedAudioDeviceID = ""
    @State private var quickTestText = ""
    @State private var quickTestState: DictationStateSignal = .idle
    @State private var quickTestMessage = "Waiting for hotkey."
    @State private var hasDetectedHotkey = false
    @State private var hotkeyLabel = "Ctrl + Space"
    @State private var targetAppName: String?
    @State private var countdownSeconds: Int?
    @State private var elapsedRecordingSeconds: Int?
    @State private var idleMicLevel: Float = 0
    @State private var liveDictationLevel: Float = 0
    @State private var micMonitorCapture: AudioCaptureService?
    @State private var micLevelTimer: Timer?
    @State private var micMonitorError: String?
    @State private var audioDeviceManager = AudioDeviceManager()
    private let shortcutChangeNotification = Notification.Name("KeyboardShortcuts_shortcutByNameDidChange")

    var body: some View {
        VStack(spacing: Spacing.lg) {
            HStack(spacing: Spacing.md) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 34))
                    .foregroundStyle(Color.Orttaai.success)
                    .accessibilityHidden(true)

                Text("Orttaai is ready!")
                    .font(.Orttaai.title)
                    .foregroundStyle(Color.Orttaai.textPrimary)
            }

            HStack(spacing: Spacing.sm) {
                Text("Press")
                    .font(.Orttaai.body)
                    .foregroundStyle(Color.Orttaai.textSecondary)

                Text(hotkeyLabel)
                    .font(.Orttaai.mono)
                    .foregroundStyle(Color.Orttaai.accent)
                    .padding(.horizontal, Spacing.md)
                    .padding(.vertical, 6)
                    .background(Color.Orttaai.bgSecondary)
                    .clipShape(RoundedRectangle(cornerRadius: CornerRadius.card))

                Text("to start dictating.")
                    .font(.Orttaai.body)
                    .foregroundStyle(Color.Orttaai.textSecondary)
            }
            .lineLimit(1)

            Text("Hold the hotkey while speaking, then release to transcribe and paste.")
                .font(.Orttaai.secondary)
                .foregroundStyle(Color.Orttaai.textTertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)

            microphoneCheckCard

            VStack(alignment: .leading, spacing: Spacing.xs) {
                feedbackSummary

                Text("Quick Test")
                    .font(.Orttaai.subheading)
                    .foregroundStyle(Color.Orttaai.textPrimary)

                Text("Click inside the field below. Hold \(hotkeyLabel), say something, then release.")
                    .font(.Orttaai.secondary)
                    .foregroundStyle(Color.Orttaai.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                ZStack(alignment: .topLeading) {
                    if quickTestText.isEmpty {
                        Text("Try saying: Hello from Orttaai")
                            .font(.Orttaai.body)
                            .foregroundStyle(Color.Orttaai.textTertiary)
                            .padding(.horizontal, Spacing.sm)
                            .padding(.vertical, Spacing.sm)
                    }

                    TextEditor(text: $quickTestText)
                        .font(.Orttaai.body)
                        .foregroundStyle(Color.Orttaai.textPrimary)
                        .scrollContentBackground(.hidden)
                        .padding(.horizontal, Spacing.xs)
                        .padding(.vertical, 2)
                        .background(Color.clear)
                }
                .frame(height: 88)
                .background(Color.Orttaai.bgSecondary)
                .clipShape(RoundedRectangle(cornerRadius: CornerRadius.input))
                .overlay(
                    RoundedRectangle(cornerRadius: CornerRadius.input)
                        .stroke(Color.Orttaai.border, lineWidth: BorderWidth.standard)
                )

                HStack(spacing: Spacing.xs) {
                    Image(systemName: statusIconName)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(statusColor)

                    Text(displayMessage)
                        .font(.Orttaai.secondary)
                        .foregroundStyle(statusColor)
                        .lineLimit(1)
                }
                .padding(.horizontal, Spacing.sm)
                .padding(.vertical, 6)
                .background(Color.Orttaai.bgSecondary)
                .clipShape(Capsule())
            }
            .frame(maxWidth: 420)

            Button("Start Using Orttaai") {
                onStart?()
            }
            .buttonStyle(OrttaaiButtonStyle(.primary))

            Text("After this, Orttaai stays in your menu bar.")
                .font(.Orttaai.caption)
                .foregroundStyle(Color.Orttaai.textTertiary)
        }
        .frame(maxWidth: .infinity)
        .onReceive(NotificationCenter.default.publisher(for: .dictationStateDidChange)) { notification in
            guard
                let rawState = notification.userInfo?[DictationNotificationKey.state] as? String,
                let state = DictationStateSignal(rawValue: rawState)
            else {
                return
            }

            quickTestState = state
            if state == .recording {
                hasDetectedHotkey = true
            }

            if let message = notification.userInfo?[DictationNotificationKey.message] as? String {
                quickTestMessage = message
            } else {
                quickTestMessage = fallbackMessage(for: state)
            }

            targetAppName = notification.userInfo?[DictationNotificationKey.targetAppName] as? String
            countdownSeconds = notification.userInfo?[DictationNotificationKey.countdownSeconds] as? Int
            elapsedRecordingSeconds = notification.userInfo?[DictationNotificationKey.elapsedRecordingSeconds] as? Int
            if let audioLevel = notification.userInfo?[DictationNotificationKey.audioLevel] as? Float {
                liveDictationLevel = max(0, min(audioLevel, 1))
            } else if state != .recording {
                liveDictationLevel = 0
            }

            updateMicMonitorForCurrentState()
        }
        .onReceive(NotificationCenter.default.publisher(for: shortcutChangeNotification)) { notification in
            guard
                let changedName = notification.userInfo?["name"] as? KeyboardShortcuts.Name,
                changedName.rawValue == KeyboardShortcuts.Name.pushToTalk.rawValue
            else {
                return
            }
            refreshHotkeyLabel()
        }
        .onAppear {
            refreshHotkeyLabel()
            audioDeviceManager.refreshDevices()
            updateMicMonitorForCurrentState()
        }
        .onDisappear {
            stopMicMonitor()
        }
        .onChange(of: selectedAudioDeviceID) { _, _ in
            audioDeviceManager.refreshDevices()
            updateMicMonitorForCurrentState(forceRestart: true)
        }
    }

    private var microphoneCheckCard: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack(alignment: .center, spacing: Spacing.sm) {
                Text("Microphone Check")
                    .font(.Orttaai.subheading)
                    .foregroundStyle(Color.Orttaai.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.9)
                    .layoutPriority(1)

                Spacer(minLength: Spacing.xs)

                Picker("Microphone input", selection: $selectedAudioDeviceID) {
                    Text(systemDefaultInputLabel)
                        .tag("")

                    ForEach(audioDeviceManager.devices) { device in
                        Text(device.name)
                            .tag(String(device.id))
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(width: 148, alignment: .trailing)

                Text(monitoringStateLabel)
                    .font(.Orttaai.caption)
                    .foregroundStyle(monitoringStateColor)
                    .padding(.horizontal, Spacing.sm)
                    .padding(.vertical, 6)
                    .background(monitoringStateColor.opacity(0.12))
                    .clipShape(Capsule())
            }

            HStack(spacing: Spacing.sm) {
                Label(activeMicName, systemImage: "mic.fill")
                    .font(.Orttaai.secondary)
                    .foregroundStyle(Color.Orttaai.textSecondary)
                    .lineLimit(1)

                AudioLevelMeter(level: displayedMicLevel)
                    .frame(width: 120, height: 8)
                    .accessibilityLabel("Microphone input level")
                    .accessibilityValue("\(Int((displayedMicLevel * 100).rounded())) percent")

                Spacer()

                Text("\(Int((displayedMicLevel * 100).rounded()))%")
                    .font(.Orttaai.mono)
                    .foregroundStyle(Color.Orttaai.accent)
            }

            if let micMonitorError {
                Text(micMonitorError)
                    .font(.Orttaai.caption)
                    .foregroundStyle(Color.Orttaai.error)
                    .lineLimit(2)
            } else {
                Text(microphoneCheckMessage)
                    .font(.Orttaai.caption)
                    .foregroundStyle(Color.Orttaai.textTertiary)
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, 10)
        .frame(maxWidth: 420, alignment: .leading)
        .background(Color.Orttaai.bgSecondary)
        .clipShape(RoundedRectangle(cornerRadius: CornerRadius.card))
        .accessibilityElement(children: .contain)
    }

    private var displayedMicLevel: Float {
        if quickTestState == .recording {
            return liveDictationLevel
        }
        return idleMicLevel
    }

    private var activeMicName: String {
        if selectedAudioDeviceID.isEmpty {
            return audioDeviceManager.defaultInputDevice()?.name ?? "System Default"
        }
        return audioDeviceManager.devices.first(where: { String($0.id) == selectedAudioDeviceID })?.name ?? "Selected microphone unavailable"
    }

    private var systemDefaultInputLabel: String {
        if let defaultInput = audioDeviceManager.defaultInputDevice() {
            return "System Default (\(defaultInput.name))"
        }
        return "System Default"
    }

    private var monitoringStateLabel: String {
        switch quickTestState {
        case .recording:
            return "Live"
        case .processing, .injecting:
            return "Paused"
        case .error:
            return "Check mic"
        case .idle:
            return micMonitorError == nil ? "Monitoring" : "Unavailable"
        }
    }

    private var monitoringStateColor: Color {
        switch quickTestState {
        case .recording:
            return Color.Orttaai.accent
        case .processing, .injecting:
            return Color.Orttaai.textSecondary
        case .error:
            return Color.Orttaai.error
        case .idle:
            return micMonitorError == nil ? Color.Orttaai.success : Color.Orttaai.warning
        }
    }

    private var microphoneCheckMessage: String {
        switch quickTestState {
        case .recording:
            return "Meter is now following the live dictation capture."
        case .processing, .injecting:
            return "Input monitoring pauses while Orttaai transcribes and pastes."
        case .error:
            return "If this stays flat, confirm macOS microphone access and the selected input device."
        case .idle:
            return "Speak normally to confirm the bar reacts before you start the quick test."
        }
    }

    private var displayMessage: String {
        if hasDetectedHotkey || quickTestState == .error {
            return quickTestMessage
        }
        return "Waiting for hotkey. Hold \(hotkeyLabel)."
    }

    private var feedbackSummary: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack(spacing: Spacing.sm) {
                statusPill(title: "State", value: stateTitle, tint: statusColor)

                if let targetAppName, !targetAppName.isEmpty {
                    statusPill(title: "Destination", value: targetAppName, tint: Color.Orttaai.accent)
                }

                if let elapsedRecordingSeconds, quickTestState == .recording {
                    statusPill(title: "Recorded", value: formattedDuration(elapsedRecordingSeconds), tint: Color.Orttaai.success)
                }

                if let countdownSeconds, quickTestState == .recording {
                    statusPill(title: "Time Left", value: "\(countdownSeconds)s", tint: Color.Orttaai.warning)
                }
            }

            Text("Orttaai pastes back into the app that was focused when you started recording.")
                .font(.Orttaai.caption)
                .foregroundStyle(Color.Orttaai.textTertiary)
        }
    }

    private var statusIconName: String {
        switch quickTestState {
        case .idle:
            return hasDetectedHotkey ? "checkmark.circle.fill" : "dot.radiowaves.left.and.right"
        case .recording:
            return "mic.fill"
        case .processing:
            return "waveform"
        case .injecting:
            return "arrow.down.doc.fill"
        case .error:
            return "exclamationmark.triangle.fill"
        }
    }

    private var statusColor: Color {
        switch quickTestState {
        case .recording:
            return Color.Orttaai.accent
        case .processing, .injecting:
            return Color.Orttaai.textSecondary
        case .error:
            return Color.Orttaai.error
        case .idle:
            return hasDetectedHotkey ? Color.Orttaai.success : Color.Orttaai.textTertiary
        }
    }

    private var stateTitle: String {
        switch quickTestState {
        case .idle:
            return hasDetectedHotkey ? "Ready" : "Waiting"
        case .recording:
            return "Listening"
        case .processing:
            return "Transcribing"
        case .injecting:
            return "Pasting"
        case .error:
            return "Error"
        }
    }

    private func fallbackMessage(for state: DictationStateSignal) -> String {
        switch state {
        case .idle:
            return "Ready"
        case .recording:
            return "Listening... Speak now."
        case .processing:
            return "Transcribing..."
        case .injecting:
            return "Pasting text..."
        case .error:
            return "Dictation failed. Try again."
        }
    }

    private func refreshHotkeyLabel() {
        guard let shortcut = KeyboardShortcuts.getShortcut(for: .pushToTalk) else {
            hotkeyLabel = "Ctrl + Shift + Space"
            return
        }
        hotkeyLabel = formatShortcut(shortcut)
    }

    private func formattedDuration(_ seconds: Int) -> String {
        let minutes = seconds / 60
        let remainingSeconds = seconds % 60
        return String(format: "%d:%02d", minutes, remainingSeconds)
    }

    private func formatShortcut(_ shortcut: KeyboardShortcuts.Shortcut) -> String {
        var parts: [String] = []
        if shortcut.modifiers.contains(.control) {
            parts.append("Ctrl")
        }
        if shortcut.modifiers.contains(.shift) {
            parts.append("Shift")
        }
        if shortcut.modifiers.contains(.option) {
            parts.append("Option")
        }
        if shortcut.modifiers.contains(.command) {
            parts.append("Cmd")
        }

        parts.append(displayName(for: shortcut.key))
        return parts.joined(separator: " + ")
    }

    private func displayName(for key: KeyboardShortcuts.Key?) -> String {
        guard let key else {
            return "Space"
        }

        let bareShortcut = KeyboardShortcuts.Shortcut(key, modifiers: [])
        if let keyEquivalent = bareShortcut.nsMenuItemKeyEquivalent {
            switch keyEquivalent {
            case " ":
                return "Space"
            case "\t":
                return "Tab"
            case "\r":
                return "Return"
            default:
                return keyEquivalent.uppercased()
            }
        }

        return "Key \(key.rawValue)"
    }

    private func updateMicMonitorForCurrentState(forceRestart: Bool = false) {
        let shouldMonitorIdleInput = quickTestState == .idle

        if !shouldMonitorIdleInput {
            stopMicMonitor()
            return
        }

        if forceRestart {
            stopMicMonitor()
        }

        guard micMonitorCapture == nil else { return }
        startMicMonitor()
    }

    private func startMicMonitor() {
        stopMicMonitor()

        let capture = AudioCaptureService()
        micMonitorError = nil

        do {
            let selectedDeviceID = resolvedSelectedAudioDeviceID()
            try capture.startCapture(deviceID: selectedDeviceID)
            if let selectedDeviceID,
               let activeDeviceID = capture.activeInputDeviceID,
               activeDeviceID != selectedDeviceID {
                Logger.audio.warning(
                    "Ready-step monitor requested device \(selectedDeviceID), but active input is \(activeDeviceID)."
                )
                micMonitorError = "Selected mic could not be activated. Check Audio settings."
            }
            micMonitorCapture = capture
            micLevelTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { _ in
                idleMicLevel = capture.audioLevel
            }
        } catch {
            micMonitorCapture = nil
            micMonitorError = "Mic check unavailable. Open Audio settings if the bar stays flat."
            idleMicLevel = 0
            Logger.audio.error("Ready step mic monitor failed: \(error.localizedDescription)")
        }
    }

    private func stopMicMonitor() {
        micLevelTimer?.invalidate()
        micLevelTimer = nil

        _ = micMonitorCapture?.stopCapture()
        micMonitorCapture = nil
        idleMicLevel = 0
    }

    private func resolvedSelectedAudioDeviceID() -> AudioDeviceID? {
        let trimmed = selectedAudioDeviceID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let rawID = UInt32(trimmed), rawID != 0 else {
            selectedAudioDeviceID = ""
            return nil
        }

        let requested = AudioDeviceID(rawID)
        let stillAvailable = audioDeviceManager.devices.contains(where: { $0.id == requested })
        guard stillAvailable else {
            Logger.audio.warning("Setup-selected input device \(rawID) unavailable; reverting to system default")
            selectedAudioDeviceID = ""
            return nil
        }

        return requested
    }

    private func statusPill(title: String, value: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title.uppercased())
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(Color.Orttaai.textTertiary)
            Text(value)
                .font(.Orttaai.secondary)
                .foregroundStyle(Color.Orttaai.textPrimary)
        }
        .padding(.horizontal, Spacing.sm)
        .padding(.vertical, 5)
        .background(tint.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: CornerRadius.card))
        .overlay(
            RoundedRectangle(cornerRadius: CornerRadius.card)
                .stroke(tint.opacity(0.22), lineWidth: BorderWidth.standard)
        )
    }
}
