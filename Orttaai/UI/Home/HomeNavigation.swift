// HomeNavigation.swift
// Orttaai

import Foundation
import Combine

enum HomeSection: String, CaseIterable, Identifiable, Hashable {
    case overview
    case chatAI
    case graph
    case memory
    case analytics
    case model
    case settings
    case about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: return "Overview"
        case .chatAI: return "ChatAI"
        case .graph: return "Graph"
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
        case .chatAI: return "bubble.left.and.text.bubble.right"
        case .graph: return "point.3.connected.trianglepath.dotted"
        case .memory: return "text.book.closed"
        case .analytics: return "chart.bar.xaxis"
        case .settings: return "gearshape"
        case .model: return "cpu"
        case .about: return "info.circle"
        }
    }

}

final class HomeNavigationState: ObservableObject {
    @Published var selectedSection: HomeSection = .overview
}
