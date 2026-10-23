// InsightStatTicker.swift
// Orttaai

import SwiftUI

/// One number (or name) the Insights header cycles through.
struct InsightStat: Identifiable, Equatable {
    let id: String
    let icon: String
    var number: Double?
    var text: String?
    let label: String
}

/// The top of the Insights panel: a scanning ring and one statistic at a
/// time. Each number rolls up from zero, a thin bar drains while it's
/// shown, and the next one takes over, so the snapshot reads itself.
/// Holds on the first statistic under Reduce Motion.
struct InsightStatTicker: View {
    let stats: [InsightStat]
    /// The analysis is running: the ring scans faster.
    var isScanning = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var index = 0
    @State private var shownNumber: Double = 0
    @State private var remaining: CGFloat = 1
    @State private var ringTurn = false
    @State private var blip = false

    private let holdSeconds = 3.2

    private var current: InsightStat? {
        guard !stats.isEmpty else { return nil }
        return stats[index % stats.count]
    }

    var body: some View {
        HStack(spacing: Spacing.md) {
            scanRing
            if let current {
                VStack(alignment: .leading, spacing: 3) {
                    valueText(current)
                        .font(.system(size: 26, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.Orttaai.textPrimary)
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                    Text(current.label)
                        .font(.Orttaai.caption)
                        .foregroundStyle(Color.Orttaai.textSecondary)
                        .lineLimit(1)
                        .id(current.id)
                        .transition(.asymmetric(
                            insertion: .move(edge: .bottom).combined(with: .opacity),
                            removal: .opacity
                        ))
                    drainBar
                        .padding(.top, 4)
                }
                .clipped()
            }
            Spacer(minLength: 0)
            pageDots
        }
        .padding(Spacing.md)
        .background(
            LinearGradient(
                colors: [Color.Orttaai.accent.opacity(0.12), Color.Orttaai.bgPrimary.opacity(0.4)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: CornerRadius.card, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: CornerRadius.card, style: .continuous)
                .stroke(Color.Orttaai.accent.opacity(0.25), lineWidth: BorderWidth.standard)
        )
        .task(id: stats.map(\.id)) {
            await cycle()
        }
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.linear(duration: isScanning ? 1.4 : 3.2).repeatForever(autoreverses: false)) {
                ringTurn = true
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(stats.map { "\($0.text ?? $0.number.map { Self.format($0) } ?? "") \($0.label)" }.joined(separator: ", "))
    }

    // MARK: - Parts

    @ViewBuilder
    private func valueText(_ stat: InsightStat) -> some View {
        if let text = stat.text {
            Text(text)
                .id(stat.id)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        } else {
            Text(Self.format(shownNumber))
                .contentTransition(.numericText(value: shownNumber))
        }
    }

    /// A ring with a sweeping arc and a blip at its centre that pings when
    /// a new statistic arrives; drawn with vector shapes, turned by Core
    /// Animation.
    private var scanRing: some View {
        ZStack {
            Circle()
                .stroke(Color.Orttaai.accent.opacity(0.18), lineWidth: 2)
            Circle()
                .trim(from: 0, to: 0.28)
                .stroke(
                    AngularGradient(
                        colors: [Color.Orttaai.accent.opacity(0), Color.Orttaai.accent],
                        center: .center,
                        startAngle: .degrees(0),
                        endAngle: .degrees(100)
                    ),
                    style: StrokeStyle(lineWidth: 2.5, lineCap: .round)
                )
                .rotationEffect(.degrees(ringTurn ? 360 : 0))
            Circle()
                .stroke(Color.Orttaai.accent.opacity(blip ? 0 : 0.6), lineWidth: 1.5)
                .scaleEffect(blip ? 1.35 : 0.4)
            Image(systemName: current?.icon ?? "brain")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.Orttaai.accent)
                .contentTransition(.symbolEffect(.replace))
        }
        .frame(width: 46, height: 46)
    }

    /// Drains while the statistic is shown, like a countdown to the next.
    private var drainBar: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.Orttaai.textTertiary.opacity(0.2))
                Capsule()
                    .fill(Color.Orttaai.accent.opacity(0.8))
                    .frame(width: geometry.size.width * remaining)
            }
        }
        .frame(width: 120, height: 3)
    }

    private var pageDots: some View {
        VStack(spacing: 4) {
            ForEach(Array(stats.enumerated()), id: \.element.id) { offset, _ in
                Capsule()
                    .fill(offset == index % max(stats.count, 1) ? Color.Orttaai.accent : Color.Orttaai.textTertiary.opacity(0.3))
                    .frame(width: 3, height: offset == index % max(stats.count, 1) ? 12 : 5)
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: index)
    }

    // MARK: - Timing

    private func cycle() async {
        guard !stats.isEmpty else { return }
        index = 0
        while !Task.isCancelled {
            show(index)
            guard !reduceMotion, stats.count > 1 else { return }
            try? await Task.sleep(for: .seconds(holdSeconds))
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.3)) {
                index = (index + 1) % stats.count
            }
        }
    }

    private func show(_ position: Int) {
        let stat = stats[position % stats.count]
        shownNumber = 0
        remaining = 1
        blip = false
        withAnimation(.spring(response: 0.9, dampingFraction: 0.9)) {
            shownNumber = stat.number ?? 0
        }
        guard !reduceMotion else { return }
        withAnimation(.easeOut(duration: 0.7)) {
            blip = true
        }
        withAnimation(.linear(duration: holdSeconds)) {
            remaining = 0
        }
    }

    static func format(_ value: Double) -> String {
        Int(value.rounded()).formatted()
    }
}
