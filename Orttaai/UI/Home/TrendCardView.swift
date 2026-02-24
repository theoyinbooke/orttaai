// TrendCardView.swift
// Orttaai

import SwiftUI
import Charts

struct TrendCardView: View {
    let points: [DashboardTrendPoint]
    let showsLegend: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            Text("7-Day Trend")
                .font(.Orttaai.subheading)
                .foregroundStyle(Color.Orttaai.textPrimary)

            if hasNoTrendData {
                Text("No activity yet. Your last 7 days will appear after you dictate.")
                    .font(.Orttaai.secondary)
                    .foregroundStyle(Color.Orttaai.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, Spacing.lg)
            } else {
                Chart(points) { point in
                    BarMark(
                        x: .value("Day", point.dayStart, unit: .day),
                        y: .value("Words", point.words)
                    )
                    .foregroundStyle(Color.Orttaai.accentSubtle)

                    LineMark(
                        x: .value("Day", point.dayStart, unit: .day),
                        y: .value("WPM", point.averageWPM)
                    )
                    .foregroundStyle(Color.Orttaai.accent)
                    .lineStyle(.init(lineWidth: 2))

                    PointMark(
                        x: .value("Day", point.dayStart, unit: .day),
                        y: .value("WPM", point.averageWPM)
                    )
                    .foregroundStyle(Color.Orttaai.accent)
                }
                .chartXAxis {
                    AxisMarks(values: .stride(by: .day)) { value in
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                            .foregroundStyle(Color.Orttaai.border.opacity(0.35))
                        AxisTick(stroke: StrokeStyle(lineWidth: 0.5))
                            .foregroundStyle(Color.Orttaai.border.opacity(0.5))
                        AxisValueLabel(format: .dateTime.weekday(.abbreviated))
                            .foregroundStyle(Color.Orttaai.textTertiary)
                            .font(.Orttaai.caption)
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading) { value in
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                            .foregroundStyle(Color.Orttaai.border.opacity(0.35))
                        AxisValueLabel {
                            if let intValue = value.as(Int.self) {
                                Text(intValue.formatted())
                                    .font(.Orttaai.caption)
                                    .foregroundStyle(Color.Orttaai.textTertiary)
                            }
                        }
                    }
                }
                .frame(height: 210)
                .accessibilityLabel("7-day trend chart")
                .accessibilityValue(trendAccessibilitySummary)

                if showsLegend {
                    HStack(spacing: Spacing.lg) {
                        legendDot(color: Color.Orttaai.accentSubtle, label: "Words/day")
                        legendDot(color: Color.Orttaai.accent, label: "Avg WPM/day")
                    }
                }
            }
        }
        .padding(Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .dashboardCard()
        .accessibilityElement(children: .contain)
    }

    private var hasNoTrendData: Bool {
        points.allSatisfy { $0.words == 0 && $0.sessions == 0 }
    }

    private func legendDot(color: Color, label: String) -> some View {
        HStack(spacing: Spacing.xs) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(label)
                .font(.Orttaai.caption)
                .foregroundStyle(Color.Orttaai.textSecondary)
        }
    }

    private var trendAccessibilitySummary: String {
        let totalWords = points.reduce(0) { $0 + $1.words }
        let spokenDays = points.filter { $0.sessions > 0 }.count
        let averageWPM = points
            .filter { $0.sessions > 0 }
            .map(\.averageWPM)
        let meanWPM: Int
        if averageWPM.isEmpty {
            meanWPM = 0
        } else {
            meanWPM = Int((Double(averageWPM.reduce(0, +)) / Double(averageWPM.count)).rounded())
        }
        return "\(spokenDays) active days, \(totalWords) total words, average \(meanWPM) words per minute."
    }
}
