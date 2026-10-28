// PerformanceHealthCard.swift
// Orttaai

import SwiftUI

/// How long a dictation takes after you stop speaking, and where that time
/// goes: one bar split into transcription, rules and polish (dictionary,
/// formatting, Polish), and insertion, with the engine underneath. Typical
/// (median) times of the latest dictations, so a change shows within a day
/// and one slow dictation doesn't skew it.
struct PerformanceHealthCard: View {
    let health: DashboardPerformanceHealth

    private struct Segment: Identifiable {
        let id: String
        let label: String
        let ms: Int
        let p95: Int?
        let color: Color
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            HStack(alignment: .firstTextBaseline) {
                Text("Performance")
                    .font(.Orttaai.subheading)
                    .foregroundStyle(Color.Orttaai.textPrimary)
                Spacer()
                Text(levelLabel)
                    .font(.Orttaai.caption)
                    .foregroundStyle(levelColor)
                    .padding(.horizontal, Spacing.sm)
                    .padding(.vertical, 2)
                    .background(levelColor.opacity(0.15), in: Capsule())
            }

            if let total = health.processingP50Ms {
                VStack(alignment: .leading, spacing: Spacing.sm) {
                    HStack(alignment: .firstTextBaseline, spacing: Spacing.sm) {
                        Text("\(total)")
                            .font(.system(size: 34, weight: .semibold, design: .rounded))
                            .foregroundStyle(Color.Orttaai.textPrimary)
                            .monospacedDigit()
                        Text("ms per dictation")
                            .font(.Orttaai.body)
                            .foregroundStyle(Color.Orttaai.textSecondary)
                        Spacer()
                        Text(health.sampleCount == 1 ? "Last dictation" : "Last \(health.sampleCount) dictations")
                            .font(.Orttaai.caption)
                            .foregroundStyle(Color.Orttaai.textTertiary)
                    }
                    breakdownBar
                    legend
                }
            } else {
                // Same three parts as with data, so the card keeps its shape.
                VStack(alignment: .leading, spacing: Spacing.sm) {
                    HStack(alignment: .firstTextBaseline, spacing: Spacing.sm) {
                        Text("–")
                            .font(.system(size: 34, weight: .semibold, design: .rounded))
                            .foregroundStyle(Color.Orttaai.textTertiary)
                        Text("ms per dictation")
                            .font(.Orttaai.body)
                            .foregroundStyle(Color.Orttaai.textSecondary)
                    }
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(Color.Orttaai.textTertiary.opacity(0.35))
                        .frame(height: 8)
                    Text("Timings appear after your first dictation")
                        .font(.Orttaai.caption)
                        .foregroundStyle(Color.Orttaai.textSecondary)
                }
            }

            Spacer(minLength: 0)

            engineRow
        }
        .padding(Spacing.md)
        .frame(maxWidth: .infinity, minHeight: 188, alignment: .leading)
        .dashboardCard()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            "Performance \(levelLabel). \(statusDescription) Pipeline \(summary(health.processingP50Ms)). Transcription \(summary(health.transcriptionP50Ms)). Rules and polish \(summary(health.textProcessingP50Ms)). Insertion \(summary(health.injectionP50Ms)). Current model \(modelDisplayName)."
        )
    }

    // MARK: - Breakdown

    /// Each stage's own typical time, in the order a dictation goes through
    /// them. Medians of the parts needn't add up to the median total.
    private var segments: [Segment] {
        [
            Segment(id: "transcribe", label: "Transcribe", ms: health.transcriptionP50Ms ?? 0, p95: health.transcriptionP95Ms, color: Color.Orttaai.accent),
            Segment(id: "polish", label: "Rules & polish", ms: health.textProcessingP50Ms ?? 0, p95: health.textProcessingP95Ms, color: Color.Orttaai.textTertiary.opacity(0.6)),
            Segment(id: "inject", label: "Insert", ms: health.injectionP50Ms ?? 0, p95: health.injectionP95Ms, color: Color.Orttaai.accent.opacity(0.45)),
        ].filter { $0.ms > 0 }
    }

    private var breakdownBar: some View {
        GeometryReader { geometry in
            let parts = segments
            let sum = max(1, parts.reduce(0) { $0 + $1.ms })
            let gaps = CGFloat(max(0, parts.count - 1)) * 2
            HStack(spacing: 2) {
                ForEach(parts) { part in
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(part.color)
                        .frame(width: max(4, (geometry.size.width - gaps) * CGFloat(part.ms) / CGFloat(sum)))
                }
            }
        }
        .frame(height: 8)
        .accessibilityHidden(true)
    }

    private var legend: some View {
        HStack(spacing: Spacing.md) {
            ForEach(segments) { part in
                HStack(spacing: 5) {
                    Circle()
                        .fill(part.color)
                        .frame(width: 7, height: 7)
                    Text(part.label)
                        .font(.Orttaai.caption)
                        .foregroundStyle(Color.Orttaai.textSecondary)
                    Text("\(part.ms) ms")
                        .font(.Orttaai.caption)
                        .foregroundStyle(Color.Orttaai.textPrimary)
                        .monospacedDigit()
                }
                .help(part.p95.map { "\(part.label): typically \(part.ms) ms, \($0) ms in the slowest 1 in 20" } ?? "\(part.label): typically \(part.ms) ms")
            }
        }
        .lineLimit(1)
    }

    // MARK: - Engine

    private var engineRow: some View {
        HStack(spacing: 7) {
            Image(systemName: "cpu")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.Orttaai.accent)
                .frame(width: 22, height: 22)
                .background(Color.Orttaai.accentSubtle, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            Text(modelDisplayName)
                .font(.Orttaai.bodyMedium)
                .foregroundStyle(Color.Orttaai.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
            if health.currentModelId == ExpressEngine.modelID {
                Text("Express")
                    .font(.Orttaai.caption)
                    .foregroundStyle(Color.Orttaai.accent)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Color.Orttaai.accentSubtle, in: Capsule())
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Spacing.sm)
        .padding(.vertical, 7)
        .background(Color.Orttaai.bgPrimary.opacity(0.7), in: RoundedRectangle(cornerRadius: CornerRadius.card, style: .continuous))
        .help(health.currentModelId)
    }

    // MARK: - Wording

    private func summary(_ typical: Int?) -> String {
        typical.map { "typically \($0) milliseconds" } ?? "no data"
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

    private var statusDescription: String {
        health.sampleCount == 0 ? "No performance samples yet." : "Typical times of the last \(health.sampleCount) dictations."
    }

    /// The model's family name ("Whisper Large V3 Turbo"), not its build ID;
    /// the ID stays available on hover.
    private var modelDisplayName: String {
        ModelManager.formatDisplayName(health.currentModelId)
    }
}
