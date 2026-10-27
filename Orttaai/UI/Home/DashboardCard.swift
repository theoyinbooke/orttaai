// DashboardCard.swift
// Orttaai

import SwiftUI

struct DashboardCardModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: CornerRadius.card, style: .continuous)
                    .fill(Color.Orttaai.bgSecondary)
            )
            .overlay(
                RoundedRectangle(cornerRadius: CornerRadius.card, style: .continuous)
                    .stroke(Color.Orttaai.border, lineWidth: BorderWidth.standard)
            )
        // No drop shadow: on the dark background it barely showed, and a
        // blurred shadow on every card had to be recomputed while scrolling.
    }
}

extension View {
    func dashboardCard() -> some View {
        modifier(DashboardCardModifier())
    }
}
