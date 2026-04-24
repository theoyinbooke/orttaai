// TodaySnapshotCard.swift
// Orttaai

import SwiftUI

struct TodaySnapshotCard: View {
    let snapshot: DashboardTodaySnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            Text("Today Snapshot")
                .font(.Orttaai.subheading)
                .foregroundStyle(Color.Orttaai.textPrimary)

            Text(statusDescription)
                .font(.Orttaai.secondary)
                .foregroundStyle(Color.Orttaai.textSecondary)
                .lineLimit(1)

            LazyVGrid(
                columns: [
                    GridItem(.flexible(), spacing: Spacing.md),
                    GridItem(.flexible(), spacing: Spacing.md)
                ],
                spacing: Spacing.md
            ) {
                metricCell(title: "Words", value: snapshot.words.formatted())
                metricCell(title: "Sessions", value: snapshot.sessions.formatted())
                metricCell(title: "Active Minutes", value: snapshot.activeMinutes.formatted())
                metricCell(title: "Avg WPM", value: snapshot.averageWPM.formatted())
            }
        }
        .padding(Spacing.lg)
        .frame(maxWidth: .infinity, minHeight: 228, alignment: .leading)
        .dashboardCard()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            "Today snapshot: \(statusDescription) \(snapshot.words) words, \(snapshot.sessions) sessions, \(snapshot.activeMinutes) active minutes, average \(snapshot.averageWPM) words per minute."
        )
    }

    private var statusDescription: String {
        if snapshot.sessions == 0 {
            return "No dictations today yet."
        }

        return "\(snapshot.sessions.formatted()) dictations today."
    }

    private func metricCell(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Text(title)
                .font(.Orttaai.secondary)
                .foregroundStyle(Color.Orttaai.textSecondary)

            Text(value)
                .font(.Orttaai.heading)
                .foregroundStyle(Color.Orttaai.textPrimary)
        }
        .padding(Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.Orttaai.bgPrimary)
        .clipShape(RoundedRectangle(cornerRadius: CornerRadius.card))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title) \(value)")
    }
}
