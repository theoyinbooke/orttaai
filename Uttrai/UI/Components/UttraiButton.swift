// UttraiButton.swift
// Uttrai

import SwiftUI

enum UttraiButtonVariant {
    case primary
    case secondary
    case ghost
}

struct UttraiButtonStyle: ButtonStyle {
    let variant: UttraiButtonVariant
    let isDestructive: Bool
    @State private var isHovered = false

    init(_ variant: UttraiButtonVariant = .primary, destructive: Bool = false) {
        self.variant = variant
        self.isDestructive = destructive
    }

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.Uttrai.bodyMedium)
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
        if isDestructive { return Color.Uttrai.error }
        switch variant {
        case .primary: return Color.Uttrai.bgPrimary
        case .secondary: return Color.Uttrai.textPrimary
        case .ghost: return isHovered ? Color.Uttrai.textPrimary : Color.Uttrai.textSecondary
        }
    }

    private func backgroundColor(isPressed: Bool) -> Color {
        if isDestructive && (isHovered || isPressed) {
            return Color.Uttrai.errorSubtle
        }
        switch variant {
        case .primary:
            if isPressed { return Color.Uttrai.accentPressed }
            if isHovered { return Color.Uttrai.accentHover }
            return Color.Uttrai.accent
        case .secondary:
            if isHovered || isPressed { return Color.Uttrai.bgTertiary }
            return .clear
        case .ghost:
            return .clear
        }
    }

    private var borderColor: Color {
        if isDestructive { return Color.Uttrai.error.opacity(0.3) }
        return variant == .secondary ? Color.Uttrai.border : .clear
    }
}
