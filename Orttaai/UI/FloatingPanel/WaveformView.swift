// WaveformView.swift
// Orttaai

import SwiftUI
import Foundation

struct WaveformView: View {
    let audioLevel: Float
    let elapsedSeconds: Int
    var onStop: (() -> Void)? = nil

    private let barCount = 16
    private let barWidth: CGFloat = 2.5
    private let barGap: CGFloat = 2
    private let minBarHeight: CGFloat = 6
    private let maxBarHeight: CGFloat = 18

    var body: some View {
        ZStack {
            waveBannerBackground

            HStack(spacing: Spacing.md) {
                HStack(spacing: barGap) {
                    ForEach(0..<barCount, id: \.self) { index in
                        RoundedRectangle(cornerRadius: barWidth / 2, style: .continuous)
                            .fill(Color.Orttaai.accent.opacity(0.95))
                            .frame(width: barWidth, height: barHeight(for: index))
                    }
                }
                .shadow(color: Color.Orttaai.accent.opacity(Double(audioLevel) * 0.5), radius: 6, y: 0)

                Spacer(minLength: 0)

                Text(formattedElapsed)
                    .font(.Orttaai.mono)
                    .foregroundStyle(Color.Orttaai.textPrimary)
                    .contentTransition(.numericText())
                    .frame(minWidth: 42, alignment: .trailing)
                    .padding(.horizontal, Spacing.sm)
                    .padding(.vertical, Spacing.xs)
                    .background(Color.Orttaai.bgPrimary.opacity(0.32))
                    .clipShape(RoundedRectangle(cornerRadius: CornerRadius.input, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: CornerRadius.input, style: .continuous)
                            .stroke(Color.Orttaai.border.opacity(0.35), lineWidth: BorderWidth.standard)
                    )

                if let onStop {
                    Button(action: onStop) {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(Color.Orttaai.error)
                            .frame(width: 22, height: 22)
                            .background(Color.Orttaai.errorSubtle.opacity(0.85))
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .help("Stop dictation")
                    .accessibilityLabel("Stop dictation")
                }
            }
            .padding(.horizontal, Spacing.md)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipShape(Capsule())
        .overlay(
            Capsule()
                .stroke(Color.Orttaai.accent.opacity(0.16), lineWidth: BorderWidth.standard)
        )
        .padding(.horizontal, Spacing.sm)
        .padding(.vertical, 5)
        .animation(.linear(duration: 0.033), value: audioLevel)
        .animation(.easeInOut(duration: 0.18), value: elapsedSeconds)
    }

    private var waveBannerBackground: some View {
        TimelineView(.animation) { context in
            let time = context.date.timeIntervalSinceReferenceDate

            Canvas { canvas, size in
                let primary = wavePath(
                    in: size,
                    time: time,
                    amplitude: 5 + CGFloat(audioLevel) * 6,
                    frequency: 1.8,
                    verticalOffset: size.height * 0.48
                )
                let secondary = wavePath(
                    in: size,
                    time: time + 0.7,
                    amplitude: 4 + CGFloat(audioLevel) * 4,
                    frequency: 2.5,
                    verticalOffset: size.height * 0.6
                )

                canvas.fill(
                    primary,
                    with: .linearGradient(
                        Gradient(colors: [
                            Color.Orttaai.accent.opacity(0.24),
                            Color.Orttaai.accent.opacity(0.06)
                        ]),
                        startPoint: CGPoint(x: 0, y: 0),
                        endPoint: CGPoint(x: size.width, y: size.height)
                    )
                )
                canvas.fill(
                    secondary,
                    with: .linearGradient(
                        Gradient(colors: [
                            Color.Orttaai.accent.opacity(0.14),
                            Color.clear
                        ]),
                        startPoint: CGPoint(x: size.width, y: 0),
                        endPoint: CGPoint(x: 0, y: size.height)
                    )
                )
            }
        }
        .background(
            LinearGradient(
                colors: [
                    Color.Orttaai.bgSecondary,
                    Color.Orttaai.bgPrimary.opacity(0.92)
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
        )
    }

    private func wavePath(
        in size: CGSize,
        time: TimeInterval,
        amplitude: CGFloat,
        frequency: CGFloat,
        verticalOffset: CGFloat
    ) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: 0, y: size.height))
        path.addLine(to: CGPoint(x: 0, y: verticalOffset))

        let step = max(4, size.width / 32)
        var x: CGFloat = 0
        while x <= size.width {
            let relative = x / max(size.width, 1)
            let y = verticalOffset + sin((relative * frequency * .pi * 2) + CGFloat(time) * 2.8) * amplitude
            path.addLine(to: CGPoint(x: x, y: y))
            x += step
        }

        path.addLine(to: CGPoint(x: size.width, y: size.height))
        path.closeSubpath()
        return path
    }

    private func barHeight(for index: Int) -> CGFloat {
        let boosted = min(Float(1.0), audioLevel * 2.5 + 0.15)
        let level = CGFloat(boosted)
        let centerDist = abs(Double(index) - Double(barCount - 1) / 2.0)
        let centerMax = Double(barCount - 1) / 2.0
        let envelope = 1.0 - (centerDist / centerMax) * 0.4
        let wave = sin(Double(index) * 1.2 + Double(audioLevel) * 12 + Double(elapsedSeconds) * 0.8) * 0.25 + 0.75
        let normalized = CGFloat(wave * envelope)
        return minBarHeight + (maxBarHeight - minBarHeight) * level * normalized
    }

    private var formattedElapsed: String {
        let minutes = elapsedSeconds / 60
        let seconds = elapsedSeconds % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}
