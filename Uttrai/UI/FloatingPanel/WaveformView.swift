// WaveformView.swift
// Uttrai

import SwiftUI

struct WaveformView: View {
    let audioLevel: Float
    let barCount = 10
    let barWidth: CGFloat = 3
    let barGap: CGFloat = 2
    let minHeight: CGFloat = 4
    let maxHeight: CGFloat = 28

    var body: some View {
        Canvas { context, size in
            let totalWidth = CGFloat(barCount) * (barWidth + barGap) - barGap
            let startX = (size.width - totalWidth) / 2

            for i in 0..<barCount {
                let noise = sin(Double(i) * 0.8 + Double(audioLevel) * 10) * 0.3 + 0.7
                let height = minHeight + (maxHeight - minHeight)
                    * CGFloat(audioLevel) * CGFloat(noise)
                let x = startX + CGFloat(i) * (barWidth + barGap)
                let y = (size.height - height) / 2

                let rect = CGRect(x: x, y: y, width: barWidth, height: height)
                let path = Path(roundedRect: rect, cornerRadius: barWidth / 2)
                context.fill(path, with: .color(Color.Uttrai.accent))
            }
        }
        .frame(height: 32)
        .animation(.linear(duration: 0.033), value: audioLevel)
    }
}
