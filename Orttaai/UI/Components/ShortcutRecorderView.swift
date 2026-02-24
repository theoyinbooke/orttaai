// ShortcutRecorderView.swift
// Orttaai

import SwiftUI
import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    static let pushToTalk = Self("pushToTalk")
    static let pasteLastTranscript = Self("pasteLastTranscript")
}

struct ShortcutRecorderView: View {
    let name: KeyboardShortcuts.Name
    let label: String

    var body: some View {
        HStack(spacing: Spacing.sm) {
            Text(label)
                .font(.Orttaai.body)
                .foregroundStyle(Color.Orttaai.textPrimary)

            Spacer()

            KeyboardShortcuts.Recorder(for: name)
                .padding(.horizontal, Spacing.sm)
                .padding(.vertical, Spacing.xs)
                .background(Color.Orttaai.bgSecondary)
                .clipShape(RoundedRectangle(cornerRadius: CornerRadius.input))
                .overlay(
                    RoundedRectangle(cornerRadius: CornerRadius.input)
                        .stroke(Color.Orttaai.border, lineWidth: 1)
                )
        }
    }
}
