// WritingInsightsService.swift
// Orttaai

import Foundation
import os

#if canImport(FoundationModels)
import FoundationModels
#endif

struct WritingInsightPayload: Sendable {
    let summary: String
    let signals: [WritingInsightSignal]
    let patterns: [WritingInsightPattern]
    let strengths: [String]
    let opportunities: [String]
}

protocol WritingInsightAnalyzing {
    var name: String { get }
    func isAvailable() -> Bool
    func analyze(transcriptions: [Transcription]) async -> WritingInsightPayload?
}

final class HeuristicWritingInsightAnalyzer: WritingInsightAnalyzing {
    let name = "Heuristic Analyzer"

    func isAvailable() -> Bool {
        true
    }

    func analyze(transcriptions: [Transcription]) async -> WritingInsightPayload? {
        guard !transcriptions.isEmpty else { return nil }

        let totalWords = transcriptions.reduce(0) { partial, record in
            partial + record.text.split(whereSeparator: \.isWhitespace).count
        }
        let totalDurationMs = transcriptions.reduce(0) { partial, record in
            partial + max(0, record.recordingDurationMs)
        }
        let averageWordsPerSession = transcriptions.isEmpty ? 0 : Int((Double(totalWords) / Double(transcriptions.count)).rounded())
        let averageDurationSeconds = transcriptions.isEmpty ? 0 : Int((Double(totalDurationMs) / Double(max(1, transcriptions.count) * 1_000)).rounded())

        var appCounts: [String: Int] = [:]
        var timeOfDayCounts: [String: Int] = ["Morning": 0, "Afternoon": 0, "Evening": 0, "Night": 0]
        var openingPhraseCounts: [String: Int] = [:]
        var fillerCounts: [String: Int] = [:]

        for record in transcriptions {
            let appName = normalizedAppName(record.targetAppName)
            appCounts[appName, default: 0] += 1

            let hour = Calendar.current.component(.hour, from: record.createdAt)
            let bucket = timeBucket(forHour: hour)
            timeOfDayCounts[bucket, default: 0] += 1

            if let opening = openingPhrase(from: record.text) {
                openingPhraseCounts[opening, default: 0] += 1
            }

            let lowered = " \(record.text.lowercased()) "
            for filler in fillerLexicon {
                if lowered.contains(" \(filler) ") {
                    fillerCounts[filler, default: 0] += 1
                }
            }
        }

        let topApp = appCounts.max(by: { $0.value < $1.value })?.key ?? "Unknown App"
        let topAppSessions = appCounts[topApp] ?? 0
        let topTimeBucket = timeOfDayCounts.max(by: { $0.value < $1.value })?.key ?? "Morning"
        let topOpening = openingPhraseCounts.max(by: { $0.value < $1.value })
        let topFiller = fillerCounts.max(by: { $0.value < $1.value })

        let summary = """
        You are most active in \(topTimeBucket.lowercased()) sessions, averaging \(averageWordsPerSession) words per dictation.
        \(topApp) is your primary context (\(topAppSessions) of \(transcriptions.count) sessions).
        """

        var patterns: [WritingInsightPattern] = [
            WritingInsightPattern(
                title: "Primary writing context",
                detail: "Most of your recent dictations happen in \(topApp).",
                evidence: "\(topAppSessions) out of \(transcriptions.count) sessions"
            ),
            WritingInsightPattern(
                title: "Session length",
                detail: "You average \(averageWordsPerSession) words over about \(max(1, averageDurationSeconds)) seconds per session.",
                evidence: "\(totalWords) words across \(transcriptions.count) sessions"
            ),
            WritingInsightPattern(
                title: "Peak writing window",
                detail: "Your strongest activity is in the \(topTimeBucket.lowercased()).",
                evidence: "\(timeOfDayCounts[topTimeBucket, default: 0]) sessions"
            )
        ]

        if let topOpening, topOpening.value > 1 {
            patterns.append(
                WritingInsightPattern(
                    title: "Frequent opening phrase",
                    detail: "You often start with “\(topOpening.key)”.",
                    evidence: "Appeared \(topOpening.value)x"
                )
            )
        }

        if let topFiller, topFiller.value > 1 {
            patterns.append(
                WritingInsightPattern(
                    title: "Filler habit",
                    detail: "You frequently use “\(topFiller.key)”.",
                    evidence: "Detected in \(topFiller.value)x transcripts"
                )
            )
        }

        let signals: [WritingInsightSignal] = [
            WritingInsightSignal(
                label: "Sessions",
                value: "\(transcriptions.count)",
                detail: "Analyzed from recent history"
            ),
            WritingInsightSignal(
                label: "Words",
                value: totalWords.formatted(),
                detail: "Total dictated words"
            ),
            WritingInsightSignal(
                label: "Avg/session",
                value: "\(averageWordsPerSession) words",
                detail: "Typical dictation length"
            ),
            WritingInsightSignal(
                label: "Avg duration",
                value: "\(max(1, averageDurationSeconds))s",
                detail: "Estimated speaking time"
            )
        ]

        var strengths: [String] = [
            "You have consistent dictation activity in one main writing context.",
            "Your sessions are frequent enough to build personal writing patterns quickly."
        ]

        if averageWordsPerSession >= 20 {
            strengths.append("You sustain longer-form dictation, which helps idea development.")
        } else {
            strengths.append("Your short sessions are efficient for quick capture workflows.")
        }

        var opportunities: [String] = []
        if let topFiller, topFiller.value > 2 {
            opportunities.append("Reduce “\(topFiller.key)” in final drafts to improve clarity.")
        }
        if let topOpening, topOpening.value > 3 {
            opportunities.append("Vary your opening line to avoid repetitive starts.")
        }
        if opportunities.isEmpty {
            opportunities = [
                "Create snippets for your most repeated openings to save time.",
                "Review history weekly to spot recurring phrasing you want to refine."
            ]
        }

        return WritingInsightPayload(
            summary: summary,
            signals: signals,
            patterns: Array(patterns.prefix(6)),
            strengths: Array(strengths.prefix(4)),
            opportunities: Array(opportunities.prefix(4))
        )
    }

    private var fillerLexicon: [String] {
        ["um", "uh", "like", "you know", "basically", "actually"]
    }

    private func normalizedAppName(_ appName: String?) -> String {
        guard let appName else { return "Unknown App" }
        let trimmed = appName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Unknown App" : trimmed
    }

    private func timeBucket(forHour hour: Int) -> String {
        switch hour {
        case 5..<12:
            return "Morning"
        case 12..<17:
            return "Afternoon"
        case 17..<22:
            return "Evening"
        default:
            return "Night"
        }
    }

    private func openingPhrase(from text: String) -> String? {
        let words = text
            .lowercased()
            .replacingOccurrences(of: "\n", with: " ")
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
            .filter { !$0.isEmpty }

        guard words.count >= 2 else { return nil }
        let phraseCount = min(3, words.count)
        let phrase = words.prefix(phraseCount).joined(separator: " ")
            .trimmingCharacters(in: .punctuationCharacters.union(.whitespacesAndNewlines))
        guard phrase.count >= 4 else { return nil }
        return phrase
    }
}

final class AppleFoundationWritingInsightAnalyzer: WritingInsightAnalyzing {
    let name = "Apple Foundation Models"

    func isAvailable() -> Bool {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            let model = SystemLanguageModel.default
            if case .available = model.availability {
                return true
            }
        }
        #endif
        return false
    }

    func analyze(transcriptions: [Transcription]) async -> WritingInsightPayload? {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            let historyLines = transcriptions
                .prefix(120)
                .map { record -> String in
                    let text = record.text
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        .replacingOccurrences(of: "\n", with: " ")
                        .replacingOccurrences(of: "\r", with: " ")
                    guard !text.isEmpty else { return "" }
                    let clamped = text.count > 220 ? String(text.prefix(220)) + "..." : text
                    let app = normalizedAppName(record.targetAppName)
                    return "\(app): \(clamped)"
                }
                .filter { !$0.isEmpty }

            guard !historyLines.isEmpty else { return nil }

            let prompt = """
            Analyze this user's dictation history and produce concise writing insights.

            Return ONLY valid JSON matching exactly:
            {
              "summary": "one short paragraph",
              "signals": [
                {"label": "Sessions", "value": "12", "detail": "short note"}
              ],
              "patterns": [
                {"title": "pattern title", "detail": "what this means", "evidence": "proof"}
              ],
              "strengths": ["short bullet", "short bullet"],
              "opportunities": ["short bullet", "short bullet"]
            }

            Rules:
            - Keep summary under 55 words.
            - Max 4 signals, 6 patterns, 4 strengths, 4 opportunities.
            - Use clear, practical language.
            - Focus on writing habits, structure, and productivity patterns.

            History:
            \(historyLines.enumerated().map { "[\($0.offset + 1)] \($0.element)" }.joined(separator: "\n"))
            """

            do {
                let session = LanguageModelSession()
                let response = try await session.respond(to: prompt)
                guard let jsonPayload = extractJSONObject(from: response.content) else {
                    Logger.memory.warning("Apple FM insights response did not contain JSON")
                    return nil
                }
                guard let data = jsonPayload.data(using: .utf8) else { return nil }
                let parsed = try JSONDecoder().decode(AppleWritingInsightsResponse.self, from: data)
                return sanitize(parsed)
            } catch {
                Logger.memory.error("Apple FM insights analysis failed: \(error.localizedDescription)")
                return nil
            }
        }
        #endif
        return nil
    }

    private func sanitize(_ parsed: AppleWritingInsightsResponse) -> WritingInsightPayload {
        let summary = parsed.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        let signals = parsed.signals.prefix(4).compactMap { signal -> WritingInsightSignal? in
            let label = signal.label.trimmingCharacters(in: .whitespacesAndNewlines)
            let value = signal.value.trimmingCharacters(in: .whitespacesAndNewlines)
            let detail = signal.detail.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !label.isEmpty, !value.isEmpty else { return nil }
            return WritingInsightSignal(label: label, value: value, detail: detail)
        }
        let patterns = parsed.patterns.prefix(6).compactMap { pattern -> WritingInsightPattern? in
            let title = pattern.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let detail = pattern.detail.trimmingCharacters(in: .whitespacesAndNewlines)
            let evidence = pattern.evidence?.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty, !detail.isEmpty else { return nil }
            return WritingInsightPattern(
                title: title,
                detail: detail,
                evidence: evidence?.isEmpty == true ? nil : evidence
            )
        }
        let strengths = parsed.strengths
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .prefix(4)
            .map { $0 }
        let opportunities = parsed.opportunities
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .prefix(4)
            .map { $0 }

        return WritingInsightPayload(
            summary: summary.isEmpty ? "Insights generated from your recent dictation sessions." : summary,
            signals: signals,
            patterns: patterns,
            strengths: strengths,
            opportunities: opportunities
        )
    }

    private func normalizedAppName(_ appName: String?) -> String {
        guard let appName else { return "Unknown App" }
        let trimmed = appName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Unknown App" : trimmed
    }

    private func extractJSONObject(from text: String) -> String? {
        guard let firstBrace = text.firstIndex(of: "{"),
              let lastBrace = text.lastIndex(of: "}") else {
            return nil
        }
        return String(text[firstBrace...lastBrace])
    }
}

final class WritingInsightsService {
    private let databaseManager: DatabaseManager
    private let appleAnalyzer: WritingInsightAnalyzing
    private let heuristicAnalyzer: WritingInsightAnalyzing
    private let agingSessionThreshold = 6
    private let staleSessionThreshold = 14
    private let autoRefreshThreshold = 20

    init(
        databaseManager: DatabaseManager,
        appleAnalyzer: WritingInsightAnalyzing = AppleFoundationWritingInsightAnalyzer(),
        heuristicAnalyzer: WritingInsightAnalyzing = HeuristicWritingInsightAnalyzer()
    ) {
        self.databaseManager = databaseManager
        self.appleAnalyzer = appleAnalyzer
        self.heuristicAnalyzer = heuristicAnalyzer
    }

    func generateInsights(request: WritingInsightsRequest = .default) async -> WritingInsightsRunResult {
        do {
            let history = try filteredHistory(request: request)
            guard !history.isEmpty else {
                return WritingInsightsRunResult(
                    snapshot: nil,
                    persistedSnapshotID: nil,
                    sampleCount: 0,
                    analyzerName: heuristicAnalyzer.name,
                    usedFallback: false,
                    errorMessage: nil,
                    persistenceWarning: nil
                )
            }

            let shouldUseApple = appleAnalyzer.isAvailable()
            let primaryAnalyzer = shouldUseApple ? appleAnalyzer : heuristicAnalyzer
            var usedFallback = false

            var payload = await primaryAnalyzer.analyze(transcriptions: history)
            if payload == nil && shouldUseApple {
                payload = await heuristicAnalyzer.analyze(transcriptions: history)
                usedFallback = true
            }

            guard let payload else {
                return WritingInsightsRunResult(
                    snapshot: nil,
                    persistedSnapshotID: nil,
                    sampleCount: history.count,
                    analyzerName: shouldUseApple ? appleAnalyzer.name : heuristicAnalyzer.name,
                    usedFallback: usedFallback,
                    errorMessage: "Couldn't generate insights yet.",
                    persistenceWarning: nil
                )
            }

            let resolvedAnalyzerName = shouldUseApple && !usedFallback ? appleAnalyzer.name : heuristicAnalyzer.name
            let snapshot = WritingInsightSnapshot(
                generatedAt: Date(),
                sampleCount: history.count,
                analyzerName: resolvedAnalyzerName,
                usedFallback: usedFallback,
                request: request,
                summary: payload.summary,
                signals: payload.signals,
                patterns: payload.patterns,
                strengths: payload.strengths,
                opportunities: payload.opportunities,
                recommendations: []
            )

            var persistedSnapshotID: Int64?
            var persistenceWarning: String?
            do {
                persistedSnapshotID = try databaseManager.saveWritingInsightSnapshot(snapshot)
            } catch {
                Logger.memory.error("Failed to persist writing insights snapshot: \(error.localizedDescription)")
                persistenceWarning = "Insights generated, but couldn't persist snapshot."
            }

            return WritingInsightsRunResult(
                snapshot: snapshot,
                persistedSnapshotID: persistedSnapshotID,
                sampleCount: history.count,
                analyzerName: resolvedAnalyzerName,
                usedFallback: usedFallback,
                errorMessage: nil,
                persistenceWarning: persistenceWarning
            )
        } catch {
            Logger.memory.error("Failed to generate writing insights: \(error.localizedDescription)")
            return WritingInsightsRunResult(
                snapshot: nil,
                persistedSnapshotID: nil,
                sampleCount: 0,
                analyzerName: heuristicAnalyzer.name,
                usedFallback: false,
                errorMessage: "Couldn't generate insights yet.",
                persistenceWarning: nil
            )
        }
    }

    func loadLatestSnapshot() -> WritingInsightSnapshot? {
        do {
            return try databaseManager.fetchLatestWritingInsightSnapshot()
        } catch {
            Logger.memory.error("Failed to load latest writing insight snapshot: \(error.localizedDescription)")
            return nil
        }
    }

    func loadRecentSnapshots(limit: Int = 30) -> [WritingInsightSnapshot] {
        do {
            return try databaseManager.fetchWritingInsightSnapshots(limit: limit)
        } catch {
            Logger.memory.error("Failed to load writing insight snapshots: \(error.localizedDescription)")
            return []
        }
    }

    func loadRecentHistoryItems(limit: Int = 30) -> [WritingInsightHistoryItem] {
        do {
            return try databaseManager.fetchWritingInsightHistory(limit: limit)
        } catch {
            Logger.memory.error("Failed to load writing insight history: \(error.localizedDescription)")
            return []
        }
    }

    func loadAvailableApps(limit: Int = 60) -> [String] {
        do {
            return try databaseManager.fetchDistinctTargetAppNames(limit: limit)
        } catch {
            Logger.memory.error("Failed to fetch app list for insights: \(error.localizedDescription)")
            return []
        }
    }

    func freshness(for snapshot: WritingInsightSnapshot) -> WritingInsightFreshness {
        do {
            let newSessionCount = try databaseManager.countTranscriptions(since: snapshot.generatedAt)
            let latestSessionAt = try databaseManager.fetchLatestTranscriptionDate()
            let status: WritingInsightFreshnessStatus
            if newSessionCount >= staleSessionThreshold {
                status = .stale
            } else if newSessionCount >= agingSessionThreshold {
                status = .aging
            } else {
                status = .fresh
            }

            return WritingInsightFreshness(
                newSessionCount: newSessionCount,
                latestSessionAt: latestSessionAt,
                status: status,
                shouldAutoRefresh: newSessionCount >= autoRefreshThreshold
            )
        } catch {
            Logger.memory.error("Failed to compute insight freshness: \(error.localizedDescription)")
            return WritingInsightFreshness(
                newSessionCount: 0,
                latestSessionAt: nil,
                status: .fresh,
                shouldAutoRefresh: false
            )
        }
    }

    func applyRecommendation(_ recommendation: WritingInsightRecommendation) throws {
        switch recommendation.kind {
        case .dictionary:
            _ = try databaseManager.upsertDictionaryEntry(
                source: recommendation.source,
                target: recommendation.target,
                isCaseSensitive: false,
                isActive: true
            )
        case .snippet:
            _ = try databaseManager.upsertSnippetEntry(
                trigger: recommendation.source,
                expansion: recommendation.target,
                isActive: true
            )
        }
    }

    func setSnapshotPinned(id: Int64, isPinned: Bool) throws {
        try databaseManager.setWritingInsightSnapshotPinned(id: id, isPinned: isPinned)
    }

    @discardableResult
    func deleteSnapshot(id: Int64) throws -> Bool {
        try databaseManager.deleteWritingInsightSnapshot(id: id)
    }

    private func filteredHistory(request: WritingInsightsRequest) throws -> [Transcription] {
        let allHistory = try databaseManager.fetchRecent(limit: 500)
        guard !allHistory.isEmpty else { return [] }

        let normalizedSelectedApps = Set(
            request.selectedApps
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                .filter { !$0.isEmpty }
        )

        let startDate = request.timeRange.startDate()

        let filtered = allHistory.filter { record in
            if let startDate, record.createdAt < startDate {
                return false
            }

            guard request.appFilterMode != .allApps else {
                return true
            }

            guard !normalizedSelectedApps.isEmpty else {
                return true
            }

            let appName = (record.targetAppName ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()

            switch request.appFilterMode {
            case .allApps:
                return true
            case .includeOnly:
                return normalizedSelectedApps.contains(appName)
            case .exclude:
                return !normalizedSelectedApps.contains(appName)
            }
        }

        return Array(filtered.prefix(request.generationMode.historyLimit))
    }

}

private struct AppleWritingInsightsResponse: Decodable {
    let summary: String
    let signals: [AppleInsightSignal]
    let patterns: [AppleInsightPattern]
    let strengths: [String]
    let opportunities: [String]
}

private struct AppleInsightSignal: Decodable {
    let label: String
    let value: String
    let detail: String
}

private struct AppleInsightPattern: Decodable {
    let title: String
    let detail: String
    let evidence: String?
}
