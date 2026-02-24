// PerformanceHealthCard.swift
// Orttaai

import SwiftUI

struct PerformanceHealthCard: View {
    let health: DashboardPerformanceHealth

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            HStack {
                Text("Performance Health")
                    .font(.Orttaai.subheading)
                    .foregroundStyle(Color.Orttaai.textPrimary)

                Spacer()

                Text(levelLabel)
                    .font(.Orttaai.caption)
                    .foregroundStyle(levelColor)
                    .padding(.horizontal, Spacing.sm)
                    .padding(.vertical, Spacing.xs)
                    .background(levelColor.opacity(0.15))
                    .clipShape(Capsule())
            }

            LazyVGrid(
                columns: [
                    GridItem(.flexible(), spacing: Spacing.md),
                    GridItem(.flexible(), spacing: Spacing.md)
                ],
                spacing: Spacing.md
            ) {
                metricCell(title: "Avg Processing", value: processingLabel)
                metricCell(title: "Status", value: levelLabel)
                metricCell(title: "Current Model", value: health.currentModelId, isMonospaced: true)
                metricCell(title: "Guidance", value: guidanceLabel)
            }
        }
        .padding(Spacing.lg)
        .frame(maxWidth: .infinity, minHeight: 228, alignment: .leading)
        .dashboardCard()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            "Performance health \(levelLabel). Average processing \(processingLabel). Current model \(health.currentModelId). Recommendation: \(health.recommendation)"
        )
    }

    private var processingLabel: String {
        guard let averageProcessingMs = health.averageProcessingMs else {
            return "No data"
        }
        return "\(averageProcessingMs) ms"
    }

    private var levelLabel: String {
        switch health.level {
        case .noData: return "No Data"
        case .fast: return "Fast"
        case .normal: return "Normal"
        case .slow: return "Slow"
        }
    }

    private var levelColor: Color {
        switch health.level {
        case .noData: return Color.Orttaai.textTertiary
        case .fast: return Color.Orttaai.success
        case .normal: return Color.Orttaai.warning
        case .slow: return Color.Orttaai.error
        }
    }

    private var guidanceLabel: String {
        switch health.level {
        case .noData: return "Need more dictations"
        case .fast: return "Keep current model"
        case .normal: return "Smaller model for speed"
        case .slow: return "Switch to smaller model"
        }
    }

    private func metricCell(
        title: String,
        value: String,
        isMonospaced: Bool = false
    ) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Text(title)
                .font(.Orttaai.secondary)
                .foregroundStyle(Color.Orttaai.textSecondary)

            Text(value)
                .font(isMonospaced ? .Orttaai.mono : .Orttaai.heading)
                .foregroundStyle(Color.Orttaai.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.Orttaai.bgPrimary)
        .clipShape(RoundedRectangle(cornerRadius: CornerRadius.card))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title) \(value)")
    }
}
