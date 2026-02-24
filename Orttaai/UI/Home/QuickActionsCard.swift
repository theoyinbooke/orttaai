// QuickActionsCard.swift
// Orttaai

import SwiftUI

struct QuickActionsCard: View {
    let onOpenSettings: () -> Void
    let onOpenModelSettings: () -> Void
    let onOpenHistory: () -> Void
    let onRunSetup: () -> Void
    let onRefresh: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            Text("Quick Actions")
                .font(.Orttaai.subheading)
                .foregroundStyle(Color.Orttaai.textPrimary)

            VStack(alignment: .leading, spacing: Spacing.sm) {
                actionButton(
                    "Open Settings",
                    icon: "gearshape",
                    shortcut: ",",
                    modifiers: .command,
                    action: onOpenSettings
                )
                actionButton("Open Model Settings", icon: "cpu", action: onOpenModelSettings)
                actionButton(
                    "Open Full History",
                    icon: "clock.arrow.circlepath",
                    shortcut: "h",
                    modifiers: [.command, .shift],
                    action: onOpenHistory
                )
                actionButton("Run Setup", icon: "slider.horizontal.3", action: onRunSetup)
                actionButton(
                    "Refresh Dashboard",
                    icon: "arrow.clockwise",
                    shortcut: "r",
                    modifiers: .command,
                    action: onRefresh
                )
            }
        }
        .padding(Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .dashboardCard()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Quick actions")
    }

    @ViewBuilder
    private func actionButton(
        _ title: String,
        icon: String,
        shortcut: KeyEquivalent? = nil,
        modifiers: EventModifiers = .command,
        action: @escaping () -> Void
    ) -> some View {
        let button = Button(action: action) {
            HStack(spacing: Spacing.sm) {
                Image(systemName: icon)
                Text(title)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(OrttaaiButtonStyle(.secondary))
        .accessibilityLabel(title)

        if let shortcut {
            button.keyboardShortcut(shortcut, modifiers: modifiers)
        } else {
            button
        }
    }
}
