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
        let performance = makePerformance(
            from: weekRecords,
            modelSourceRecords: recentRecords,
            currentModelId: currentModelId
        )
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
        modelSourceRecords: [Transcription],
        currentModelId: String?
    ) -> DashboardPerformanceHealth {
        let modelId = resolvedModelId(currentModelId: currentModelId, records: modelSourceRecords)
        let modelScopedRecords = recordsForModel(modelId, in: records)
        let processingValues = modelScopedRecords.map { max(0, $0.processingDurationMs) }
        let transcriptionValues = modelScopedRecords.compactMap(\.transcriptionDurationMs)
        let injectionValues = modelScopedRecords.compactMap(\.injectionDurationMs)

        let avgProcessing = averageLatency(from: processingValues)
        let processingP50 = percentileLatency(from: processingValues, percentile: 0.50)
        let processingP95 = percentileLatency(from: processingValues, percentile: 0.95)
        let avgTranscription = averageLatency(from: transcriptionValues)
        let transcriptionP50 = percentileLatency(from: transcriptionValues, percentile: 0.50)
        let transcriptionP95 = percentileLatency(from: transcriptionValues, percentile: 0.95)
        let avgInjection = averageLatency(from: injectionValues)
        let injectionP50 = percentileLatency(from: injectionValues, percentile: 0.50)
        let injectionP95 = percentileLatency(from: injectionValues, percentile: 0.95)
        let level = performanceLevel(for: avgProcessing)

        return DashboardPerformanceHealth(
            level: level,
            sampleCount: modelScopedRecords.count,
            averageProcessingMs: avgProcessing,
            processingP50Ms: processingP50,
            processingP95Ms: processingP95,
            averageTranscriptionMs: avgTranscription,
            transcriptionP50Ms: transcriptionP50,
            transcriptionP95Ms: transcriptionP95,
            averageInjectionMs: avgInjection,
            injectionP50Ms: injectionP50,
            injectionP95Ms: injectionP95,
            currentModelId: modelId
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
        if let currentModelId {
            let normalized = canonicalModelID(currentModelId)
            if !normalized.isEmpty {
                return normalized
            }
        }
        if let recentModel = records.first?.modelId {
            let normalized = canonicalModelID(recentModel)
            if !normalized.isEmpty {
                return normalized
            }
        }
        return "Not set"
    }

    private func recordsForModel(_ modelId: String, in records: [Transcription]) -> [Transcription] {
        let normalizedTargetModel = canonicalModelID(modelId)
        guard !normalizedTargetModel.isEmpty else { return [] }

        return records.filter { record in
            canonicalModelID(record.modelId) == normalizedTargetModel
        }
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

    private func averageLatency(from values: [Int]) -> Int? {
        let valid = values.filter { $0 >= 0 }
        guard !valid.isEmpty else { return nil }
        return Int((Double(valid.reduce(0, +)) / Double(valid.count)).rounded())
    }

    private func percentileLatency(from values: [Int], percentile: Double) -> Int? {
        let valid = values.filter { $0 >= 0 }.sorted()
        guard !valid.isEmpty else { return nil }

        let p = max(0, min(percentile, 1))
        guard valid.count > 1 else { return valid[0] }

        let rank = p * Double(valid.count - 1)
        let lowerIndex = Int(rank.rounded(.down))
        let upperIndex = Int(rank.rounded(.up))

        if lowerIndex == upperIndex {
            return valid[lowerIndex]
        }

        let weight = rank - Double(lowerIndex)
        let lower = Double(valid[lowerIndex])
        let upper = Double(valid[upperIndex])
        return Int((lower + (upper - lower) * weight).rounded())
    }

    private func canonicalModelID(_ modelId: String) -> String {
        let trimmed = modelId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        let pattern = #"_\d+(mb|gb)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return trimmed
        }
        let range = NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)
        if let match = regex.firstMatch(in: trimmed, options: [], range: range),
           match.range.location != NSNotFound,
           let swiftRange = Range(match.range, in: trimmed),
           swiftRange.upperBound == trimmed.endIndex
        {
            return String(trimmed[..<swiftRange.lowerBound])
        }
        return trimmed
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
