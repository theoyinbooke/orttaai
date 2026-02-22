// UttraiTextField.swift
// Uttrai

import SwiftUI

struct UttraiTextField: View {
    let placeholder: String
    @Binding var text: String
    @FocusState private var isFocused: Bool

    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.plain)
            .font(.Uttrai.body)
            .foregroundStyle(Color.Uttrai.textPrimary)
            .padding(.horizontal, Spacing.sm)
            .padding(.vertical, Spacing.sm)
            .background(Color.Uttrai.bgSecondary)
            .clipShape(RoundedRectangle(cornerRadius: CornerRadius.input))
            .overlay(
                RoundedRectangle(cornerRadius: CornerRadius.input)
                    .stroke(
                        isFocused ? Color.Uttrai.accent : Color.Uttrai.border,
                        lineWidth: BorderWidth.standard
                    )
            )
            .focused($isFocused)
    }
}
