// ProcessingIndicatorView.swift
// Orttaai

import SwiftUI

struct ProcessingIndicatorView: View {
    let estimateText: String?
    let errorMessage: String?

    @State private var shimmerOffset: CGFloat = -1

    var body: some View {
        HStack(spacing: Spacing.sm) {
            if let errorMessage = errorMessage {
                errorView(message: errorMessage)
            } else {
                shimmerView
                Text(estimateText ?? "Processing...")
                    .font(.Orttaai.secondary)
                    .foregroundStyle(Color.Orttaai.textSecondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: 24)
        .padding(.horizontal, 8)
        .onAppear {
            if errorMessage == nil {
                withAnimation(.easeInOut(duration: 1.5).repeatForever(autoreverses: true)) {
                    shimmerOffset = 1
                }
            }
        }
    }

    private var shimmerView: some View {
        RoundedRectangle(cornerRadius: 3)
            .fill(
                LinearGradient(
                    colors: [
                        Color.Orttaai.accent.opacity(0.3),
                        Color.Orttaai.accent.opacity(0.8),
                        Color.Orttaai.accent.opacity(0.3)
                    ],
                    startPoint: UnitPoint(x: shimmerOffset, y: 0.5),
                    endPoint: UnitPoint(x: shimmerOffset + 0.5, y: 0.5)
                )
            )
            .frame(width: 28, height: 5)
    }

    private func errorView(message: String) -> some View {
        HStack(spacing: Spacing.xs) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 14))
                .foregroundStyle(Color.Orttaai.warning)
            Text(message)
                .font(.Orttaai.secondary)
                .foregroundStyle(Color.Orttaai.error)
        }
    }
}
