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
    case milestones
    case coach
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
        case .milestones: return "Milestones"
        case .coach: return "Coach"
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
        case .milestones: return "rosette"
        case .coach: return "scope"
        case .settings: return "gearshape"
        case .model: return "cpu"
        case .about: return "info.circle"
        }
    }

}

final class HomeNavigationState: ObservableObject {
    @Published var selectedSection: HomeSection = .overview
    /// A question another page handed to Chat AI; Chat AI sends it in a new
    /// chat and clears it.
    @Published var pendingChatPrompt: String?

    /// The Model page tab to open on next; cleared once it has opened.
    @Published var pendingModelSection: ModelPageSection?

    /// Set to open Memory on its Suggestions tab; Memory clears it.
    @Published var openMemorySuggestions = false

    /// The share sheet's subject while it is open, from the Milestones page,
    /// a celebration or the corner toast.
    @Published var milestoneShareSubject: MilestoneShareSubject?

    func shareMilestone(_ subject: MilestoneShareSubject) {
        milestoneShareSubject = subject
    }

    func askChatAI(_ prompt: String) {
        pendingChatPrompt = prompt
        selectedSection = .chatAI
    }

    func openAISettings() {
        pendingModelSection = .ai
        selectedSection = .model
    }
}
