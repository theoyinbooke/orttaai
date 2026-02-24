// TopAppsCard.swift
// Orttaai

import SwiftUI

struct TopAppsCard: View {
    let apps: [DashboardTopApp]

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            Text("Top Apps (7d)")
                .font(.Orttaai.subheading)
                .foregroundStyle(Color.Orttaai.textPrimary)

            if apps.isEmpty {
                Text("No app usage data yet.")
                    .font(.Orttaai.secondary)
                    .foregroundStyle(Color.Orttaai.textSecondary)
            } else {
                ForEach(apps) { app in
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
        .frame(maxWidth: .infinity, alignment: .leading)
        .dashboardCard()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Top apps over 7 days")
    }
}
