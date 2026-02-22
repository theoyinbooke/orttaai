// UttraiProgressBar.swift
// Uttrai

import SwiftUI

struct UttraiProgressBarStyle: ProgressViewStyle {
    func makeBody(configuration: Configuration) -> some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.Uttrai.bgTertiary)
                    .frame(height: 6)

                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.Uttrai.accent)
                    .frame(
                        width: geometry.size.width * (configuration.fractionCompleted ?? 0),
                        height: 6
                    )
                    .animation(.linear(duration: 0.2), value: configuration.fractionCompleted)
            }
        }
        .frame(height: 6)
    }
}
