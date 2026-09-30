// HomeSettingsWorkspaceView.swift
// Orttaai

import SwiftUI

enum SettingsSection: String, CaseIterable, Identifiable {
    case dictation
    case text
    case audio
    case general

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dictation: return "Dictation"
        case .text: return "Text"
        case .audio: return "Audio"
        case .general: return "General"
        }
    }

    var icon: String {
        switch self {
        case .dictation: return "waveform"
        case .text: return "text.alignleft"
        case .audio: return "mic"
        case .general: return "slider.horizontal.3"
        }
    }

    @MainActor @ViewBuilder
    var content: some View {
        switch self {
        case .dictation: DictationSettingsView()
        case .text: TextSettingsView()
        case .audio: AudioSettingsView()
        case .general: GeneralSettingsView()
        }
    }
}

struct HomeSettingsWorkspaceView: View {
    @State private var section: SettingsSection

    init(initialSection: SettingsSection = .dictation) {
        _section = State(initialValue: initialSection)
    }

    var body: some View {
        TabbedWorkspacePage(
            title: "Settings",
            tabs: SettingsSection.allCases,
            selection: $section,
            tabTitle: \.title,
            tabIcon: \.icon
        ) { section in
            section.content
        }
    }
}
