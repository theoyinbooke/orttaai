// TrendCardView.swift
// Orttaai

import SwiftUI
import Charts

struct TrendCardView: View {
    var title = "30-Day Trend"
    let points: [DashboardTrendPoint]
    /// Totals across all your history, as a quiet line beside the title.
    var allTime: DashboardHeaderStats?
    let showsLegend: Bool
    var axisTickCount = 8
    var emptyMessage = "No activity yet. Your last 30 days will appear after you dictate."

    /// The day under the pointer, for the tooltip.
    @State private var hoveredDay: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.md) {
                Text(title)
                    .font(.Orttaai.subheading)
                    .foregroundStyle(Color.Orttaai.textPrimary)
                Spacer(minLength: 0)
                if let allTime, allTime.activeDays > 0 {
                    Text(allTimeLine(allTime))
                        .font(.Orttaai.caption)
                        .foregroundStyle(Color.Orttaai.textTertiary)
                        .monospacedDigit()
                        .lineLimit(1)
                        .truncationMode(.head)
                        .help("Since your first dictation")
                        .accessibilityLabel(
                            "All time: \(allTime.totalWords) words over \(allTime.activeDays) active days, average \(allTime.averageWPM) words per minute."
                        )
                }
            }

            if hasNoTrendData {
                Text(emptyMessage)
                    .font(.Orttaai.secondary)
                    .foregroundStyle(Color.Orttaai.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, Spacing.lg)
            } else {
                Chart {
                    ForEach(points) { point in
                        // Words per day as a soft area, average WPM as a line over it.
                        AreaMark(
                            x: .value("Day", point.dayStart, unit: .day),
                            y: .value("Words", point.words)
                        )
                        .foregroundStyle(
                            LinearGradient(
                                colors: [Color.Orttaai.accent.opacity(0.32), Color.Orttaai.accent.opacity(0.02)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .interpolationMethod(.monotone)

                        LineMark(
                            x: .value("Day", point.dayStart, unit: .day),
                            y: .value("Words", point.words),
                            series: .value("Series", "Words")
                        )
                        .foregroundStyle(Color.Orttaai.accent.opacity(0.45))
                        .lineStyle(.init(lineWidth: 1.5))
                        .interpolationMethod(.monotone)

                        LineMark(
                            x: .value("Day", point.dayStart, unit: .day),
                            y: .value("WPM", point.averageWPM),
                            series: .value("Series", "WPM")
                        )
                        .foregroundStyle(Color.Orttaai.accent)
                        .lineStyle(.init(lineWidth: 2))
                        .interpolationMethod(.monotone)
                    }

                    if let hovered = hoveredPoint {
                        RuleMark(x: .value("Day", hovered.dayStart, unit: .day))
                            .foregroundStyle(Color.Orttaai.textTertiary.opacity(0.6))
                            .lineStyle(.init(lineWidth: 1, dash: [3, 3]))
                            .annotation(
                                position: .top,
                                spacing: 4,
                                overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))
                            ) {
                                tooltip(for: hovered)
                            }

                        PointMark(
                            x: .value("Day", hovered.dayStart, unit: .day),
                            y: .value("Words", hovered.words)
                        )
                        .foregroundStyle(Color.Orttaai.accent.opacity(0.6))
                        .symbolSize(36)

                        PointMark(
                            x: .value("Day", hovered.dayStart, unit: .day),
                            y: .value("WPM", hovered.averageWPM)
                        )
                        .foregroundStyle(Color.Orttaai.accent)
                        .symbolSize(48)
                    }
                }
                .chartXSelection(value: $hoveredDay)
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: axisTickCount)) { value in
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                            .foregroundStyle(Color.Orttaai.border.opacity(0.35))
                        AxisTick(stroke: StrokeStyle(lineWidth: 0.5))
                            .foregroundStyle(Color.Orttaai.border.opacity(0.5))
                        AxisValueLabel(format: .dateTime.month(.abbreviated).day())
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
                // New data is drawn straight away. Animated, Swift Charts gave
                // its axis labels negative sizes on every frame of the change
                // (about 100 "Invalid frame dimension" warnings for each range
                // or device click), and drawing every frame was seven times
                // the work of drawing the chart once.
                .transaction { $0.animation = nil }
                .accessibilityLabel("\(title) chart")
                .accessibilityValue(trendAccessibilitySummary)

                if showsLegend {
                    HStack(spacing: Spacing.lg) {
                        legendDot(color: Color.Orttaai.accent.opacity(0.35), label: "Words/day")
                        legendDot(color: Color.Orttaai.accent, label: "Avg WPM/day")
                    }
                }
            }
        }
        .padding(Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .dashboardCard()
        .accessibilityElement(children: .contain)
    }

    private var hoveredPoint: DashboardTrendPoint? {
        guard let hoveredDay else { return nil }
        let calendar = Calendar.current
        return points.first { calendar.isDate($0.dayStart, inSameDayAs: hoveredDay) }
    }

    private func tooltip(for point: DashboardTrendPoint) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(point.dayStart, format: .dateTime.weekday(.abbreviated).month(.abbreviated).day())
                .font(.Orttaai.caption)
                .foregroundStyle(Color.Orttaai.textTertiary)
            if point.sessions == 0 {
                Text("No dictation")
                    .font(.Orttaai.secondary)
                    .foregroundStyle(Color.Orttaai.textSecondary)
            } else {
                tooltipRow(color: Color.Orttaai.accent.opacity(0.35), value: point.words, unit: point.words == 1 ? "word" : "words")
                tooltipRow(color: Color.Orttaai.accent, value: point.averageWPM, unit: "WPM")
                Text(point.sessions == 1 ? "1 session" : "\(point.sessions) sessions")
                    .font(.Orttaai.caption)
                    .foregroundStyle(Color.Orttaai.textTertiary)
            }
        }
        .padding(.horizontal, Spacing.sm)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.Orttaai.bgSecondary)
                .shadow(color: .black.opacity(0.25), radius: 8, y: 3)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.Orttaai.border.opacity(0.6), lineWidth: 1)
        )
    }

    private func tooltipRow(color: Color, value: Int, unit: String) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
            Text(value.formatted())
                .font(.Orttaai.secondary)
                .foregroundStyle(Color.Orttaai.textPrimary)
                .monospacedDigit()
            Text(unit)
                .font(.Orttaai.caption)
                .foregroundStyle(Color.Orttaai.textTertiary)
        }
    }

    private func allTimeLine(_ stats: DashboardHeaderStats) -> String {
        let words = "\(stats.totalWords.formatted()) \(stats.totalWords == 1 ? "word" : "words")"
        let days = "\(stats.activeDays.formatted()) \(stats.activeDays == 1 ? "day" : "days")"
        return "All time · \(words) · \(days) · \(stats.averageWPM) WPM"
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
