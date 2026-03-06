// FloatingPanelHintView.swift
// Orttaai

import SwiftUI

struct FloatingPanelHintView: View {
    let shortcutLabel: String
    let onStart: () -> Void

    var body: some View {
        ZStack {
            hintBackdrop

            HStack(spacing: Spacing.sm) {
                Image(systemName: "waveform.path.ecg")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.Orttaai.accent)

                HStack(spacing: 4) {
                    Text("Hold")
                        .foregroundStyle(Color.Orttaai.textSecondary)

                    Text(shortcutLabel)
                        .foregroundStyle(Color.Orttaai.textPrimary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(Color.Orttaai.bgPrimary.opacity(0.45))
                        )

                    Text("to dictate")
                        .foregroundStyle(Color.Orttaai.textSecondary)
                }
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)

                Spacer(minLength: 0)

                Button(action: onStart) {
                    Image(systemName: "mic.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.Orttaai.bgPrimary)
                        .frame(width: 24, height: 24)
                        .background(Color.Orttaai.accent)
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .help("Start dictation")
                .accessibilityLabel("Start dictation")
            }
            .padding(.horizontal, Spacing.md)
        }
        .clipShape(Capsule())
        .overlay(
            Capsule()
                .stroke(Color.Orttaai.border.opacity(0.35), lineWidth: BorderWidth.standard)
        )
    }

    private var hintBackdrop: some View {
        TimelineView(.animation) { context in
            let time = context.date.timeIntervalSinceReferenceDate

            Canvas { canvas, size in
                let glowRect = CGRect(x: size.width * 0.08, y: size.height * 0.18, width: size.width * 0.36, height: size.height * 0.64)
                canvas.fill(
                    Path(ellipseIn: glowRect.offsetBy(dx: sin(time * 1.6) * 14, dy: 0)),
                    with: .radialGradient(
                        Gradient(colors: [
                            Color.Orttaai.accent.opacity(0.22),
                            Color.clear
                        ]),
                        center: CGPoint(x: glowRect.midX, y: glowRect.midY),
                        startRadius: 0,
                        endRadius: glowRect.width * 0.5
                    )
                )

                var wavePath = Path()
                wavePath.move(to: CGPoint(x: 0, y: size.height))
                wavePath.addLine(to: CGPoint(x: 0, y: size.height * 0.62))

                let step = max(5, size.width / 28)
                var x: CGFloat = 0
                while x <= size.width {
                    let relative = x / max(size.width, 1)
                    let y = size.height * 0.62 + sin((relative * .pi * 4.4) + CGFloat(time) * 2.4) * 5
                    wavePath.addLine(to: CGPoint(x: x, y: y))
                    x += step
                }

                wavePath.addLine(to: CGPoint(x: size.width, y: size.height))
                wavePath.closeSubpath()

                canvas.fill(
                    wavePath,
                    with: .linearGradient(
                        Gradient(colors: [
                            Color.Orttaai.accent.opacity(0.16),
                            Color.clear
                        ]),
                        startPoint: CGPoint(x: 0, y: size.height * 0.3),
                        endPoint: CGPoint(x: size.width, y: size.height)
                    )
                )
            }
        }
        .background(
            LinearGradient(
                colors: [
                    Color.Orttaai.bgSecondary.opacity(0.98),
                    Color.Orttaai.bgPrimary.opacity(0.96)
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
        )
    }
}
