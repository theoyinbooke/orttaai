// WaveformView.swift
// Orttaai

import SwiftUI
import Foundation

/// The microphone level the recording pill draws. AppDelegate writes it on
/// every poll and the pill's canvas reads it each frame, so a new level
/// redraws one canvas instead of rebuilding the pill.
final class RecordingLevelMeter {
    var level: Float = 0
}

/// The recording pill. It never displays transcript text; the finalized
/// dictation is inserted once after recording ends.
struct WaveformView: View {
    /// The level drawn when there is no meter.
    let audioLevel: Float
    let elapsedSeconds: Int
    var countdownSeconds: Int? = nil
    /// Hands-free (tap-to-toggle) recordings show a distinct glyph so the
    /// pill never lies about whether releasing a key will stop anything.
    var isHandsFree: Bool = false
    /// Voice edit sessions get an explicit EDIT badge so the pill never looks
    /// like a plain dictation while an instruction is being recorded.
    var isEditMode: Bool = false
    /// The live level while recording.
    var meter: RecordingLevelMeter? = nil
    var onStop: (() -> Void)? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let barCount = 16
    private let barWidth: CGFloat = 2.5
    private let barGap: CGFloat = 2
    private let minBarHeight: CGFloat = 6
    private let maxBarHeight: CGFloat = 18

    private var isCountingDown: Bool { countdownSeconds != nil }

    private var activeTint: Color {
        isCountingDown ? Color.Orttaai.error : Color.Orttaai.accent
    }

    var body: some View {
        ZStack {
            liveCanvas
            controlsRow
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipShape(Capsule())
        .overlay(
            Capsule()
                .stroke(activeTint.opacity(0.16), lineWidth: BorderWidth.standard)
        )
        .padding(.horizontal, Spacing.sm)
        .padding(.vertical, 5)
        .animation(.easeInOut(duration: 0.18), value: elapsedSeconds)
        .animation(.easeInOut(duration: 0.3), value: isCountingDown)
        .animation(.easeInOut(duration: 0.18), value: countdownSeconds)
        .animation(.easeInOut(duration: 0.18), value: isHandsFree)
        .animation(.easeInOut(duration: 0.18), value: isEditMode)
    }

    private var controlsRow: some View {
        HStack(spacing: Spacing.md) {
            // The level bars are drawn here by `liveCanvas`.
            Color.clear
                .frame(width: barsWidth, height: maxBarHeight)

            Spacer(minLength: 0)

            if isEditMode {
                HStack(spacing: Spacing.xs) {
                    Image(systemName: "pencil.line")
                        .font(.system(size: 9, weight: .bold))
                    Text("EDIT")
                        .font(.Orttaai.caption)
                        .fontWeight(.bold)
                }
                .foregroundStyle(activeTint)
                .padding(.horizontal, Spacing.sm)
                .padding(.vertical, Spacing.xs)
                .background(activeTint.opacity(0.14))
                .clipShape(Capsule())
                .help("Speak how to change the selected text")
                .accessibilityLabel("Recording edit instruction")
            }

            if isHandsFree {
                Image(systemName: "infinity")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(activeTint)
                    .frame(width: 18, height: 18)
                    .background(activeTint.opacity(0.14))
                    .clipShape(Circle())
                    .help("Tap the shortcut, press stop, or pause to finish")
                    .accessibilityLabel("Hands-free recording")
            }

            HStack(spacing: Spacing.xs) {
                Text(formattedElapsed)
                    .font(.Orttaai.mono)
                    .foregroundStyle(Color.Orttaai.textPrimary)
                    .contentTransition(.numericText())

                if let countdown = countdownSeconds {
                    Text("\u{00B7}")
                        .font(.Orttaai.mono)
                        .foregroundStyle(Color.Orttaai.textSecondary)

                    Text("\(countdown)s")
                        .font(.Orttaai.mono)
                        .foregroundStyle(Color.Orttaai.error)
                        .contentTransition(.numericText())
                }
            }
            .frame(minWidth: 42, alignment: .trailing)
            .padding(.horizontal, Spacing.sm)
            .padding(.vertical, Spacing.xs)
            .background(
                isCountingDown
                    ? Color.Orttaai.errorSubtle.opacity(0.32)
                    : Color.Orttaai.bgPrimary.opacity(0.32)
            )
            .clipShape(RoundedRectangle(cornerRadius: CornerRadius.input, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: CornerRadius.input, style: .continuous)
                    .stroke(
                        isCountingDown
                            ? Color.Orttaai.error.opacity(0.35)
                            : Color.Orttaai.border.opacity(0.35),
                        lineWidth: BorderWidth.standard
                    )
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

    private var currentLevel: Float { meter?.level ?? audioLevel }

    private var barsWidth: CGFloat { CGFloat(barCount) * barWidth + CGFloat(barCount - 1) * barGap }

    /// The waves and the level bars, drawn 30 times a second from the
    /// meter's latest level. Rebuilding the pill for every new level, with
    /// the bars animating at the display's rate (up to 144 a second here),
    /// cost twice the CPU while recording.
    private var liveCanvas: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion && meter == nil)) { context in
            let time = reduceMotion ? 0 : context.date.timeIntervalSinceReferenceDate
            let audioLevel = currentLevel

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
                            activeTint.opacity(0.24),
                            activeTint.opacity(0.06)
                        ]),
                        startPoint: CGPoint(x: 0, y: 0),
                        endPoint: CGPoint(x: size.width, y: size.height)
                    )
                )
                canvas.fill(
                    secondary,
                    with: .linearGradient(
                        Gradient(colors: [
                            activeTint.opacity(0.14),
                            Color.clear
                        ]),
                        startPoint: CGPoint(x: size.width, y: 0),
                        endPoint: CGPoint(x: 0, y: size.height)
                    )
                )

                canvas.drawLayer { bars in
                    bars.addFilter(.shadow(color: activeTint.opacity(Double(audioLevel) * 0.5), radius: 6))
                    for index in 0..<barCount {
                        let height = barHeight(for: index, level: audioLevel)
                        let rect = CGRect(
                            x: Spacing.md + CGFloat(index) * (barWidth + barGap),
                            y: (size.height - height) / 2,
                            width: barWidth,
                            height: height
                        )
                        bars.fill(
                            Path(roundedRect: rect, cornerRadius: barWidth / 2, style: .continuous),
                            with: .color(activeTint.opacity(0.95))
                        )
                    }
                }
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

    private func barHeight(for index: Int, level audioLevel: Float) -> CGFloat {
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
