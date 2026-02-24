// StatChipView.swift
// Orttaai

import SwiftUI

struct StatChipView: View {
    let label: String
    let value: String

    var body: some View {
        HStack(spacing: Spacing.xs) {
            Text(value)
                .font(.Orttaai.bodyMedium)
                .foregroundStyle(Color.Orttaai.textPrimary)
            Text(label)
                .font(.Orttaai.secondary)
                .foregroundStyle(Color.Orttaai.textSecondary)
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.sm)
        .background(Color.Orttaai.bgSecondary)
        .clipShape(Capsule())
        .overlay(
            Capsule()
                .stroke(Color.Orttaai.border, lineWidth: BorderWidth.standard)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label) \(value)")
    }
}
