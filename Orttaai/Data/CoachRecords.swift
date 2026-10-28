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

/// A practice rep, as kept: numbers and check results, never what was said.
nonisolated struct CoachRepRecord: Codable, Equatable, Identifiable, FetchableRecord, MutablePersistableRecord {
    var id: Int64?
    var skillID: String
    var kind: String
    var spoken: Bool
    var createdAt: Date
    var score: Double?
    /// Whether the skill's own check was met; nil when it couldn't be told.
    var skillMet: Bool?
    var durationMs: Int
    var words: Int
    /// JSON of the rep's `[CheckResult]`.
    var checks: String
    var persona: String

    static let databaseTableName = "coach_rep"

    var skill: CoachSkill? { CoachSkill.skill(id: skillID) }

    var checkResults: [CheckResult] {
        (try? JSONDecoder().decode([CheckResult].self, from: Data(checks.utf8))) ?? []
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

nonisolated extension DatabaseManager {
    @discardableResult
    func saveCoachRep(_ rep: CoachRepRecord) throws -> CoachRepRecord {
        try dbQueue.write { db in
            var saved = rep
            try saved.insert(db)
            return saved
        }
    }

    func fetchCoachReps() throws -> [CoachRepRecord] {
        try dbQueue.read { db in
            try CoachRepRecord.order(Column("createdAt").asc).fetchAll(db)
        }
    }
}

/// What a habit tracks: a counted measure, or a judged question.
nonisolated enum CoachHabitTarget: Equatable, Sendable {
    case measure(CoachMeasure)
    case question(CoachQuestion)

    /// As kept in `coach_habit.measure`: a measure's name, or "q:" and the question's.
    var stored: String {
        switch self {
        case .measure(let m): return m.rawValue
        case .question(let q): return "q:" + q.rawValue
        }
    }

    init?(stored: String) {
        if stored.hasPrefix("q:") {
            guard let q = CoachQuestion(rawValue: String(stored.dropFirst(2))) else { return nil }
            self = .question(q)
        } else {
            guard let m = CoachMeasure(rawValue: stored) else { return nil }
            self = .measure(m)
        }
    }

    var title: String {
        switch self {
        case .measure(let m): return m.habitTitle
        case .question(let q):
            return CoachSkill.all.first { $0.check == .judged(q) }?.title ?? q.label
        }
    }

    var hitTitle: String {
        switch self {
        case .measure(let m): return m.hitTitle
        case .question(let q): return q.label
        }
    }
}

extension CoachHabitRecord {
    var target: CoachHabitTarget? { CoachHabitTarget(stored: measure) }
}

nonisolated extension DatabaseManager {
    @discardableResult
    func startCoachHabit(target: CoachHabitTarget, mode: CoachMode?, at date: Date = Date()) throws -> CoachHabitRecord {
        try dbQueue.write { db in
            var habit = CoachHabitRecord(id: nil, measure: target.stored, mode: mode?.rawValue, startedAt: date, endedAt: nil)
            try habit.insert(db)
            return habit
        }
    }

    /// Yes or not, by dictation, for one question and model.
    func fetchCoachJudgements(question: CoachQuestion, model: String) throws -> [Int64: Bool] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT transcriptionId, answer FROM coach_judgement WHERE question = ? AND model = ?",
                arguments: [question.rawValue, model]
            )
            var result: [Int64: Bool] = [:]
            for row in rows {
                let id: Int64 = row["transcriptionId"]
                let answer: String = row["answer"]
                result[id] = answer == JudgeAnswer.yes.rawValue
            }
            return result
        }
    }

    /// Every answer from one model as points (yes 1, partly 0.5, no 0), by
    /// question and dictation, for the judged axes of the voice shape.
    func fetchCoachJudgementScores(model: String) throws -> [CoachQuestion: [Int64: Double]] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT transcriptionId, question, answer FROM coach_judgement WHERE model = ?",
                arguments: [model]
            )
            var result: [CoachQuestion: [Int64: Double]] = [:]
            for row in rows {
                let raw: String = row["question"]
                let answer: String = row["answer"]
                guard let question = CoachQuestion(rawValue: raw), let points = JudgeAnswer(rawValue: answer)?.points else { continue }
                result[question, default: [:]][row["transcriptionId"]] = points
            }
            return result
        }
    }

    func saveCoachJudgement(transcriptionId: Int64, question: CoachQuestion, model: String, answer: JudgeAnswer, confidence: Double, at date: Date = Date()) throws {
        try dbQueue.write { db in
            guard try Bool.fetchOne(db, sql: "SELECT 1 FROM transcription WHERE id = ?", arguments: [transcriptionId]) == true else { return }
            try db.execute(
                sql: "INSERT OR REPLACE INTO coach_judgement (transcriptionId, question, model, answer, confidence, judgedAt) VALUES (?, ?, ?, ?, ?, ?)",
                arguments: [transcriptionId, question.rawValue, model, answer.rawValue, confidence, date]
            )
        }
    }

    func countCoachJudgements(since date: Date) throws -> Int {
        try dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM coach_judgement WHERE judgedAt >= ?", arguments: [date]) ?? 0
        }
    }

    /// A dictation's text, for the judge. Read live; never kept by Coach.
    func fetchCoachText(id: Int64) throws -> String? {
        try dbQueue.read { db in
            try String.fetchOne(db, sql: "SELECT text FROM transcription WHERE id = ?", arguments: [id])
        }
    }
}
