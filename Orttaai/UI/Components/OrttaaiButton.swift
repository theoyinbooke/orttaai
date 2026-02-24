// OrttaaiButton.swift
// Orttaai

import SwiftUI

enum OrttaaiButtonVariant {
    case primary
    case secondary
    case ghost
}

struct OrttaaiButtonStyle: ButtonStyle {
    let variant: OrttaaiButtonVariant
    let isDestructive: Bool
    @State private var isHovered = false

    init(_ variant: OrttaaiButtonVariant = .primary, destructive: Bool = false) {
        self.variant = variant
        self.isDestructive = destructive
    }

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.Orttaai.bodyMedium)
            .padding(.horizontal, variant == .ghost ? Spacing.sm : Spacing.lg)
            .padding(.vertical, variant == .ghost ? Spacing.xs : Spacing.sm)
            .foregroundStyle(foregroundColor(isPressed: configuration.isPressed))
            .background(backgroundColor(isPressed: configuration.isPressed))
            .clipShape(RoundedRectangle(cornerRadius: CornerRadius.button))
            .overlay(
                RoundedRectangle(cornerRadius: CornerRadius.button)
                    .stroke(borderColor, lineWidth: variant == .secondary ? BorderWidth.standard : 0)
            )
            .onHover { isHovered = $0 }
    }

    private func foregroundColor(isPressed: Bool) -> Color {
        if isDestructive { return Color.Orttaai.error }
        switch variant {
        case .primary: return Color.Orttaai.bgPrimary
        case .secondary: return Color.Orttaai.textPrimary
        case .ghost: return isHovered ? Color.Orttaai.textPrimary : Color.Orttaai.textSecondary
        }
    }

    private func backgroundColor(isPressed: Bool) -> Color {
        if isDestructive && (isHovered || isPressed) {
            return Color.Orttaai.errorSubtle
        }
        switch variant {
        case .primary:
            if isPressed { return Color.Orttaai.accentPressed }
            if isHovered { return Color.Orttaai.accentHover }
            return Color.Orttaai.accent
        case .secondary:
            if isHovered || isPressed { return Color.Orttaai.bgTertiary }
            return .clear
        case .ghost:
            return .clear
        }
    }

    private var borderColor: Color {
        if isDestructive { return Color.Orttaai.error.opacity(0.3) }
        return variant == .secondary ? Color.Orttaai.border : .clear
    }
}
