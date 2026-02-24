// DashboardStatsService.swift
// Orttaai

import Foundation
import GRDB

final class DashboardStatsService {
    private let databaseManager: DatabaseManager
    private let calendar: Calendar
    private let nowProvider: () -> Date

    init(
        databaseManager: DatabaseManager,
        calendar: Calendar = .current,
        now: @escaping () -> Date = Date.init
    ) {
        self.databaseManager = databaseManager
        self.calendar = calendar
        self.nowProvider = now
    }

    func load(currentModelId: String? = nil) throws -> DashboardStatsPayload {
        let now = nowProvider()
        let todayStart = calendar.startOfDay(for: now)
        let tomorrowStart = calendar.date(byAdding: .day, value: 1, to: todayStart) ?? now
        let weekStart = calendar.date(byAdding: .day, value: -6, to: todayStart) ?? todayStart

        let weekRecords = try databaseManager.fetchTranscriptions(from: weekStart, to: tomorrowStart)
        let todayRecords = weekRecords.filter { $0.createdAt >= todayStart && $0.createdAt < tomorrowStart }
        let recentRecords = try databaseManager.fetchRecent(limit: 12)

        let header = makeHeaderStats(from: weekRecords)
        let today = makeTodaySnapshot(from: todayRecords)
        let trend7d = makeTrendPoints(from: weekRecords, startDay: weekStart)
        let topApps7d = makeTopApps(from: weekRecords)
        let performance = makePerformance(from: weekRecords, currentModelId: currentModelId)
        let recent = makeRecentDictations(from: recentRecords)

        return DashboardStatsPayload(
            header: header,
            today: today,
            trend7d: trend7d,
            topApps7d: topApps7d,
            performance: performance,
            recent: recent
        )
    }

    func observeChanges(_ onChange: @escaping () -> Void) -> DatabaseCancellable {
        databaseManager.observeTranscriptions { _ in
            onChange()
        }
    }

    func deleteRecentDictation(id: Int64) throws {
        _ = try databaseManager.deleteTranscription(id: id)
    }

    // MARK: - Builders

    private func makeHeaderStats(from records: [Transcription]) -> DashboardHeaderStats {
        let words = records.reduce(0) { $0 + countWords(in: $1.text) }
        let recordingMs = records.reduce(0) { $0 + max(0, $1.recordingDurationMs) }
        let days = Set(records.map { calendar.startOfDay(for: $0.createdAt) }).count

        return DashboardHeaderStats(
            activeDays7d: days,
            words7d: words,
            averageWPM7d: calculateWPM(words: words, recordingMs: recordingMs)
        )
    }

    private func makeTodaySnapshot(from records: [Transcription]) -> DashboardTodaySnapshot {
        let words = records.reduce(0) { $0 + countWords(in: $1.text) }
        let recordingMs = records.reduce(0) { $0 + max(0, $1.recordingDurationMs) }
        let minutes = Int((Double(recordingMs) / 60_000).rounded())

        return DashboardTodaySnapshot(
            words: words,
            sessions: records.count,
            activeMinutes: minutes,
            averageWPM: calculateWPM(words: words, recordingMs: recordingMs)
        )
    }

    private func makeTrendPoints(from records: [Transcription], startDay: Date) -> [DashboardTrendPoint] {
        var aggregatesByDay: [Date: DayAggregate] = [:]

        for record in records {
            let day = calendar.startOfDay(for: record.createdAt)
            var aggregate = aggregatesByDay[day, default: DayAggregate()]
            aggregate.words += countWords(in: record.text)
            aggregate.sessions += 1
            aggregate.recordingMs += max(0, record.recordingDurationMs)
            aggregatesByDay[day] = aggregate
        }

        return (0...6).compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: offset, to: startDay) else {
                return nil
            }
            let aggregate = aggregatesByDay[day, default: DayAggregate()]
            return DashboardTrendPoint(
                dayStart: day,
                words: aggregate.words,
                sessions: aggregate.sessions,
                averageWPM: calculateWPM(words: aggregate.words, recordingMs: aggregate.recordingMs)
            )
        }
    }

    private func makeTopApps(from records: [Transcription]) -> [DashboardTopApp] {
        struct AppAggregate {
            var sessions: Int = 0
            var words: Int = 0
        }

        var byApp: [String: AppAggregate] = [:]
        for record in records {
            let appName = normalizedAppName(record.targetAppName)
            var aggregate = byApp[appName, default: AppAggregate()]
            aggregate.sessions += 1
            aggregate.words += countWords(in: record.text)
            byApp[appName] = aggregate
        }

        let totalSessions = max(1, records.count)
        return byApp
            .map { name, aggregate in
                DashboardTopApp(
                    name: name,
                    sessions: aggregate.sessions,
                    words: aggregate.words,
                    sessionShare: Double(aggregate.sessions) / Double(totalSessions)
                )
            }
            .sorted {
                if $0.sessions == $1.sessions {
                    return $0.words > $1.words
                }
                return $0.sessions > $1.sessions
            }
            .prefix(5)
            .map { $0 }
    }

    private func makePerformance(
        from records: [Transcription],
        currentModelId: String?
    ) -> DashboardPerformanceHealth {
        let avgProcessing: Int? = records.isEmpty
            ? nil
            : Int((Double(records.reduce(0) { $0 + max(0, $1.processingDurationMs) }) / Double(records.count)).rounded())
        let level = performanceLevel(for: avgProcessing)
        let recommendation = recommendationText(for: level)
        let modelId = resolvedModelId(currentModelId: currentModelId, records: records)

        return DashboardPerformanceHealth(
            level: level,
            averageProcessingMs: avgProcessing,
            currentModelId: modelId,
            recommendation: recommendation
        )
    }

    private func makeRecentDictations(from records: [Transcription]) -> [DashboardRecentDictation] {
        records.map { record in
            let wordCount = countWords(in: record.text)
            return DashboardRecentDictation(
                id: record.id ?? Int64(record.createdAt.timeIntervalSince1970 * 1_000),
                createdAt: record.createdAt,
                fullText: record.text,
                previewText: previewText(record.text),
                appName: normalizedAppName(record.targetAppName),
                wordCount: wordCount,
                processingMs: max(0, record.processingDurationMs)
            )
        }
    }

    // MARK: - Helpers

    private func countWords(in text: String) -> Int {
        text.split(whereSeparator: \.isWhitespace).count
    }

    private func calculateWPM(words: Int, recordingMs: Int) -> Int {
        guard words > 0, recordingMs > 0 else { return 0 }
        let minutes = Double(recordingMs) / 60_000
        guard minutes > 0 else { return 0 }
        return Int((Double(words) / minutes).rounded())
    }

    private func normalizedAppName(_ rawName: String?) -> String {
        guard let rawName else { return "Unknown App" }
        let trimmed = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Unknown App" : trimmed
    }

    private func resolvedModelId(currentModelId: String?, records: [Transcription]) -> String {
        if let currentModelId, !currentModelId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return currentModelId
        }
        if let recentModel = records.first?.modelId, !recentModel.isEmpty {
            return recentModel
        }
        return "Not set"
    }

    private func performanceLevel(for averageProcessingMs: Int?) -> DashboardPerformanceLevel {
        guard let averageProcessingMs else { return .noData }
        if averageProcessingMs < 1_200 {
            return .fast
        }
        if averageProcessingMs < 3_000 {
            return .normal
        }
        return .slow
    }

    private func recommendationText(for level: DashboardPerformanceLevel) -> String {
        switch level {
        case .noData:
            return "Complete a few dictations to unlock performance insights."
        case .fast:
            return "Performance looks great. Keep your current model."
        case .normal:
            return "Performance is stable. Try a smaller model if you want lower latency."
        case .slow:
            return "Latency is high. Switch to a smaller model in Settings > Model."
        }
    }

    private func previewText(_ text: String, limit: Int = 120) -> String {
        let singleLine = text
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard singleLine.count > limit else { return singleLine }
        let cutoff = singleLine.index(singleLine.startIndex, offsetBy: limit)
        return "\(singleLine[..<cutoff])..."
    }
}

private struct DayAggregate {
    var words: Int = 0
    var sessions: Int = 0
    var recordingMs: Int = 0
}
