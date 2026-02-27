// HomeNavigation.swift
// Orttaai

import Foundation
import Combine

enum HomeSection: String, CaseIterable, Identifiable {
    case overview
    case memory
    case history
    case settings
    case model
    case about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: return "Overview"
        case .memory: return "Memory"
        case .history: return "History"
        case .settings: return "Settings"
        case .model: return "Model"
        case .about: return "About"
        }
    }

    var icon: String {
        switch self {
        case .overview: return "house"
        case .memory: return "text.book.closed"
        case .history: return "clock.arrow.circlepath"
        case .settings: return "gearshape"
        case .model: return "cpu"
        case .about: return "info.circle"
        }
    }

    var subtitle: String {
        switch self {
        case .overview: return "Daily stats and actions"
        case .memory: return "Dictionary and snippets"
        case .history: return "Browse recent transcriptions"
        case .settings: return "General and audio controls"
        case .model: return "Model selection and storage"
        case .about: return "Version and acknowledgments"
        }
    }
}

final class HomeNavigationState: ObservableObject {
    @Published var selectedSection: HomeSection = .overview
}
