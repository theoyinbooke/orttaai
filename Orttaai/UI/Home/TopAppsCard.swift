// TopAppsCard.swift
// Orttaai

import SwiftUI

struct TopAppsCard: View {
    static let preferredHeight: CGFloat = 276

    let apps: [DashboardTopApp]

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            Text("Top Apps (30d)")
                .font(.Orttaai.subheading)
                .foregroundStyle(Color.Orttaai.textPrimary)

            if displayedApps.isEmpty {
                Text("No app usage data yet.")
                    .font(.Orttaai.secondary)
                    .foregroundStyle(Color.Orttaai.textSecondary)
            } else {
                ForEach(displayedApps) { app in
                    VStack(alignment: .leading, spacing: Spacing.xs) {
                        HStack {
                            Text(app.name)
                                .font(.Orttaai.bodyMedium)
                                .foregroundStyle(Color.Orttaai.textPrimary)
                                .lineLimit(1)

                            Spacer()

                            Text("\(app.sessions) sessions")
                                .font(.Orttaai.secondary)
                                .foregroundStyle(Color.Orttaai.textSecondary)
                        }

                        ProgressView(value: app.sessionShare, total: 1)
                            .tint(Color.Orttaai.accent)

                        Text("\(Int((app.sessionShare * 100).rounded()))% of sessions")
                            .font(.Orttaai.caption)
                            .foregroundStyle(Color.Orttaai.textTertiary)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(
                        "\(app.name), \(app.sessions) sessions, \(Int((app.sessionShare * 100).rounded())) percent of sessions."
                    )
                }
            }
        }
        .padding(Spacing.lg)
        .frame(
            maxWidth: .infinity,
            minHeight: Self.preferredHeight,
            maxHeight: Self.preferredHeight,
            alignment: .topLeading
        )
        .dashboardCard()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Top apps over 30 days")
    }

    private var displayedApps: [DashboardTopApp] {
        Array(apps.prefix(3))
    }
}
