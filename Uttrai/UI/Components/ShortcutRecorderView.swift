// ShortcutRecorderView.swift
// Uttrai

import SwiftUI
import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    static let pushToTalk = Self("pushToTalk", default: .init(.space, modifiers: [.control, .shift]))
    static let pasteLastTranscript = Self("pasteLastTranscript")
}

struct ShortcutRecorderView: View {
    let name: KeyboardShortcuts.Name
    let label: String

    var body: some View {
        HStack(spacing: Spacing.sm) {
            Text(label)
                .font(.Uttrai.body)
                .foregroundStyle(Color.Uttrai.textPrimary)

            Spacer()

            KeyboardShortcuts.Recorder(for: name)
                .padding(.horizontal, Spacing.sm)
                .padding(.vertical, Spacing.xs)
                .background(Color.Uttrai.bgSecondary)
                .clipShape(RoundedRectangle(cornerRadius: CornerRadius.input))
                .overlay(
                    RoundedRectangle(cornerRadius: CornerRadius.input)
                        .stroke(Color.Uttrai.border, lineWidth: 1)
                )
        }
    }
}
