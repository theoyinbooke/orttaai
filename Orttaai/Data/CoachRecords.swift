// CoachRecords.swift
// Orttaai

import CoachCore
import Foundation
import GRDB

/// A habit the person started in Coach. Local to this Mac.
nonisolated struct CoachHabitRecord: Codable, Equatable, Identifiable, FetchableRecord, MutablePersistableRecord {
    var id: Int64?
    var measure: String
    /// nil is every way of talking.
    var mode: String?
    var startedAt: Date
    var endedAt: Date?

    static let databaseTableName = "coach_habit"

    var coachMeasure: CoachMeasure? { CoachMeasure(rawValue: measure) }
    var coachMode: CoachMode? { mode.flatMap(CoachMode.init(rawValue:)) }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

/// A dictation waiting to be counted.
nonisolated struct CoachIndexSource: Sendable {
    var id: Int64
    var createdAt: Date
    var text: String
    var rawText: String?
    var recordingMs: Int

    /// Raw transcripts were kept from v1.14.0 (25 October 2026). Before it
    /// a NULL rawText can't be told from "same as the text", so those rows
    /// only give a pace.
    static let rawKeptSince = Date(timeIntervalSince1970: 1_792_910_184)

    var dictation: CoachDictation {
        CoachDictation(
            createdAt: createdAt,
            heard: rawText ?? text,
            written: text,
            recordingMs: recordingMs,
            rawKnown: rawText != nil || createdAt >= Self.rawKeptSince
        )
    }
}

/// A counted dictation with the app it went to.
nonisolated struct CoachInput: Sendable {
    var id: Int64
    var createdAt: Date
    var bundleID: String?
    var appName: String?
    var measures: DictationMeasures
}

/// An app dictated into, as Coach lists them.
nonisolated struct CoachAppUsage: Sendable, Equatable, Identifiable {
    /// `CoachAppCatalog.key`; "" when the app isn't known.
    var key: String
    var bundleID: String?
    var appName: String?
    var deviceKind: String?
    var dictations: Int
    var firstAt: Date?

    var id: String { key }

    var displayName: String {
        if let name = appName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty { return name }
        switch deviceKind {
        case "iphone": return "Orttakey on iPhone"
        case "ipad": return "Orttakey on iPad"
        default: return bundleID ?? "Unknown app"
        }
    }
}

/// A dictation quoted in Coach, read live so deleting it removes the quote.
nonisolated struct CoachQuote: Sendable, Equatable {
    var id: Int64
    var text: String
    var createdAt: Date
    var appName: String?
}

nonisolated extension DatabaseManager {
    /// Dictations (not edit commands) with no counts yet, or counts from an
    /// older version of the rules, newest first.
    /// Apps in `skippingKeys` (switched off in Coach) are never read.
    func fetchCoachBacklog(skippingKeys: Set<String>, limit: Int = 500) throws -> [CoachIndexSource] {
        try dbQueue.read { db in
            // Never empty: NOT IN (NULL) would match nothing.
            let skipped = skippingKeys.isEmpty ? ["\u{0}none"] : Array(skippingKeys)
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT t.id, t.createdAt, t.text, t.rawText, t.recordingDurationMs
                FROM transcription t
                LEFT JOIN coach_metric m ON m.transcriptionId = t.id
                WHERE (t.entryKind IS NULL OR t.entryKind != ?)
                  AND (m.transcriptionId IS NULL OR m.metricsVersion < ?)
                  AND \(Self.coachAppKeySQL) NOT IN \(coachPlaceholders(skipped.count))
                ORDER BY t.createdAt DESC
                LIMIT ?
                """,
                arguments: StatementArguments([Transcription.editEntryKind, DictationMeasures.version] as [any DatabaseValueConvertible])
                    + StatementArguments(skipped)
                    + StatementArguments([limit])
            )
            return rows.map { row in
                CoachIndexSource(
                    id: row["id"],
                    createdAt: row["createdAt"],
                    text: row["text"] ?? "",
                    rawText: row["rawText"],
                    recordingMs: row["recordingDurationMs"] ?? 0
                )
            }
        }
    }

    func saveCoachMetrics(_ metrics: [(id: Int64, measures: DictationMeasures)]) throws {
        guard !metrics.isEmpty else { return }
        try dbQueue.write { db in
            for (id, m) in metrics {
                // The dictation may have been deleted while it was counted.
                guard try Bool.fetchOne(db, sql: "SELECT 1 FROM transcription WHERE id = ?", arguments: [id]) == true else { continue }
                try db.execute(
                    sql: """
                    INSERT OR REPLACE INTO coach_metric
                    (transcriptionId, metricsVersion, words, umUh, phraseFillers, wpm, sentenceLengths, repeats, polishChangeRatio, rawKnown)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    arguments: [
                        id, DictationMeasures.version, m.words, m.umUh, m.phraseFillers, m.wpm,
                        m.sentenceLengths.map(String.init).joined(separator: ","),
                        m.repeats, m.polishChangeRatio, m.rawKnown,
                    ]
                )
            }
        }
    }

    /// Every counted dictation, oldest first, with its app.
    func fetchCoachInputs() throws -> [CoachInput] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT t.id, t.createdAt, t.targetAppBundleID, t.targetAppName,
                       m.words, m.umUh, m.phraseFillers, m.wpm, m.sentenceLengths,
                       m.repeats, m.polishChangeRatio, m.rawKnown
                FROM coach_metric m
                JOIN transcription t ON t.id = m.transcriptionId
                ORDER BY t.createdAt ASC
                """
            )
            return rows.map { row in
                let lengths: String = row["sentenceLengths"] ?? ""
                return CoachInput(
                    id: row["id"],
                    createdAt: row["createdAt"],
                    bundleID: row["targetAppBundleID"],
                    appName: row["targetAppName"],
                    measures: DictationMeasures(
                        words: row["words"],
                        umUh: row["umUh"],
                        phraseFillers: row["phraseFillers"],
                        wpm: row["wpm"],
                        sentenceLengths: lengths.split(separator: ",").compactMap { Int($0) },
                        repeats: row["repeats"],
                        polishChangeRatio: row["polishChangeRatio"],
                        rawKnown: row["rawKnown"]
                    )
                )
            }
        }
    }

    func fetchCoachQuotes(ids: [Int64]) throws -> [Int64: CoachQuote] {
        guard !ids.isEmpty else { return [:] }
        return try dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT id, text, createdAt, targetAppName FROM transcription WHERE id IN \(coachPlaceholders(ids.count))",
                arguments: StatementArguments(ids)
            )
            var quotes: [Int64: CoachQuote] = [:]
            for row in rows {
                let id: Int64 = row["id"]
                quotes[id] = CoachQuote(id: id, text: row["text"] ?? "", createdAt: row["createdAt"], appName: row["targetAppName"])
            }
            return quotes
        }
    }

    /// The key `CoachAppCatalog.key` gives an app, in SQL: the bundle id,
    /// else "name:" and the name, lowercased; "" when neither is known.
    static let coachAppKeySQL = """
    (CASE WHEN t.targetAppBundleID IS NOT NULL AND trim(t.targetAppBundleID) != '' THEN lower(trim(t.targetAppBundleID)) \
    WHEN t.targetAppName IS NOT NULL AND trim(t.targetAppName) != '' THEN 'name:' || lower(trim(t.targetAppName)) \
    ELSE '' END)
    """

    /// Every app dictated into (edit commands aside), most used first.
    func fetchCoachApps() throws -> [CoachAppUsage] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT \(Self.coachAppKeySQL) AS appKey,
                       MAX(t.targetAppBundleID) AS bundleID,
                       MAX(t.targetAppName) AS appName,
                       MAX(t.sourceDeviceKind) AS deviceKind,
                       COUNT(*) AS dictations,
                       MIN(t.createdAt) AS firstAt
                FROM transcription t
                WHERE t.entryKind IS NULL OR t.entryKind != ?
                GROUP BY appKey
                ORDER BY dictations DESC
                """,
                arguments: [Transcription.editEntryKind]
            )
            return rows.map { row in
                CoachAppUsage(
                    key: row["appKey"] ?? "",
                    bundleID: row["bundleID"],
                    appName: row["appName"],
                    deviceKind: row["deviceKind"],
                    dictations: row["dictations"] ?? 0,
                    firstAt: row["firstAt"]
                )
            }
        }
    }

    /// Forgets the counts of apps just switched off.
    func deleteCoachMetrics(forKeys keys: Set<String>) throws {
        guard !keys.isEmpty else { return }
        let list = Array(keys)
        try dbQueue.write { db in
            try db.execute(
                sql: """
                DELETE FROM coach_metric WHERE transcriptionId IN (
                    SELECT t.id FROM transcription t WHERE \(Self.coachAppKeySQL) IN \(coachPlaceholders(list.count))
                )
                """,
                arguments: StatementArguments(list)
            )
        }
    }

    // MARK: Habits

    func fetchCoachHabits() throws -> [CoachHabitRecord] {
        try dbQueue.read { db in
            try CoachHabitRecord.order(Column("startedAt").desc).fetchAll(db)
        }
    }

    @discardableResult
    func startCoachHabit(measure: CoachMeasure, mode: CoachMode?, at date: Date = Date()) throws -> CoachHabitRecord {
        try dbQueue.write { db in
            var habit = CoachHabitRecord(id: nil, measure: measure.rawValue, mode: mode?.rawValue, startedAt: date, endedAt: nil)
            try habit.insert(db)
            return habit
        }
    }

    func endCoachHabit(id: Int64, at date: Date = Date()) throws {
        try dbQueue.write { db in
            try db.execute(sql: "UPDATE coach_habit SET endedAt = ? WHERE id = ? AND endedAt IS NULL", arguments: [date, id])
        }
    }
}

/// "(?,?,?)" for an IN list of `count` values; `count` is never 0 here.
private nonisolated func coachPlaceholders(_ count: Int) -> String {
    "(" + Array(repeating: "?", count: max(1, count)).joined(separator: ",") + ")"
}
