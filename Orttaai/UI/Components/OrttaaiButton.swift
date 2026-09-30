// OrttaaiButton.swift
// Orttaai

import SwiftUI

enum OrttaaiButtonVariant {
    case primary
    case secondary
    case ghost
}

/// `.small` is the compact size used inside settings rows and cards.
enum OrttaaiButtonSize {
    case regular
    case small
}

struct OrttaaiButtonStyle: ButtonStyle {
    let variant: OrttaaiButtonVariant
    let isDestructive: Bool
    let size: OrttaaiButtonSize

    init(
        _ variant: OrttaaiButtonVariant = .primary,
        destructive: Bool = false,
        size: OrttaaiButtonSize = .regular
    ) {
        self.variant = variant
        self.isDestructive = destructive
        self.size = size
    }

    func makeBody(configuration: Configuration) -> some View {
        StyledButton(
            configuration: configuration,
            variant: variant,
            isDestructive: isDestructive,
            size: size
        )
    }

    /// Hover and enabled state live in a view: a ButtonStyle's own @State is
    /// not reliably preserved, and disabled buttons must look disabled.
    private struct StyledButton: View {
        let configuration: ButtonStyleConfiguration
        let variant: OrttaaiButtonVariant
        let isDestructive: Bool
        let size: OrttaaiButtonSize
        @Environment(\.isEnabled) private var isEnabled
        @State private var isHovered = false

        var body: some View {
            configuration.label
                .font(size == .small ? .Orttaai.secondary.weight(.medium) : .Orttaai.bodyMedium)
                .padding(.horizontal, horizontalPadding)
                .padding(.vertical, verticalPadding)
                .foregroundStyle(foregroundColor)
                .background(backgroundColor)
                .clipShape(RoundedRectangle(cornerRadius: CornerRadius.button))
                .overlay(
                    RoundedRectangle(cornerRadius: CornerRadius.button)
                        .stroke(borderColor, lineWidth: variant == .secondary ? BorderWidth.standard : 0)
                )
                .contentShape(RoundedRectangle(cornerRadius: CornerRadius.button))
                .opacity(isEnabled ? 1 : 0.45)
                .onHover { isHovered = $0 }
        }

        private var isActive: Bool { isEnabled && isHovered }

        private var horizontalPadding: CGFloat {
            if variant == .ghost { return Spacing.sm }
            return size == .small ? Spacing.md - 2 : Spacing.lg
        }

        private var verticalPadding: CGFloat {
            if variant == .ghost { return Spacing.xs }
            return size == .small ? 5 : Spacing.sm
        }

        private var foregroundColor: Color {
            if isDestructive { return Color.Orttaai.error }
            switch variant {
            case .primary: return Color.Orttaai.bgPrimary
            case .secondary: return Color.Orttaai.textPrimary
            case .ghost: return isActive ? Color.Orttaai.textPrimary : Color.Orttaai.textSecondary
            }
        }

        private var backgroundColor: Color {
            let isPressed = configuration.isPressed
            if isDestructive && (isActive || isPressed) {
                return Color.Orttaai.errorSubtle
            }
            switch variant {
            case .primary:
                if isPressed { return Color.Orttaai.accentPressed }
                if isActive { return Color.Orttaai.accentHover }
                return Color.Orttaai.accent
            case .secondary:
                if isActive || isPressed { return Color.Orttaai.bgTertiary }
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
}
