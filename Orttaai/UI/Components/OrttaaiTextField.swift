// OrttaaiTextField.swift
// Orttaai

import SwiftUI

struct OrttaaiTextField: View {
    let placeholder: String
    @Binding var text: String
    @FocusState private var isFocused: Bool

    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.plain)
            .font(.Orttaai.body)
            .foregroundStyle(Color.Orttaai.textPrimary)
            .padding(.horizontal, Spacing.sm)
            .padding(.vertical, Spacing.sm)
            .background(Color.Orttaai.bgSecondary)
            .clipShape(RoundedRectangle(cornerRadius: CornerRadius.input))
            .overlay(
                RoundedRectangle(cornerRadius: CornerRadius.input)
                    .stroke(
                        isFocused ? Color.Orttaai.accent : Color.Orttaai.border,
                        lineWidth: BorderWidth.standard
                    )
            )
            .focused($isFocused)
    }
}
