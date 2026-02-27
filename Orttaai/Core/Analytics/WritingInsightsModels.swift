// WritingInsightsModels.swift
// Orttaai

import Foundation

enum WritingInsightsTimeRange: String, CaseIterable, Identifiable, Sendable, Codable {
    case days7
    case days14
    case days30
    case days90
    case all

    var id: String { rawValue }

    var title: String {
        switch self {
        case .days7:
            return "7d"
        case .days14:
            return "14d"
        case .days30:
            return "30d"
        case .days90:
            return "90d"
        case .all:
            return "All"
        }
    }

    func startDate(relativeTo now: Date = Date(), calendar: Calendar = .current) -> Date? {
        switch self {
        case .days7:
            return calendar.date(byAdding: .day, value: -7, to: now)
        case .days14:
            return calendar.date(byAdding: .day, value: -14, to: now)
        case .days30:
            return calendar.date(byAdding: .day, value: -30, to: now)
        case .days90:
            return calendar.date(byAdding: .day, value: -90, to: now)
        case .all:
            return nil
        }
    }
}

enum WritingInsightsGenerationMode: String, CaseIterable, Identifiable, Sendable, Codable {
    case balanced
    case deep

    var id: String { rawValue }

    var title: String {
        switch self {
        case .balanced:
            return "Balanced"
        case .deep:
            return "Deep"
        }
    }

    var historyLimit: Int {
        switch self {
        case .balanced:
            return 120
        case .deep:
            return 300
        }
    }
}

enum WritingInsightsAppFilterMode: String, CaseIterable, Identifiable, Sendable, Codable {
    case allApps
    case includeOnly
    case exclude

    var id: String { rawValue }

    var title: String {
        switch self {
        case .allApps:
            return "All apps"
        case .includeOnly:
            return "Include"
        case .exclude:
            return "Exclude"
        }
    }
}

struct WritingInsightsRequest: Sendable, Codable, Equatable {
    var timeRange: WritingInsightsTimeRange
    var generationMode: WritingInsightsGenerationMode
    var appFilterMode: WritingInsightsAppFilterMode
    var selectedApps: [String]

    static let `default` = WritingInsightsRequest(
        timeRange: .days30,
        generationMode: .balanced,
        appFilterMode: .allApps,
        selectedApps: []
    )
}

enum WritingInsightRecommendationKind: String, Sendable, Codable {
    case dictionary
    case snippet

    var actionTitle: String {
        switch self {
        case .dictionary:
            return "Add to Dictionary"
        case .snippet:
            return "Add as Snippet"
        }
    }
}

struct WritingInsightRecommendation: Identifiable, Sendable, Codable, Hashable {
    var id: UUID
    let kind: WritingInsightRecommendationKind
    let source: String
    let target: String
    let rationale: String
    let confidence: Double

    init(
        id: UUID = UUID(),
        kind: WritingInsightRecommendationKind,
        source: String,
        target: String,
        rationale: String,
        confidence: Double
    ) {
        self.id = id
        self.kind = kind
        self.source = source
        self.target = target
        self.rationale = rationale
        self.confidence = confidence
    }

    var stableKey: String {
        let normalizedSource = source.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalizedTarget = target.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return "\(kind.rawValue)|\(normalizedSource)|\(normalizedTarget)"
    }
}

struct WritingInsightSignal: Identifiable, Sendable, Codable {
    var id: UUID
    let label: String
    let value: String
    let detail: String

    init(id: UUID = UUID(), label: String, value: String, detail: String) {
        self.id = id
        self.label = label
        self.value = value
        self.detail = detail
    }
}

struct WritingInsightPattern: Identifiable, Sendable, Codable {
    var id: UUID
    let title: String
    let detail: String
    let evidence: String?

    init(id: UUID = UUID(), title: String, detail: String, evidence: String?) {
        self.id = id
        self.title = title
        self.detail = detail
        self.evidence = evidence
    }
}

struct WritingInsightSnapshot: Sendable, Codable {
    let generatedAt: Date
    let sampleCount: Int
    let analyzerName: String
    let usedFallback: Bool
    let request: WritingInsightsRequest
    let summary: String
    let signals: [WritingInsightSignal]
    let patterns: [WritingInsightPattern]
    let strengths: [String]
    let opportunities: [String]
    let recommendations: [WritingInsightRecommendation]
}

struct WritingInsightsRunResult: Sendable {
    let snapshot: WritingInsightSnapshot?
    let persistedSnapshotID: Int64?
    let sampleCount: Int
    let analyzerName: String
    let usedFallback: Bool
    let errorMessage: String?
    let persistenceWarning: String?
}

struct WritingInsightHistoryItem: Identifiable, Sendable {
    let id: Int64
    let isPinned: Bool
    let snapshot: WritingInsightSnapshot
}

struct WritingInsightsComparison: Sendable {
    let older: WritingInsightHistoryItem
    let newer: WritingInsightHistoryItem
    let headline: String
    let bullets: [String]
}

enum WritingInsightFreshnessStatus: String, Sendable {
    case fresh
    case aging
    case stale

    var title: String {
        switch self {
        case .fresh:
            return "Fresh"
        case .aging:
            return "Aging"
        case .stale:
            return "Stale"
        }
    }
}

struct WritingInsightFreshness: Sendable {
    let newSessionCount: Int
    let latestSessionAt: Date?
    let status: WritingInsightFreshnessStatus
    let shouldAutoRefresh: Bool
}
