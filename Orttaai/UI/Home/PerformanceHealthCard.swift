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

                if health.sampleCount > 0 {
                    Text("\(health.sampleCount) samples")
                        .font(.Orttaai.caption)
                        .foregroundStyle(Color.Orttaai.textTertiary)
                }

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
                metricCell(title: "Pipeline", value: averageLatencySummary(health.averageProcessingMs))
                metricCell(title: "Transcribe", value: averageLatencySummary(health.averageTranscriptionMs))
                metricCell(title: "Inject", value: averageLatencySummary(health.averageInjectionMs))
                metricCell(title: "Current Model", value: health.currentModelId, isMonospaced: true)
            }
        }
        .padding(Spacing.lg)
        .frame(maxWidth: .infinity, minHeight: 228, alignment: .leading)
        .dashboardCard()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            "Performance health \(levelLabel). Pipeline \(averageLatencySummary(health.averageProcessingMs)). Transcription \(averageLatencySummary(health.averageTranscriptionMs)). Injection \(averageLatencySummary(health.averageInjectionMs)). Current model \(health.currentModelId)."
        )
    }

    private func averageLatencySummary(_ average: Int?) -> String {
        guard let average else {
            return "No data"
        }
        return "Avg \(average) ms"
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
                .lineLimit(isMonospaced ? 1 : 2)
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
