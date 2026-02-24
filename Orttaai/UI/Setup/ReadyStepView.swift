// ReadyStepView.swift
// Orttaai

import SwiftUI
import KeyboardShortcuts

struct ReadyStepView: View {
    var onStart: (() -> Void)?
    @State private var quickTestText = ""
    @State private var quickTestState: DictationStateSignal = .idle
    @State private var quickTestMessage = "Waiting for hotkey."
    @State private var hasDetectedHotkey = false
    @State private var hotkeyLabel = "Ctrl + Space"
    private let shortcutChangeNotification = Notification.Name("KeyboardShortcuts_shortcutByNameDidChange")

    var body: some View {
        VStack(spacing: Spacing.xl) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(Color.Orttaai.success)

            Text("Orttaai is ready!")
                .font(.Orttaai.title)
                .foregroundStyle(Color.Orttaai.textPrimary)

            VStack(spacing: Spacing.sm) {
                Text("Press")
                    .font(.Orttaai.body)
                    .foregroundStyle(Color.Orttaai.textSecondary)

                Text(hotkeyLabel)
                    .font(.Orttaai.mono)
                    .foregroundStyle(Color.Orttaai.accent)
                    .padding(.horizontal, Spacing.lg)
                    .padding(.vertical, Spacing.sm)
                    .background(Color.Orttaai.bgSecondary)
                    .clipShape(RoundedRectangle(cornerRadius: CornerRadius.card))

                Text("anywhere to start dictating.")
                    .font(.Orttaai.body)
                    .foregroundStyle(Color.Orttaai.textSecondary)
            }

                Text("Hold the hotkey while speaking, then release to transcribe and paste.")
                    .font(.Orttaai.secondary)
                    .foregroundStyle(Color.Orttaai.textTertiary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 400)

            VStack(alignment: .leading, spacing: Spacing.sm) {
                Text("Quick Test")
                    .font(.Orttaai.subheading)
                    .foregroundStyle(Color.Orttaai.textPrimary)

                Text("Click inside the field below. Hold \(hotkeyLabel), say something, then release.")
                    .font(.Orttaai.secondary)
                    .foregroundStyle(Color.Orttaai.textSecondary)

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
                        .padding(.vertical, Spacing.xs)
                        .background(Color.clear)
                }
                .frame(height: 110)
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
                }
                .padding(.horizontal, Spacing.sm)
                .padding(.vertical, Spacing.xs)
                .background(Color.Orttaai.bgSecondary)
                .clipShape(Capsule())
            }
            .frame(maxWidth: 420)

            Button("Start Using Orttaai") {
                onStart?()
            }
            .buttonStyle(OrttaaiButtonStyle(.primary))
            .padding(.top, Spacing.lg)

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
        }
    }

    private var displayMessage: String {
        if hasDetectedHotkey || quickTestState == .error {
            return quickTestMessage
        }
        return "Waiting for hotkey. Hold \(hotkeyLabel)."
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
}
