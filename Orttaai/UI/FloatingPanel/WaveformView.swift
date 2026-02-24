// WaveformView.swift
// Orttaai

import SwiftUI

struct WaveformView: View {
    let audioLevel: Float

    private let barCount = 16
    private let barWidth: CGFloat = 2.5
    private let barGap: CGFloat = 1.5
    private let minBarHeight: CGFloat = 6
    private let maxBarHeight: CGFloat = 28

    var body: some View {
        ZStack {
            // Glow layer — blurred copy behind the bars
            barsCanvas(opacity: 0.5)
                .blur(radius: 4)

            // Crisp bar layer
            barsCanvas(opacity: 1.0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .shadow(color: Color.Orttaai.accent.opacity(Double(audioLevel) * 0.5), radius: 6, y: 0)
        .padding(.horizontal, 4)
        .animation(.linear(duration: 0.033), value: audioLevel)
    }

    private func barsCanvas(opacity: Double) -> some View {
        Canvas { context, size in
            let totalWidth = CGFloat(barCount) * (barWidth + barGap) - barGap
            let startX = (size.width - totalWidth) / 2
            // Boost low audio levels so bars are always visibly active
            let boosted = min(Float(1.0), audioLevel * 2.5 + 0.15)
            let level = CGFloat(boosted)

            for i in 0..<barCount {
                let centerDist = abs(Double(i) - Double(barCount - 1) / 2.0)
                let centerMax = Double(barCount - 1) / 2.0
                let envelope = 1.0 - (centerDist / centerMax) * 0.4
                let wave = sin(Double(i) * 1.2 + Double(audioLevel) * 12) * 0.25 + 0.75
                let normalized = CGFloat(wave * envelope)

                let barH = minBarHeight + (maxBarHeight - minBarHeight) * level * normalized
                let x = startX + CGFloat(i) * (barWidth + barGap)
                let y = (size.height - barH) / 2

                let rect = CGRect(x: x, y: y, width: barWidth, height: barH)
                let path = Path(roundedRect: rect, cornerRadius: barWidth / 2)
                context.fill(path, with: .color(Color.Orttaai.accent.opacity(opacity)))
            }
        }
    }
}
