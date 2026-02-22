// ReadyStepView.swift
// Uttrai

import SwiftUI

struct ReadyStepView: View {
    var onStart: (() -> Void)?

    var body: some View {
        VStack(spacing: Spacing.xl) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(Color.Uttrai.success)

            Text("Uttrai is ready!")
                .font(.Uttrai.title)
                .foregroundStyle(Color.Uttrai.textPrimary)

            VStack(spacing: Spacing.sm) {
                Text("Press")
                    .font(.Uttrai.body)
                    .foregroundStyle(Color.Uttrai.textSecondary)

                Text("Ctrl + Shift + Space")
                    .font(.Uttrai.mono)
                    .foregroundStyle(Color.Uttrai.accent)
                    .padding(.horizontal, Spacing.lg)
                    .padding(.vertical, Spacing.sm)
                    .background(Color.Uttrai.bgSecondary)
                    .clipShape(RoundedRectangle(cornerRadius: CornerRadius.card))

                Text("anywhere to start dictating.")
                    .font(.Uttrai.body)
                    .foregroundStyle(Color.Uttrai.textSecondary)
            }

            Text("Hold the hotkey while speaking, then release to transcribe and paste.")
                .font(.Uttrai.secondary)
                .foregroundStyle(Color.Uttrai.textTertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)

            Button("Start Using Uttrai") {
                onStart?()
            }
            .buttonStyle(UttraiButtonStyle(.primary))
            .padding(.top, Spacing.lg)
        }
        .frame(maxWidth: .infinity)
    }
}
