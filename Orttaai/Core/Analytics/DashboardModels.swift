// DashboardModels.swift
// Orttaai

import Foundation

struct DashboardHeaderStats {
    let activeDays7d: Int
    let words7d: Int
    let averageWPM7d: Int
}

struct DashboardTodaySnapshot {
    let words: Int
    let sessions: Int
    let activeMinutes: Int
    let averageWPM: Int
}

struct DashboardTrendPoint: Identifiable {
    let dayStart: Date
    let words: Int
    let sessions: Int
    let averageWPM: Int

    var id: Date { dayStart }
}

struct DashboardTopApp: Identifiable {
    let name: String
    let sessions: Int
    let words: Int
    let sessionShare: Double

    var id: String { name }
}

enum DashboardPerformanceLevel {
    case noData
    case fast
    case normal
    case slow
}

struct DashboardPerformanceHealth {
    let level: DashboardPerformanceLevel
    let sampleCount: Int
    let averageProcessingMs: Int?
    let processingP50Ms: Int?
    let processingP95Ms: Int?
    let averageTranscriptionMs: Int?
    let transcriptionP50Ms: Int?
    let transcriptionP95Ms: Int?
    let averageInjectionMs: Int?
    let injectionP50Ms: Int?
    let injectionP95Ms: Int?
    let currentModelId: String
}

struct DashboardRecentDictation: Identifiable {
    let id: Int64
    let createdAt: Date
    let fullText: String
    let previewText: String
    let appName: String
    let wordCount: Int
    let processingMs: Int
}

struct DashboardStatsPayload {
    let header: DashboardHeaderStats
    let today: DashboardTodaySnapshot
    let trend7d: [DashboardTrendPoint]
    let topApps7d: [DashboardTopApp]
    let performance: DashboardPerformanceHealth
    let recent: [DashboardRecentDictation]
}

extension DashboardHeaderStats {
    static let empty = DashboardHeaderStats(activeDays7d: 0, words7d: 0, averageWPM7d: 0)
}

extension DashboardTodaySnapshot {
    static let empty = DashboardTodaySnapshot(words: 0, sessions: 0, activeMinutes: 0, averageWPM: 0)
}

extension DashboardPerformanceHealth {
    static let empty = DashboardPerformanceHealth(
        level: .noData,
        sampleCount: 0,
        averageProcessingMs: nil,
        processingP50Ms: nil,
        processingP95Ms: nil,
        averageTranscriptionMs: nil,
        transcriptionP50Ms: nil,
        transcriptionP95Ms: nil,
        averageInjectionMs: nil,
        injectionP50Ms: nil,
        injectionP95Ms: nil,
        currentModelId: "Not set"
    )
}

extension DashboardStatsPayload {
    static let empty = DashboardStatsPayload(
        header: .empty,
        today: .empty,
        trend7d: [],
        topApps7d: [],
        performance: .empty,
        recent: []
    )
}
