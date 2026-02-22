// UttraiToggle.swift
// Uttrai

import SwiftUI

struct UttraiToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: Spacing.sm) {
            configuration.label
                .font(.Uttrai.body)
                .foregroundStyle(Color.Uttrai.textPrimary)

            Spacer()

            RoundedRectangle(cornerRadius: 10)
                .fill(configuration.isOn ? Color.Uttrai.accent : Color.Uttrai.bgTertiary)
                .frame(width: 36, height: 20)
                .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                    Circle()
                        .fill(.white)
                        .frame(width: 16, height: 16)
                        .padding(2)
                }
                .animation(.easeOut(duration: 0.15), value: configuration.isOn)
                .onTapGesture {
                    configuration.isOn.toggle()
                }
        }
    }
}
