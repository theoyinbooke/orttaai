// HomeNavigation.swift
// Orttaai

import Foundation
import Combine

enum HomeSection: String, CaseIterable, Identifiable {
    case overview
    case memory
    case analytics
    case model
    case settings
    case about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: return "Overview"
        case .memory: return "Memory"
        case .analytics: return "Analytics"
        case .settings: return "Settings"
        case .model: return "Model"
        case .about: return "About"
        }
    }

    var icon: String {
        switch self {
        case .overview: return "house"
        case .memory: return "text.book.closed"
        case .analytics: return "chart.bar.xaxis"
        case .settings: return "gearshape"
        case .model: return "cpu"
        case .about: return "info.circle"
        }
    }

    var subtitle: String {
        switch self {
        case .overview: return "Daily stats and actions"
        case .memory: return "Dictionary and snippets"
        case .analytics: return "Charts, insights, and history"
        case .settings: return "General and audio controls"
        case .model: return "Model selection and storage"
        case .about: return "Version and acknowledgments"
        }
    }
}

final class HomeNavigationState: ObservableObject {
    @Published var selectedSection: HomeSection = .overview
}
