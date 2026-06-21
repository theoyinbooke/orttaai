// AnalyticsView.swift
// Orttaai

import SwiftUI

enum AnalyticsTab: String, CaseIterable {
    case dashboard = "Dashboard"
    case toneOfVoice = "Tone of Voice"
    case history = "History"
}

struct AnalyticsView: View {
    @State private var selectedTab: AnalyticsTab = .dashboard

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, WorkspaceLayout.contentHorizontalPadding)
                .padding(.top, WorkspaceLayout.contentTopPadding)
                .padding(.bottom, Spacing.lg)

            switch selectedTab {
            case .dashboard:
                AnalyticsDashboardView()
            case .toneOfVoice:
                ToneOfVoiceView()
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

            tabPicker
                .frame(width: 340)
        }
    }

    private var tabPicker: some View {
        HStack(spacing: 4) {
            ForEach(AnalyticsTab.allCases, id: \.self) { tab in
                Button {
                    withAnimation(.easeInOut(duration: 0.16)) {
                        selectedTab = tab
                    }
                } label: {
                    Text(tab.rawValue)
                        .font(.Orttaai.bodyMedium)
                        .lineLimit(1)
                        .foregroundStyle(selectedTab == tab ? Color.Orttaai.bgPrimary : Color.Orttaai.textSecondary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 28)
                        .background(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(selectedTab == tab ? Color.Orttaai.accent : Color.clear)
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background(Color.Orttaai.bgSecondary)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}
