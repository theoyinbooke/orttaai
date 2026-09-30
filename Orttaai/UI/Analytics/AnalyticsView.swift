// AnalyticsView.swift
// Orttaai

import SwiftUI

enum AnalyticsTab: String, CaseIterable, Identifiable {
    case dashboard = "Dashboard"
    case toneOfVoice = "Tone of Voice"
    case history = "History"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .dashboard: return "chart.bar"
        case .toneOfVoice: return "waveform.path.ecg"
        case .history: return "clock.arrow.circlepath"
        }
    }
}

struct AnalyticsView: View {
    @State private var selectedTab: AnalyticsTab = .dashboard

    var body: some View {
        Group {
            switch selectedTab {
            case .dashboard:
                AnalyticsDashboardView()
            case .toneOfVoice:
                ToneOfVoiceView()
            case .history:
                HistoryView()
            }
        }
        .padding(.top, Spacing.md)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.Orttaai.bgPrimary)
        .workspaceHeader("Analytics") {
            OrttaaiTabBar(
                tabs: AnalyticsTab.allCases,
                selection: $selectedTab,
                title: \.rawValue,
                icon: \.icon
            )
        }
    }
}
