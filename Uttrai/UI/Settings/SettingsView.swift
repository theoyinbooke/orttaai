// SettingsView.swift
// Uttrai

import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem {
                    Label("General", systemImage: "gearshape")
                }

            AudioSettingsView()
                .tabItem {
                    Label("Audio", systemImage: "speaker.wave.2.fill")
                }

            ModelSettingsView()
                .tabItem {
                    Label("Model", systemImage: "cpu")
                }

            AboutView()
                .tabItem {
                    Label("About", systemImage: "info.circle")
                }
        }
        .frame(width: WindowSize.settings.width, height: WindowSize.settings.height)
    }
}
