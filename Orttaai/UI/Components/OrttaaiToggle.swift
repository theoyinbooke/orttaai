// OrttaaiToggle.swift
// Orttaai

import SwiftUI

struct OrttaaiToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: Spacing.sm) {
            configuration.label
                .font(.Orttaai.body)
                .foregroundStyle(Color.Orttaai.textPrimary)

            Spacer()

            OrttaaiSwitchTrack(isOn: configuration.isOn)
                .onTapGesture {
                    configuration.isOn.toggle()
                }
        }
    }
}
