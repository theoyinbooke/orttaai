// AnalyticsView.swift
// Orttaai

import SwiftUI

enum AnalyticsTab: String, CaseIterable {
    case dashboard = "Dashboard"
    case history = "History"
}

struct AnalyticsView: View {
    @State private var selectedTab: AnalyticsTab = .dashboard

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, Spacing.xxl)
                .padding(.top, Spacing.xxl)
                .padding(.bottom, Spacing.lg)

            switch selectedTab {
            case .dashboard:
                AnalyticsDashboardView()
            case .history:
                HistoryView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.Orttaai.bgPrimary)
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text("Analytics")
                    .font(.Orttaai.heading)
                    .foregroundStyle(Color.Orttaai.textPrimary)

                Text("Insights, trends, and transcription history.")
                    .font(.Orttaai.secondary)
                    .foregroundStyle(Color.Orttaai.textSecondary)
            }

            Spacer()

            Picker("", selection: $selectedTab) {
                ForEach(AnalyticsTab.allCases, id: \.self) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 200)
        }
    }
}
