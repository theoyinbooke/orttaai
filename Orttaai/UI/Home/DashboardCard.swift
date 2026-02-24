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
            .shadow(color: .black.opacity(0.16), radius: 8, y: 4)
    }
}

extension View {
    func dashboardCard() -> some View {
        modifier(DashboardCardModifier())
    }
}

struct DashboardSkeletonBlock: View {
    let width: CGFloat?
    let height: CGFloat
    let cornerRadius: CGFloat

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shimmerOffset: CGFloat = -1

    init(width: CGFloat? = nil, height: CGFloat, cornerRadius: CGFloat = CornerRadius.card) {
        self.width = width
        self.height = height
        self.cornerRadius = cornerRadius
    }

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(Color.Orttaai.bgTertiary.opacity(0.8))
            .overlay {
                if !reduceMotion {
                    GeometryReader { geometry in
                        LinearGradient(
                            colors: [
                                Color.clear,
                                Color.white.opacity(0.22),
                                Color.clear
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                        .frame(width: max(geometry.size.width, 1) * 0.4)
                        .offset(x: shimmerOffset * max(geometry.size.width, 1) * 1.6)
                        .blendMode(.plusLighter)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                }
            }
            .frame(width: width, height: height)
            .onAppear {
                guard !reduceMotion else { return }
                shimmerOffset = -1
                withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) {
                    shimmerOffset = 1
                }
            }
    }
}
