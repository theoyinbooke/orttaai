// DatabaseManager.swift
// Orttaai

import Foundation
import GRDB
import os

struct DictationLatencyTelemetry: Sendable {
    let settingsSyncMs: Int?
    let transcriptionMs: Int?
    let textProcessingMs: Int?
    let injectionMs: Int?
    let appActivationMs: Int?
    let clipboardRestoreDelayMs: Int?
}

final class DatabaseManager {
    private let dbQueue: DatabaseQueue
    private static let maxRecords = 500
    private static let maxInsightSnapshots = 60

    init(dbQueue: DatabaseQueue) throws {
        self.dbQueue = dbQueue
        try migrator.migrate(dbQueue)
        Logger.database.info("Database initialized")
    }

    convenience init() throws {
        let appSupportURL = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!.appendingPathComponent("Orttaai")

        try FileManager.default.createDirectory(
            at: appSupportURL,
            withIntermediateDirectories: true
        )

        let dbPath = appSupportURL.appendingPathComponent("orttaai.db").path
        let dbQueue = try DatabaseQueue(path: dbPath)
        try self.init(dbQueue: dbQueue)
    }

    private var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1") { db in
            try db.create(table: "transcription") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("createdAt", .datetime).notNull()
                t.column("text", .text).notNull()
                t.column("targetAppName", .text)
                t.column("targetAppBundleID", .text)
                t.column("recordingDurationMs", .integer).notNull()
                t.column("processingDurationMs", .integer).notNull()
                t.column("modelId", .text).notNull()
                t.column("audioDevice", .text)
            }

            try db.create(
                index: "idx_transcription_createdAt",
                on: "transcription",
                columns: ["createdAt"]
            )
        }

        migrator.registerMigration("v2_latency_telemetry") { db in
            try db.alter(table: "transcription") { t in
                t.add(column: "settingsSyncDurationMs", .integer)
                t.add(column: "transcriptionDurationMs", .integer)
                t.add(column: "textProcessingDurationMs", .integer)
                t.add(column: "injectionDurationMs", .integer)
                t.add(column: "appActivationDurationMs", .integer)
                t.add(column: "clipboardRestoreDelayMs", .integer)
            }
        }

        migrator.registerMigration("v3_personal_memory") { db in
            try db.create(table: "dictionary_entry") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("source", .text).notNull()
                t.column("target", .text).notNull()
                t.column("normalizedSource", .text).notNull()
                t.column("isCaseSensitive", .boolean).notNull().defaults(to: false)
                t.column("isActive", .boolean).notNull().defaults(to: true)
                t.column("usageCount", .integer).notNull().defaults(to: 0)
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
            }

            try db.create(
                index: "idx_dictionary_entry_normalizedSource_unique",
                on: "dictionary_entry",
                columns: ["normalizedSource"],
                unique: true
            )
            try db.create(
                index: "idx_dictionary_entry_active",
                on: "dictionary_entry",
                columns: ["isActive", "updatedAt"]
            )

            try db.create(table: "snippet_entry") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("trigger", .text).notNull()
                t.column("expansion", .text).notNull()
                t.column("normalizedTrigger", .text).notNull()
                t.column("isActive", .boolean).notNull().defaults(to: true)
                t.column("usageCount", .integer).notNull().defaults(to: 0)
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
            }

            try db.create(
                index: "idx_snippet_entry_normalizedTrigger_unique",
                on: "snippet_entry",
                columns: ["normalizedTrigger"],
                unique: true
            )
            try db.create(
                index: "idx_snippet_entry_active",
                on: "snippet_entry",
                columns: ["isActive", "updatedAt"]
            )

            try db.create(table: "learning_suggestion") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("type", .text).notNull()
                t.column("candidateSource", .text).notNull()
                t.column("candidateTarget", .text).notNull()
                t.column("normalizedSource", .text).notNull()
                t.column("confidence", .double).notNull().defaults(to: 0.0)
                t.column("status", .text).notNull()
                t.column("evidence", .text)
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
            }

            try db.create(
                index: "idx_learning_suggestion_status_createdAt",
                on: "learning_suggestion",
                columns: ["status", "createdAt"]
            )
            try db.create(
                index: "idx_learning_suggestion_lookup",
                on: "learning_suggestion",
                columns: ["type", "normalizedSource", "candidateTarget", "status"]
            )
        }

        migrator.registerMigration("v4_writing_insights") { db in
            try db.create(table: "writing_insight_snapshot") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("generatedAt", .datetime).notNull()
                t.column("analyzerName", .text).notNull()
                t.column("usedFallback", .boolean).notNull().defaults(to: false)
                t.column("sampleCount", .integer).notNull()
                t.column("requestJSON", .text).notNull()
                t.column("snapshotJSON", .text).notNull()
            }

            try db.create(
                index: "idx_writing_insight_snapshot_generatedAt",
                on: "writing_insight_snapshot",
                columns: ["generatedAt"]
            )
        }

        migrator.registerMigration("v5_writing_insights_pin_state") { db in
            try db.alter(table: "writing_insight_snapshot") { t in
                t.add(column: "isPinned", .boolean).notNull().defaults(to: false)
            }

            try db.create(
                index: "idx_writing_insight_snapshot_pin_generatedAt",
                on: "writing_insight_snapshot",
                columns: ["isPinned", "generatedAt"]
            )
        }

        migrator.registerMigration("v6_writing_insights_remove_recommendations") { db in
            try Self.removeLegacyInsightRecommendations(in: db)
        }

        return migrator
    }

    nonisolated private static func removeLegacyInsightRecommendations(in db: Database) throws {
        let rows = try Row.fetchAll(
            db,
            sql: """
            SELECT id, snapshotJSON
            FROM writing_insight_snapshot
            """
        )

        for row in rows {
            guard let id: Int64 = row["id"],
                  let snapshotJSONString: String = row["snapshotJSON"] else {
                continue
            }

            guard let snapshotData = snapshotJSONString.data(using: .utf8) else {
                continue
            }

            do {
                guard var payload = try JSONSerialization.jsonObject(with: snapshotData) as? [String: Any] else {
                    continue
                }

                if let recommendations = payload["recommendations"] as? [Any], !recommendations.isEmpty {
                    payload["recommendations"] = []
                    let normalizedData = try JSONSerialization.data(withJSONObject: payload, options: [])
                    guard let normalizedJSONString = String(data: normalizedData, encoding: .utf8) else {
                        continue
                    }

                    try db.execute(
                        sql: """
                        UPDATE writing_insight_snapshot
                        SET snapshotJSON = ?
                        WHERE id = ?
                        """,
                        arguments: [normalizedJSONString, id]
                    )
                }
            } catch {
                continue
            }
        }
    }

    // MARK: - CRUD

    func saveTranscription(
        text: String,
        appName: String?,
        bundleID: String? = nil,
        recordingMs: Int,
        processingMs: Int,
        modelId: String,
        audioDevice: String? = nil,
        latency: DictationLatencyTelemetry? = nil,
        createdAt: Date = Date()
    ) throws {
        try dbQueue.write { db in
            var record = Transcription(
                createdAt: createdAt,
                text: text,
                targetAppName: appName,
                targetAppBundleID: bundleID,
                recordingDurationMs: recordingMs,
                processingDurationMs: processingMs,
                settingsSyncDurationMs: latency?.settingsSyncMs,
                transcriptionDurationMs: latency?.transcriptionMs,
                textProcessingDurationMs: latency?.textProcessingMs,
                injectionDurationMs: latency?.injectionMs,
                appActivationDurationMs: latency?.appActivationMs,
                clipboardRestoreDelayMs: latency?.clipboardRestoreDelayMs,
                modelId: modelId,
                audioDevice: audioDevice
            )
            try record.insert(db)

            // Auto-prune: keep latest maxRecords
            let count = try Transcription.fetchCount(db)
            if count > Self.maxRecords {
                let toDelete = count - Self.maxRecords
                try db.execute(
                    sql: """
                    DELETE FROM transcription WHERE id IN (
                        SELECT id FROM transcription ORDER BY createdAt ASC LIMIT ?
                    )
                    """,
                    arguments: [toDelete]
                )
                Logger.database.info("Pruned \(toDelete) old transcriptions")
            }
        }
    }

    func fetchTranscriptions(
        from startDate: Date,
        to endDate: Date,
        limit: Int? = nil
    ) throws -> [Transcription] {
        try dbQueue.read { db in
            var request = Transcription
                .filter(Column("createdAt") >= startDate && Column("createdAt") < endDate)
                .order(Column("createdAt").desc)

            if let limit {
                request = request.limit(limit)
            }

            return try request.fetchAll(db)
        }
    }

    func fetchRecent(limit: Int = 50, offset: Int = 0) throws -> [Transcription] {
        try dbQueue.read { db in
            try Transcription
                .order(Column("createdAt").desc)
                .limit(limit, offset: offset)
                .fetchAll(db)
        }
    }

    func fetchLatestTranscriptionDate() throws -> Date? {
        try dbQueue.read { db in
            try Date.fetchOne(
                db,
                sql: "SELECT createdAt FROM transcription ORDER BY createdAt DESC LIMIT 1"
            )
        }
    }

    func countTranscriptions(since date: Date) throws -> Int {
        try dbQueue.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM transcription WHERE createdAt > ?",
                arguments: [date]
            ) ?? 0
        }
    }

    func search(query: String) throws -> [Transcription] {
        try dbQueue.read { db in
            try Transcription
                .filter(Column("text").like("%\(query)%"))
                .order(Column("createdAt").desc)
                .fetchAll(db)
        }
    }

    func deleteAll() throws {
        _ = try dbQueue.write { db in
            try Transcription.deleteAll(db)
        }
        Logger.database.info("All transcriptions deleted")
    }

    @discardableResult
    func deleteTranscription(id: Int64) throws -> Bool {
        return try dbQueue.write { db in
            try Transcription.deleteOne(db, key: id)
        }
    }

    // MARK: - Writing Insights

    @discardableResult
    func saveWritingInsightSnapshot(_ snapshot: WritingInsightSnapshot) throws -> Int64 {
        try dbQueue.write { db in
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let requestJSONData = try encoder.encode(snapshot.request)
            let snapshotJSONData = try encoder.encode(snapshot)
            guard let requestJSONString = String(data: requestJSONData, encoding: .utf8),
                  let snapshotJSONString = String(data: snapshotJSONData, encoding: .utf8) else {
                throw NSError(
                    domain: "com.orttaai.database",
                    code: 20,
                    userInfo: [NSLocalizedDescriptionKey: "Unable to encode writing insights snapshot."]
                )
            }

            var record = WritingInsightSnapshotRecord(
                generatedAt: snapshot.generatedAt,
                analyzerName: snapshot.analyzerName,
                usedFallback: snapshot.usedFallback,
                isPinned: false,
                sampleCount: snapshot.sampleCount,
                requestJSON: requestJSONString,
                snapshotJSON: snapshotJSONString
            )
            try record.insert(db)

            let count = try WritingInsightSnapshotRecord.fetchCount(db)
            if count > Self.maxInsightSnapshots {
                let toDelete = count - Self.maxInsightSnapshots
                try db.execute(
                    sql: """
                    DELETE FROM writing_insight_snapshot WHERE id IN (
                        SELECT id FROM writing_insight_snapshot
                        WHERE isPinned = 0
                        ORDER BY generatedAt ASC, id ASC
                        LIMIT ?
                    )
                    """,
                    arguments: [toDelete]
                )

                let remainingCount = try WritingInsightSnapshotRecord.fetchCount(db)
                if remainingCount > Self.maxInsightSnapshots {
                    let overflow = remainingCount - Self.maxInsightSnapshots
                    try db.execute(
                        sql: """
                        DELETE FROM writing_insight_snapshot WHERE id IN (
                            SELECT id FROM writing_insight_snapshot
                            ORDER BY generatedAt ASC, id ASC
                            LIMIT ?
                        )
                        """,
                        arguments: [overflow]
                    )
                }
            }

            return record.id ?? db.lastInsertedRowID
        }
    }

    func fetchLatestWritingInsightSnapshot() throws -> WritingInsightSnapshot? {
        try dbQueue.read { db in
            guard let record = try WritingInsightSnapshotRecord
                .order(Column("generatedAt").desc, Column("id").desc)
                .fetchOne(db) else {
                return nil
            }

            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let payloadData = Data(record.snapshotJSON.utf8)
            return try decoder.decode(WritingInsightSnapshot.self, from: payloadData)
        }
    }

    func fetchWritingInsightSnapshots(limit: Int = 30) throws -> [WritingInsightSnapshot] {
        try dbQueue.read { db in
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601

            let records = try WritingInsightSnapshotRecord
                .order(Column("generatedAt").desc, Column("id").desc)
                .limit(limit)
                .fetchAll(db)

            return try records.map { record in
                let payloadData = Data(record.snapshotJSON.utf8)
                return try decoder.decode(WritingInsightSnapshot.self, from: payloadData)
            }
        }
    }

    func fetchWritingInsightHistory(limit: Int = 30) throws -> [WritingInsightHistoryItem] {
        try dbQueue.read { db in
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601

            let records = try WritingInsightSnapshotRecord
                .order(Column("isPinned").desc, Column("generatedAt").desc, Column("id").desc)
                .limit(limit)
                .fetchAll(db)

            return try records.compactMap { record in
                guard let id = record.id else { return nil }
                let payloadData = Data(record.snapshotJSON.utf8)
                let snapshot = try decoder.decode(WritingInsightSnapshot.self, from: payloadData)
                return WritingInsightHistoryItem(
                    id: id,
                    isPinned: record.isPinned,
                    snapshot: snapshot
                )
            }
        }
    }

    func setWritingInsightSnapshotPinned(id: Int64, isPinned: Bool) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                UPDATE writing_insight_snapshot
                SET isPinned = ?
                WHERE id = ?
                """,
                arguments: [isPinned, id]
            )
        }
    }

    @discardableResult
    func deleteWritingInsightSnapshot(id: Int64) throws -> Bool {
        try dbQueue.write { db in
            try WritingInsightSnapshotRecord.deleteOne(db, key: id)
        }
    }

    func fetchDistinctTargetAppNames(limit: Int = 60) throws -> [String] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT DISTINCT targetAppName
                FROM transcription
                WHERE targetAppName IS NOT NULL
                AND TRIM(targetAppName) <> ''
                ORDER BY targetAppName COLLATE NOCASE ASC
                LIMIT ?
                """,
                arguments: [limit]
            )

            return rows.compactMap { row in
                guard let appName: String = row["targetAppName"] else { return nil }
                let trimmed = appName.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            }
        }
    }

    // MARK: - Personal Memory

    func fetchDictionaryEntries(includeInactive: Bool = true) throws -> [DictionaryEntry] {
        try dbQueue.read { db in
            var request = DictionaryEntry
                .order(Column("isActive").desc, Column("usageCount").desc, Column("source").asc)
            if !includeInactive {
                request = request.filter(Column("isActive") == true)
            }
            return try request.fetchAll(db)
        }
    }

    func upsertDictionaryEntry(
        source: String,
        target: String,
        isCaseSensitive: Bool = false,
        isActive: Bool = true
    ) throws -> DictionaryEntry {
        let trimmedSource = source.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedTarget = target.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSource.isEmpty, !trimmedTarget.isEmpty else {
            throw NSError(
                domain: "com.orttaai.database",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Dictionary source and target must not be empty."]
            )
        }

        return try dbQueue.write { db in
            let normalizedSource = PersonalMemoryNormalizer.normalizedKey(trimmedSource)
            let now = Date()

            if var existing = try DictionaryEntry
                .filter(Column("normalizedSource") == normalizedSource)
                .fetchOne(db)
            {
                existing.source = trimmedSource
                existing.target = trimmedTarget
                existing.normalizedSource = normalizedSource
                existing.isCaseSensitive = isCaseSensitive
                existing.isActive = isActive
                existing.updatedAt = now
                try existing.update(db)
                return existing
            }

            var entry = DictionaryEntry(
                source: trimmedSource,
                target: trimmedTarget,
                normalizedSource: normalizedSource,
                isCaseSensitive: isCaseSensitive,
                isActive: isActive,
                usageCount: 0,
                createdAt: now,
                updatedAt: now
            )
            try entry.insert(db)
            if entry.id == nil {
                entry.id = db.lastInsertedRowID
            }
            return entry
        }
    }

    func deleteDictionaryEntry(id: Int64) throws -> Bool {
        try dbQueue.write { db in
            try DictionaryEntry.deleteOne(db, key: id)
        }
    }

    func updateDictionaryEntry(
        id: Int64,
        source: String,
        target: String,
        isCaseSensitive: Bool,
        isActive: Bool
    ) throws -> DictionaryEntry {
        let trimmedSource = source.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedTarget = target.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSource.isEmpty, !trimmedTarget.isEmpty else {
            throw NSError(
                domain: "com.orttaai.database",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "Dictionary source and target must not be empty."]
            )
        }

        return try dbQueue.write { db in
            guard var entry = try DictionaryEntry.fetchOne(db, key: id) else {
                throw NSError(
                    domain: "com.orttaai.database",
                    code: 4,
                    userInfo: [NSLocalizedDescriptionKey: "Dictionary entry not found."]
                )
            }

            let normalizedSource = PersonalMemoryNormalizer.normalizedKey(trimmedSource)
            if let conflictingEntry = try DictionaryEntry
                .filter(Column("normalizedSource") == normalizedSource)
                .fetchOne(db),
               conflictingEntry.id != id
            {
                throw NSError(
                    domain: "com.orttaai.database",
                    code: 5,
                    userInfo: [NSLocalizedDescriptionKey: "A dictionary entry with this source already exists."]
                )
            }

            entry.source = trimmedSource
            entry.target = trimmedTarget
            entry.normalizedSource = normalizedSource
            entry.isCaseSensitive = isCaseSensitive
            entry.isActive = isActive
            entry.updatedAt = Date()
            try entry.update(db)
            return entry
        }
    }

    func incrementDictionaryUsage(id: Int64) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                UPDATE dictionary_entry
                SET usageCount = usageCount + 1,
                    updatedAt = ?
                WHERE id = ?
                """,
                arguments: [Date(), id]
            )
        }
    }

    func fetchSnippetEntries(includeInactive: Bool = true) throws -> [SnippetEntry] {
        try dbQueue.read { db in
            var request = SnippetEntry
                .order(Column("isActive").desc, Column("usageCount").desc, Column("trigger").asc)
            if !includeInactive {
                request = request.filter(Column("isActive") == true)
            }
            return try request.fetchAll(db)
        }
    }

    func upsertSnippetEntry(
        trigger: String,
        expansion: String,
        isActive: Bool = true
    ) throws -> SnippetEntry {
        let trimmedTrigger = trigger.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedExpansion = expansion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTrigger.isEmpty, !trimmedExpansion.isEmpty else {
            throw NSError(
                domain: "com.orttaai.database",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Snippet trigger and expansion must not be empty."]
            )
        }

        return try dbQueue.write { db in
            let normalizedTrigger = PersonalMemoryNormalizer.normalizedKey(trimmedTrigger)
            let now = Date()

            if var existing = try SnippetEntry
                .filter(Column("normalizedTrigger") == normalizedTrigger)
                .fetchOne(db)
            {
                existing.trigger = trimmedTrigger
                existing.expansion = trimmedExpansion
                existing.normalizedTrigger = normalizedTrigger
                existing.isActive = isActive
                existing.updatedAt = now
                try existing.update(db)
                return existing
            }

            var entry = SnippetEntry(
                trigger: trimmedTrigger,
                expansion: trimmedExpansion,
                normalizedTrigger: normalizedTrigger,
                isActive: isActive,
                usageCount: 0,
                createdAt: now,
                updatedAt: now
            )
            try entry.insert(db)
            if entry.id == nil {
                entry.id = db.lastInsertedRowID
            }
            return entry
        }
    }

    func deleteSnippetEntry(id: Int64) throws -> Bool {
        try dbQueue.write { db in
            try SnippetEntry.deleteOne(db, key: id)
        }
    }

    func updateSnippetEntry(
        id: Int64,
        trigger: String,
        expansion: String,
        isActive: Bool
    ) throws -> SnippetEntry {
        let trimmedTrigger = trigger.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedExpansion = expansion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTrigger.isEmpty, !trimmedExpansion.isEmpty else {
            throw NSError(
                domain: "com.orttaai.database",
                code: 6,
                userInfo: [NSLocalizedDescriptionKey: "Snippet trigger and expansion must not be empty."]
            )
        }

        return try dbQueue.write { db in
            guard var entry = try SnippetEntry.fetchOne(db, key: id) else {
                throw NSError(
                    domain: "com.orttaai.database",
                    code: 7,
                    userInfo: [NSLocalizedDescriptionKey: "Snippet entry not found."]
                )
            }

            let normalizedTrigger = PersonalMemoryNormalizer.normalizedKey(trimmedTrigger)
            if let conflictingEntry = try SnippetEntry
                .filter(Column("normalizedTrigger") == normalizedTrigger)
                .fetchOne(db),
               conflictingEntry.id != id
            {
                throw NSError(
                    domain: "com.orttaai.database",
                    code: 8,
                    userInfo: [NSLocalizedDescriptionKey: "A snippet with this trigger already exists."]
                )
            }

            entry.trigger = trimmedTrigger
            entry.expansion = trimmedExpansion
            entry.normalizedTrigger = normalizedTrigger
            entry.isActive = isActive
            entry.updatedAt = Date()
            try entry.update(db)
            return entry
        }
    }

    func incrementSnippetUsage(id: Int64) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                UPDATE snippet_entry
                SET usageCount = usageCount + 1,
                    updatedAt = ?
                WHERE id = ?
                """,
                arguments: [Date(), id]
            )
        }
    }

    @discardableResult
    func saveLearningSuggestions(_ drafts: [LearningSuggestionDraft]) throws -> Int {
        try dbQueue.write { db in
            var changeCount = 0
            let now = Date()

            for draft in drafts {
                let trimmedSource = draft.candidateSource.trimmingCharacters(in: .whitespacesAndNewlines)
                let trimmedTarget = draft.candidateTarget.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmedSource.isEmpty, !trimmedTarget.isEmpty else { continue }

                let normalizedSource = PersonalMemoryNormalizer.normalizedKey(trimmedSource)

                if var existing = try LearningSuggestion
                    .filter(Column("type") == draft.type.rawValue)
                    .filter(Column("normalizedSource") == normalizedSource)
                    .filter(Column("candidateTarget") == trimmedTarget)
                    .filter(Column("status") == LearningSuggestionStatus.pending.rawValue)
                    .fetchOne(db)
                {
                    existing.confidence = max(existing.confidence, draft.confidence)
                    if let evidence = draft.evidence, !evidence.isEmpty {
                        existing.evidence = evidence
                    }
                    existing.updatedAt = now
                    try existing.update(db)
                    changeCount += 1
                    continue
                }

                let suggestion = LearningSuggestion(
                    type: draft.type.rawValue,
                    candidateSource: trimmedSource,
                    candidateTarget: trimmedTarget,
                    normalizedSource: normalizedSource,
                    confidence: min(max(draft.confidence, 0), 1),
                    status: LearningSuggestionStatus.pending.rawValue,
                    evidence: draft.evidence,
                    createdAt: now,
                    updatedAt: now
                )
                try suggestion.insert(db)
                changeCount += 1
            }

            return changeCount
        }
    }

    func fetchLearningSuggestions(
        status: LearningSuggestionStatus? = nil,
        limit: Int = 100
    ) throws -> [LearningSuggestion] {
        try dbQueue.read { db in
            var request = LearningSuggestion
                .order(Column("createdAt").desc)
                .limit(limit)

            if let status {
                request = request.filter(Column("status") == status.rawValue)
            }

            return try request.fetchAll(db)
        }
    }

    func updateLearningSuggestionStatus(
        id: Int64,
        status: LearningSuggestionStatus
    ) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                UPDATE learning_suggestion
                SET status = ?,
                    updatedAt = ?
                WHERE id = ?
                """,
                arguments: [status.rawValue, Date(), id]
            )
        }
    }

    func clearLearningSuggestions(status: LearningSuggestionStatus? = nil) throws {
        try dbQueue.write { db in
            if let status {
                try db.execute(
                    sql: "DELETE FROM learning_suggestion WHERE status = ?",
                    arguments: [status.rawValue]
                )
            } else {
                try LearningSuggestion.deleteAll(db)
            }
        }
    }

    func logSkippedRecording(duration: TimeInterval) {
        Logger.database.info("Skipped recording: \(duration, format: .fixed(precision: 2))s (< 0.5s)")
    }

    // MARK: - Observation

    func observeTranscriptions(
        limit: Int = 50,
        onChange: @escaping ([Transcription]) -> Void
    ) -> DatabaseCancellable {
        let observation = ValueObservation.tracking { db in
            try Transcription
                .order(Column("createdAt").desc)
                .limit(limit)
                .fetchAll(db)
        }
        return observation.start(
            in: dbQueue,
            onError: { error in
                Logger.database.error("Observation error: \(error.localizedDescription)")
            },
            onChange: onChange
        )
    }
}
