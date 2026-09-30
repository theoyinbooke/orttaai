// SettingsView.swift
// Orttaai

import SwiftUI

enum SettingsTab: Hashable {
    case settings
    case model
    case about
}

/// The standalone Settings window (the app's Settings scene) shows the same
/// pages as the main window's Settings and Model sections.
struct SettingsView: View {
    @State private var selectedTab: SettingsTab

    init(initialTab: SettingsTab = .settings) {
        _selectedTab = State(initialValue: initialTab)
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            HomeSettingsWorkspaceView()
                .tabItem {
                    Label("Settings", systemImage: "gearshape")
                }
                .tag(SettingsTab.settings)

            ModelSettingsView()
                .tabItem {
                    Label("Model", systemImage: "cpu")
                }
                .tag(SettingsTab.model)

            AboutView()
                .tabItem {
                    Label("About", systemImage: "info.circle")
                }
                .tag(SettingsTab.about)
        }
        .frame(width: WindowSize.settings.width, height: WindowSize.settings.height)
        .environment(\.workspaceHeaderInToolbar, false)
        .preferredColorScheme(.dark)
    }
}
