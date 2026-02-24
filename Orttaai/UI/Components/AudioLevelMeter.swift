// AudioLevelMeter.swift
// Orttaai

import SwiftUI

struct AudioLevelMeter: View {
    let level: Float // 0.0 to 1.0

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.Orttaai.bgTertiary)

                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.Orttaai.accent)
                    .frame(width: geometry.size.width * CGFloat(min(level, 1.0)))
                    .animation(.linear(duration: 0.033), value: level)
            }
        }
        .frame(height: 8)
    }
}
