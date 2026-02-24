// OrttaaiApp.swift
// Orttaai

import SwiftUI

@main
struct OrttaaiApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            EmptyView()
                .frame(width: 0, height: 0)
        }
        .defaultSize(width: 0, height: 0)

        Settings {
            Text("Settings placeholder")
        }
    }
}
