// SettingsView.swift
// Orttaai

import SwiftUI

enum SettingsTab: Hashable {
    case general
    case audio
    case model
    case about
}

struct SettingsView: View {
    @State private var selectedTab: SettingsTab

    init(initialTab: SettingsTab = .general) {
        _selectedTab = State(initialValue: initialTab)
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            GeneralSettingsView()
                .tabItem {
                    Label("General", systemImage: "gearshape")
                }
                .tag(SettingsTab.general)

            AudioSettingsView()
                .tabItem {
                    Label("Audio", systemImage: "speaker.wave.2.fill")
                }
                .tag(SettingsTab.audio)

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
    }
}
