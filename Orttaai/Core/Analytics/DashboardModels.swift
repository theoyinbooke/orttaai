// DashboardModels.swift
// Orttaai

import Foundation

nonisolated struct DashboardHeaderStats {
    let activeDays: Int
    let totalWords: Int
    let averageWPM: Int
}

nonisolated struct DashboardTodaySnapshot {
    let words: Int
    let sessions: Int
    let activeMinutes: Int
    let averageWPM: Int
}

nonisolated struct DashboardTrendPoint: Identifiable {
    let dayStart: Date
    let words: Int
    let sessions: Int
    let averageWPM: Int

    var id: Date { dayStart }
}

nonisolated struct DashboardTopApp: Identifiable {
    let name: String
    let sessions: Int
    let words: Int
    let sessionShare: Double

    var id: String { name }
}

nonisolated enum DashboardPerformanceLevel {
    case noData
    case fast
    case normal
    case slow
}

/// How long this Mac's latest dictations took, from key release to the text
/// in place (`DashboardStatsService.performanceSampleCount` of them), and
/// each stage's share: transcription, text processing (rules, dictionary
/// and Polish), then insertion.
nonisolated struct DashboardPerformanceHealth {
    let level: DashboardPerformanceLevel
    let sampleCount: Int
    let averageProcessingMs: Int?
    let processingP50Ms: Int?
    let processingP95Ms: Int?
    let averageTranscriptionMs: Int?
    let transcriptionP50Ms: Int?
    let transcriptionP95Ms: Int?
    let averageTextProcessingMs: Int?
    let textProcessingP50Ms: Int?
    let textProcessingP95Ms: Int?
    let averageInjectionMs: Int?
    let injectionP50Ms: Int?
    let injectionP95Ms: Int?
    let currentModelId: String
}

nonisolated struct DashboardRecentDictation: Identifiable {
    let id: Int64
    let createdAt: Date
    let fullText: String
    let previewText: String
    let appName: String
    let wordCount: Int
    let processingMs: Int
}

/// One device's share of the dictations in a range.
nonisolated struct DeviceBreakdownRow: Identifiable, Equatable {
    /// The device ID, or "unknown" for dictations whose device isn't known.
    let id: String
    let name: String
    /// "mac", "iphone", "ipad" or "unknown", for its symbol.
    let kindName: String?
    let isThisMac: Bool
    var words: Int
    var dictations: Int
}

nonisolated struct DashboardStatsPayload {
    let header: DashboardHeaderStats
    let today: DashboardTodaySnapshot
    let trend30d: [DashboardTrendPoint]
    let topApps30d: [DashboardTopApp]
    let performance: DashboardPerformanceHealth
    let recent: [DashboardRecentDictation]
}

nonisolated extension DashboardHeaderStats {
    static let empty = DashboardHeaderStats(activeDays: 0, totalWords: 0, averageWPM: 0)
}

nonisolated extension DashboardTodaySnapshot {
    static let empty = DashboardTodaySnapshot(words: 0, sessions: 0, activeMinutes: 0, averageWPM: 0)
}

nonisolated extension DashboardPerformanceHealth {
    static let empty = DashboardPerformanceHealth(
        level: .noData,
        sampleCount: 0,
        averageProcessingMs: nil,
        processingP50Ms: nil,
        processingP95Ms: nil,
        averageTranscriptionMs: nil,
        transcriptionP50Ms: nil,
        transcriptionP95Ms: nil,
        averageTextProcessingMs: nil,
        textProcessingP50Ms: nil,
        textProcessingP95Ms: nil,
        averageInjectionMs: nil,
        injectionP50Ms: nil,
        injectionP95Ms: nil,
        currentModelId: "Not set"
    )
}

nonisolated extension DashboardStatsPayload {
    static let empty = DashboardStatsPayload(
        header: .empty,
        today: .empty,
        trend30d: [],
        topApps30d: [],
        performance: .empty,
        recent: []
    )
}
