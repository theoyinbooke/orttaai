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
    private let databaseURL: URL?
    private let backupDirectoryURL: URL?
    private static let maxInsightSnapshots = 60
    private static let maxRecentCloudSyncBackups = 100
    private static let maxDailyCloudSyncBackups = 30
    private static let databaseFileName = "orttaai.db"

    convenience init(dbQueue: DatabaseQueue) throws {
        try self.init(dbQueue: dbQueue, databaseURL: nil, backupDirectoryURL: nil)
    }

    init(
        dbQueue: DatabaseQueue,
        databaseURL: URL?,
        backupDirectoryURL: URL? = nil
    ) throws {
        self.dbQueue = dbQueue
        self.databaseURL = databaseURL
        self.backupDirectoryURL = backupDirectoryURL
        try migrator.migrate(dbQueue)
        if let databaseURL {
            Logger.database.info("Database initialized at \(databaseURL.path, privacy: .public)")
        } else {
            Logger.database.info("Database initialized")
        }
    }

    convenience init() throws {
        let databaseURL = try Self.defaultDatabaseURL()
        let dbQueue = try DatabaseQueue(path: databaseURL.path)
        try self.init(dbQueue: dbQueue, databaseURL: databaseURL)
    }

    static func applicationSupportRootURL() throws -> URL {
        try AppStoragePaths.applicationSupportRootURL()
    }

    static func defaultApplicationSupportURL(createDirectory: Bool = true) throws -> URL {
        try AppStoragePaths.applicationSupportURL(createDirectory: createDirectory)
    }

    static func defaultDatabaseURL(createDirectory: Bool = true) throws -> URL {
        try defaultApplicationSupportURL(createDirectory: createDirectory)
            .appendingPathComponent(databaseFileName)
    }

    static func defaultBackupDirectoryURL(createDirectory: Bool = true) throws -> URL {
        try AppStoragePaths.backupDirectoryURL(createDirectory: createDirectory)
    }

    @discardableResult
    static func backupDefaultDatabase(reason: String) throws -> URL? {
        let databaseURL = try defaultDatabaseURL(createDirectory: false)
        return try backupDatabase(at: databaseURL, reason: reason)
    }

    @discardableResult
    static func backupDatabase(
        at databaseURL: URL,
        using source: (any DatabaseReader)? = nil,
        backupDirectoryURL: URL? = nil,
        reason: String
    ) throws -> URL? {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: databaseURL.path) else {
            Logger.database.info("Skipped database backup; no database exists at \(databaseURL.path, privacy: .public)")
            return nil
        }

        let resolvedBackupDirectoryURL: URL
        if let backupDirectoryURL {
            resolvedBackupDirectoryURL = backupDirectoryURL
        } else {
            resolvedBackupDirectoryURL = try defaultBackupDirectoryURL()
        }

        try fileManager.createDirectory(
            at: resolvedBackupDirectoryURL,
            withIntermediateDirectories: true
        )

        let backupURL = resolvedBackupDirectoryURL.appendingPathComponent(
            "\(databaseFileNameWithoutExtension)-\(backupTimestamp())-\(sanitizedBackupReason(reason)).db"
        )
        if fileManager.fileExists(atPath: backupURL.path) {
            try fileManager.removeItem(at: backupURL)
        }

        let destinationQueue = try DatabaseQueue(path: backupURL.path)
        if let source {
            try source.backup(to: destinationQueue)
        } else {
            let sourceQueue = try DatabaseQueue(path: databaseURL.path)
            try sourceQueue.backup(to: destinationQueue)
        }

        Logger.database.info("Database backup created at \(backupURL.path, privacy: .public)")
        do {
            let removedCount = try pruneCloudSyncBackups(in: resolvedBackupDirectoryURL)
            if removedCount > 0 {
                Logger.database.info("Pruned \(removedCount) expired iCloud database backups")
            }
        } catch {
            Logger.database.error("Could not prune database backups: \(error.localizedDescription, privacy: .public)")
        }
        return backupURL
    }

    @discardableResult
    static func pruneCloudSyncBackups(in backupDirectoryURL: URL) throws -> Int {
        let fileManager = FileManager.default
        let cloudSyncBackups = try fileManager.contentsOfDirectory(
            at: backupDirectoryURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        .filter {
            $0.pathExtension == "db"
                && $0.lastPathComponent.hasPrefix("\(databaseFileNameWithoutExtension)-")
                && $0.lastPathComponent.hasSuffix("-icloud-sync.db")
        }
        .sorted { $0.lastPathComponent > $1.lastPathComponent }

        guard cloudSyncBackups.count > maxRecentCloudSyncBackups else { return 0 }

        let recentBackups = cloudSyncBackups.prefix(maxRecentCloudSyncBackups)
        var retainedURLs = Set(recentBackups)
        var retainedDays = Set(recentBackups.compactMap(backupDay))
        var retainedDailyCount = 0

        for backupURL in cloudSyncBackups.dropFirst(maxRecentCloudSyncBackups) {
            guard retainedDailyCount < maxDailyCloudSyncBackups,
                  let day = backupDay(backupURL),
                  retainedDays.insert(day).inserted else {
                continue
            }
            retainedURLs.insert(backupURL)
            retainedDailyCount += 1
        }

        var removedCount = 0
        for backupURL in cloudSyncBackups where !retainedURLs.contains(backupURL) {
            try fileManager.removeItem(at: backupURL)
            removedCount += 1
        }
        return removedCount
    }

    @discardableResult
    func backupDatabase(reason: String) throws -> URL? {
        guard let databaseURL else { return nil }
        return try Self.backupDatabase(
            at: databaseURL,
            using: dbQueue,
            backupDirectoryURL: backupDirectoryURL,
            reason: reason
        )
    }

    private static var databaseFileNameWithoutExtension: String {
        (databaseFileName as NSString).deletingPathExtension
    }

    private static func backupTimestamp(date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }

    private static func sanitizedBackupReason(_ reason: String) -> String {
        let sanitized = reason
            .lowercased()
            .replacingOccurrences(
                of: #"[^a-z0-9]+"#,
                with: "-",
                options: .regularExpression
            )
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))

        return sanitized.isEmpty ? "manual" : sanitized
    }

    nonisolated private static func backupDay(_ backupURL: URL) -> String? {
        let components = backupURL.deletingPathExtension().lastPathComponent.split(separator: "-")
        guard components.count >= 4 else { return nil }
        let day = components[1]
        guard day.count == 8, day.allSatisfy(\.isNumber) else { return nil }
        return String(day)
    }

    private func createDestructiveOperationBackup(reason: String) throws {
        guard databaseURL != nil else { return }
        _ = try backupDatabase(reason: reason)
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

        migrator.registerMigration("v7_cloud_sync_metadata") { db in
            try Self.addCloudSyncMetadata(in: db)
        }

        migrator.registerMigration("v8_semantic_memory") { db in
            try db.create(table: "semantic_chunk") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("transcriptionID", .integer).notNull()
                t.column("chunkIndex", .integer).notNull()
                t.column("text", .text).notNull()
                t.column("textHash", .text).notNull()
                t.column("sourceCreatedAt", .datetime).notNull()
                t.column("targetAppName", .text)
                t.column("targetAppBundleID", .text)
                t.column("wordCount", .integer).notNull()
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
            }
            try db.create(
                index: "idx_semantic_chunk_transcription_chunk_unique",
                on: "semantic_chunk",
                columns: ["transcriptionID", "chunkIndex"],
                unique: true
            )
            try db.create(
                index: "idx_semantic_chunk_sourceCreatedAt",
                on: "semantic_chunk",
                columns: ["sourceCreatedAt"]
            )
            try db.create(
                index: "idx_semantic_chunk_textHash",
                on: "semantic_chunk",
                columns: ["textHash"]
            )

            try db.create(table: "semantic_embedding") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("chunkID", .integer).notNull()
                t.column("modelID", .text).notNull()
                t.column("providerName", .text).notNull()
                t.column("dimension", .integer).notNull()
                t.column("vectorData", .blob).notNull()
                t.column("generatedAt", .datetime).notNull()
            }
            try db.create(
                index: "idx_semantic_embedding_chunk_model_unique",
                on: "semantic_embedding",
                columns: ["chunkID", "modelID"],
                unique: true
            )
            try db.create(
                index: "idx_semantic_embedding_model_generatedAt",
                on: "semantic_embedding",
                columns: ["modelID", "generatedAt"]
            )

            try db.create(table: "semantic_graph_node") { t in
                t.column("nodeID", .text).primaryKey()
                t.column("kind", .text).notNull()
                t.column("title", .text).notNull()
                t.column("subtitle", .text)
                t.column("weight", .double).notNull()
                t.column("lastSeenAt", .datetime)
                t.column("updatedAt", .datetime).notNull()
            }
            try db.create(
                index: "idx_semantic_graph_node_kind_weight",
                on: "semantic_graph_node",
                columns: ["kind", "weight"]
            )

            try db.create(table: "semantic_graph_edge") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("sourceNodeID", .text).notNull()
                t.column("targetNodeID", .text).notNull()
                t.column("kind", .text).notNull()
                t.column("weight", .double).notNull()
                t.column("evidence", .text)
                t.column("updatedAt", .datetime).notNull()
            }
            try db.create(
                index: "idx_semantic_graph_edge_unique",
                on: "semantic_graph_edge",
                columns: ["sourceNodeID", "targetNodeID", "kind"],
                unique: true
            )
            try db.create(
                index: "idx_semantic_graph_edge_weight",
                on: "semantic_graph_edge",
                columns: ["weight"]
            )
        }

        migrator.registerMigration("v9_semantic_insight_snapshots") { db in
            try db.create(table: "semantic_insight_snapshot") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("generatedAt", .datetime).notNull()
                t.column("graphSignature", .text).notNull()
                t.column("analyzerName", .text).notNull()
                t.column("summaryModelName", .text)
                t.column("sourceNodeCount", .integer).notNull()
                t.column("sourceEdgeCount", .integer).notNull()
                t.column("sourceChunkCount", .integer).notNull()
                t.column("reportJSON", .text).notNull()
            }

            try db.create(
                index: "idx_semantic_insight_snapshot_generatedAt",
                on: "semantic_insight_snapshot",
                columns: ["generatedAt"]
            )
        }

        migrator.registerMigration("v10_transcription_source_device") { db in
            try db.alter(table: "transcription") { t in
                // NULL means the row predates device tagging (or came from an
                // older app version); readers treat NULL as local.
                t.add(column: "sourceDeviceID", .text)
            }
        }

        migrator.registerMigration("v11_semantic_signals") { db in
            try db.create(table: "semantic_signal") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("chunkID", .integer).notNull()
                t.column("family", .text).notNull()
                t.column("value", .text).notNull()
                t.column("confidence", .double).notNull()
                t.column("modelID", .text).notNull()
                t.column("extractedAt", .datetime).notNull()
            }
            try db.create(
                index: "idx_semantic_signal_chunk_family_value_unique",
                on: "semantic_signal",
                columns: ["chunkID", "family", "value"],
                unique: true
            )
            try db.create(
                index: "idx_semantic_signal_family",
                on: "semantic_signal",
                columns: ["family", "extractedAt"]
            )
        }

        migrator.registerMigration("v12_insight_findings") { db in
            try db.create(table: "insight_finding") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("kind", .text).notNull()
                t.column("subjectKey", .text).notNull()
                t.column("title", .text).notNull()
                t.column("detail", .text).notNull()
                t.column("magnitude", .double).notNull().defaults(to: 0)
                t.column("confidence", .double).notNull().defaults(to: 0.5)
                t.column("windowStart", .datetime)
                t.column("windowEnd", .datetime)
                t.column("evidenceChunkIDs", .text).notNull().defaults(to: "[]")
                t.column("firstSeenAt", .datetime).notNull()
                t.column("lastComputedAt", .datetime).notNull()
                t.column("lastShownAt", .datetime)
                t.column("status", .text).notNull().defaults(to: "active")
            }
            try db.create(
                index: "idx_insight_finding_kind_subject_unique",
                on: "insight_finding",
                columns: ["kind", "subjectKey"],
                unique: true
            )
            try db.create(
                index: "idx_insight_finding_status_computed",
                on: "insight_finding",
                columns: ["status", "lastComputedAt"]
            )
        }

        return migrator
    }

    nonisolated private static func addCloudSyncMetadata(in db: Database) throws {
        let syncableTables: [(table: String, modifiedAtExpression: String)] = [
            ("transcription", "createdAt"),
            ("dictionary_entry", "updatedAt"),
            ("snippet_entry", "updatedAt"),
            ("learning_suggestion", "updatedAt"),
            ("writing_insight_snapshot", "generatedAt")
        ]

        for item in syncableTables {
            try db.alter(table: item.table) { t in
                t.add(column: "syncID", .text)
                t.add(column: "cloudChangeTag", .text)
                t.add(column: "modifiedAt", .datetime)
                t.add(column: "lastSyncedAt", .datetime)
            }

            try db.execute(
                sql: """
                UPDATE \(item.table)
                SET syncID = lower(hex(randomblob(16)))
                WHERE syncID IS NULL OR TRIM(syncID) = ''
                """
            )
            try db.execute(
                sql: """
                UPDATE \(item.table)
                SET modifiedAt = COALESCE(modifiedAt, \(item.modifiedAtExpression), CURRENT_TIMESTAMP)
                WHERE modifiedAt IS NULL
                """
            )
            try db.create(
                index: "idx_\(item.table)_syncID_unique",
                on: item.table,
                columns: ["syncID"],
                unique: true
            )
            try db.create(
                index: "idx_\(item.table)_modifiedAt",
                on: item.table,
                columns: ["modifiedAt"]
            )
        }

        try db.create(table: "cloud_sync_tombstone") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("tableName", .text).notNull()
            t.column("syncID", .text).notNull()
            t.column("deletedAt", .datetime).notNull()
            t.column("needsCloudSync", .boolean).notNull().defaults(to: true)
        }
        try db.create(
            index: "idx_cloud_sync_tombstone_unique",
            on: "cloud_sync_tombstone",
            columns: ["tableName", "syncID"],
            unique: true
        )

        try db.create(table: "cloud_sync_state") { t in
            t.column("key", .text).primaryKey()
            t.column("value", .text)
            t.column("updatedAt", .datetime).notNull()
        }
    }

    private static func newSyncID() -> String {
        UUID().uuidString.lowercased()
    }

    private static func touchSyncMetadata(
        in db: Database,
        table: String,
        id: Int64,
        modifiedAt: Date = Date()
    ) throws {
        try db.execute(
            sql: """
            UPDATE \(table)
            SET syncID = COALESCE(NULLIF(syncID, ''), ?),
                modifiedAt = ?,
                lastSyncedAt = NULL
            WHERE id = ?
            """,
            arguments: [newSyncID(), modifiedAt, id]
        )
    }

    private static func recordTombstone(
        in db: Database,
        table: CloudSyncTable,
        id: Int64,
        deletedAt: Date = Date(),
        needsCloudSync: Bool = true
    ) throws {
        guard let syncID = try String.fetchOne(
            db,
            sql: "SELECT syncID FROM \(table.rawValue) WHERE id = ?",
            arguments: [id]
        ) else {
            return
        }
        try recordTombstone(
            in: db,
            table: table,
            syncID: syncID,
            deletedAt: deletedAt,
            needsCloudSync: needsCloudSync
        )
    }

    private static func recordTombstones(
        in db: Database,
        table: CloudSyncTable,
        where condition: String? = nil,
        deletedAt: Date = Date(),
        needsCloudSync: Bool = true
    ) throws {
        let sql = """
        SELECT syncID
        FROM \(table.rawValue)
        \(condition.map { "WHERE \($0)" } ?? "")
        """
        let syncIDs = try String.fetchAll(db, sql: sql)
        for syncID in syncIDs {
            try recordTombstone(
                in: db,
                table: table,
                syncID: syncID,
                deletedAt: deletedAt,
                needsCloudSync: needsCloudSync
            )
        }
    }

    private static func recordTombstone(
        in db: Database,
        table: CloudSyncTable,
        syncID: String,
        deletedAt: Date,
        needsCloudSync: Bool
    ) throws {
        guard !syncID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        try db.execute(
            sql: """
            INSERT INTO cloud_sync_tombstone (tableName, syncID, deletedAt, needsCloudSync)
            VALUES (?, ?, ?, ?)
            ON CONFLICT(tableName, syncID) DO UPDATE SET
                deletedAt = excluded.deletedAt,
                needsCloudSync = excluded.needsCloudSync
            """,
            arguments: [table.rawValue, syncID, deletedAt, needsCloudSync]
        )
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
        createdAt: Date = Date(),
        sourceDeviceID: String = DeviceIdentity.currentID
    ) throws {
        try dbQueue.write { db in
            let record = Transcription(
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
                audioDevice: audioDevice,
                sourceDeviceID: sourceDeviceID
            )
            try record.insert(db)
            try Self.touchSyncMetadata(
                in: db,
                table: CloudSyncTable.transcription.rawValue,
                id: db.lastInsertedRowID,
                modifiedAt: createdAt
            )
        }
        requestCloudSyncIfEnabled()
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

    func fetchAllTranscriptions() throws -> [Transcription] {
        try dbQueue.read { db in
            try Transcription
                .order(Column("createdAt").desc)
                .fetchAll(db)
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
        try createDestructiveOperationBackup(reason: "clear-history")
        _ = try dbQueue.write { db in
            try Self.recordTombstones(in: db, table: .transcription)
            try Self.deleteAllSemanticMemory(in: db)
            try Transcription.deleteAll(db)
        }
        requestCloudSyncIfEnabled()
        Logger.database.info("All transcriptions deleted")
    }

    func resetAllLocalData() throws {
        try createDestructiveOperationBackup(reason: "reset-local-data")
        _ = try dbQueue.write { db in
            try Self.recordTombstones(in: db, table: .transcription)
            try Self.recordTombstones(in: db, table: .dictionaryEntry)
            try Self.recordTombstones(in: db, table: .snippetEntry)
            try Self.recordTombstones(in: db, table: .learningSuggestion)
            try Self.recordTombstones(in: db, table: .writingInsightSnapshot)
            try Self.deleteAllSemanticMemory(in: db)
            try Transcription.deleteAll(db)
            try db.execute(sql: "DELETE FROM dictionary_entry")
            try db.execute(sql: "DELETE FROM snippet_entry")
            try db.execute(sql: "DELETE FROM learning_suggestion")
            try db.execute(sql: "DELETE FROM writing_insight_snapshot")
        }
        NotificationCenter.default.post(name: .personalMemoryDidChange, object: nil)
        requestCloudSyncIfEnabled()
        Logger.database.info("All local database content deleted")
    }

    @discardableResult
    func deleteTranscription(id: Int64) throws -> Bool {
        let deleted = try dbQueue.write { db in
            try Self.recordTombstone(in: db, table: .transcription, id: id)
            try Self.deleteSemanticMemory(forTranscriptionID: id, in: db)
            return try Transcription.deleteOne(db, key: id)
        }
        if deleted {
            requestCloudSyncIfEnabled()
        }
        return deleted
    }

    // MARK: - Semantic Memory

    private static func deleteAllSemanticMemory(in db: Database) throws {
        try db.execute(sql: "DELETE FROM semantic_insight_snapshot")
        try db.execute(sql: "DELETE FROM semantic_graph_edge")
        try db.execute(sql: "DELETE FROM semantic_graph_node")
        try db.execute(sql: "DELETE FROM semantic_signal")
        try db.execute(sql: "DELETE FROM semantic_embedding")
        try db.execute(sql: "DELETE FROM semantic_chunk")
    }

    private static func deleteSemanticMemory(forTranscriptionID transcriptionID: Int64, in db: Database) throws {
        let chunkIDs = try Int64.fetchAll(
            db,
            sql: "SELECT id FROM semantic_chunk WHERE transcriptionID = ?",
            arguments: [transcriptionID]
        )
        if !chunkIDs.isEmpty {
            try db.execute(
                sql: "DELETE FROM semantic_embedding WHERE chunkID IN \(chunkIDs.sqlInList)",
                arguments: StatementArguments(chunkIDs)
            )
            try db.execute(
                sql: "DELETE FROM semantic_signal WHERE chunkID IN \(chunkIDs.sqlInList)",
                arguments: StatementArguments(chunkIDs)
            )
        }
        try db.execute(
            sql: "DELETE FROM semantic_chunk WHERE transcriptionID = ?",
            arguments: [transcriptionID]
        )
    }

    // MARK: - Insight Findings

    /// Reconciles a fresh computation with stored findings: recomputed
    /// findings update in place (preserving firstSeenAt, lastShownAt, and any
    /// user resolve/dismiss), previously-active findings of the computed kinds
    /// that vanished are expired, and new findings are inserted.
    func reconcileInsightFindings(
        _ drafts: [InsightFindingDraft],
        computedKinds: [InsightFindingKind],
        now: Date = Date()
    ) throws {
        let encoder = JSONEncoder()
        try dbQueue.write { db in
            let kindValues = computedKinds.map(\.rawValue)
            var freshSubjects: Set<String> = []

            for draft in drafts {
                let subject = "\(draft.kind.rawValue)|\(draft.subjectKey)"
                freshSubjects.insert(subject)
                let evidenceJSON = (try? encoder.encode(draft.evidenceChunkIDs))
                    .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"

                let existing = try InsightFinding
                    .filter(Column("kind") == draft.kind.rawValue && Column("subjectKey") == draft.subjectKey)
                    .fetchOne(db)

                if var finding = existing {
                    finding.title = draft.title
                    finding.detail = draft.detail
                    finding.magnitude = draft.magnitude
                    finding.confidence = draft.confidence
                    finding.windowStart = draft.windowStart
                    finding.windowEnd = draft.windowEnd
                    finding.evidenceChunkIDs = evidenceJSON
                    finding.lastComputedAt = now
                    // Re-activate expired findings; never un-resolve/undismiss.
                    if finding.status == InsightFindingStatus.expired.rawValue {
                        finding.status = InsightFindingStatus.active.rawValue
                    }
                    try finding.update(db)
                } else {
                    var finding = InsightFinding(
                        kind: draft.kind.rawValue,
                        subjectKey: draft.subjectKey,
                        title: draft.title,
                        detail: draft.detail,
                        magnitude: draft.magnitude,
                        confidence: draft.confidence,
                        windowStart: draft.windowStart,
                        windowEnd: draft.windowEnd,
                        evidenceChunkIDs: evidenceJSON,
                        firstSeenAt: now,
                        lastComputedAt: now,
                        lastShownAt: nil,
                        status: InsightFindingStatus.active.rawValue
                    )
                    try finding.insert(db)
                }
            }

            // Expire active findings of the computed kinds that no longer hold.
            if !kindValues.isEmpty {
                let stale = try InsightFinding
                    .filter(kindValues.contains(Column("kind")))
                    .filter(Column("status") == InsightFindingStatus.active.rawValue)
                    .fetchAll(db)
                for var finding in stale where !freshSubjects.contains("\(finding.kind)|\(finding.subjectKey)") {
                    finding.status = InsightFindingStatus.expired.rawValue
                    finding.lastComputedAt = now
                    try finding.update(db)
                }
            }
        }
    }

    func fetchInsightFindings(
        kinds: [InsightFindingKind]? = nil,
        statuses: [InsightFindingStatus] = [.active],
        limit: Int = 200
    ) throws -> [InsightFinding] {
        try dbQueue.read { db in
            var request = InsightFinding
                .filter(statuses.map(\.rawValue).contains(Column("status")))
            if let kinds, !kinds.isEmpty {
                request = request.filter(kinds.map(\.rawValue).contains(Column("kind")))
            }
            return try request
                .order(Column("magnitude").desc)
                .limit(max(1, limit))
                .fetchAll(db)
        }
    }

    func updateInsightFindingStatus(id: Int64, status: InsightFindingStatus) throws {
        _ = try dbQueue.write { db in
            try db.execute(
                sql: "UPDATE insight_finding SET status = ? WHERE id = ?",
                arguments: [status.rawValue, id]
            )
        }
    }

    func markInsightFindingsShown(ids: [Int64], at date: Date = Date()) throws {
        guard !ids.isEmpty else { return }
        try dbQueue.write { db in
            try db.execute(
                sql: "UPDATE insight_finding SET lastShownAt = ? WHERE id IN \(ids.sqlInList)",
                arguments: StatementArguments([date] + ids.map { $0 as DatabaseValueConvertible })
            )
        }
    }

    // MARK: - Semantic Signals

    /// Inserts signals, ignoring duplicates (unique on chunk+family+value).
    func insertSemanticSignals(_ signals: [SemanticSignal]) throws {
        guard !signals.isEmpty else { return }
        try dbQueue.write { db in
            for signal in signals {
                try db.execute(
                    sql: """
                    INSERT OR IGNORE INTO semantic_signal
                        (chunkID, family, value, confidence, modelID, extractedAt)
                    VALUES (?, ?, ?, ?, ?, ?)
                    """,
                    arguments: [
                        signal.chunkID,
                        signal.family,
                        signal.value,
                        signal.confidence,
                        signal.modelID,
                        signal.extractedAt
                    ]
                )
            }
        }
    }

    /// Chunk IDs that already have signals from the given extractor.
    func fetchSemanticSignalChunkIDs(modelID: String) throws -> Set<Int64> {
        try dbQueue.read { db in
            let ids = try Int64.fetchAll(
                db,
                sql: "SELECT DISTINCT chunkID FROM semantic_signal WHERE modelID = ?",
                arguments: [modelID]
            )
            return Set(ids)
        }
    }

    /// Signals joined with their source chunk context, newest first.
    func fetchSemanticSignals(
        families: [String]? = nil,
        limit: Int = 2_000
    ) throws -> [SemanticSignalWithContext] {
        try dbQueue.read { db in
            var sql = """
            SELECT s.id, s.chunkID, s.family, s.value, s.confidence, s.modelID, s.extractedAt,
                   c.text AS chunkText, c.sourceCreatedAt, c.targetAppName, c.transcriptionID
            FROM semantic_signal s
            JOIN semantic_chunk c ON c.id = s.chunkID
            """
            var arguments: [DatabaseValueConvertible] = []
            if let families, !families.isEmpty {
                sql += " WHERE s.family IN (\(families.map { _ in "?" }.joined(separator: ", ")))"
                arguments.append(contentsOf: families)
            }
            sql += " ORDER BY c.sourceCreatedAt DESC LIMIT ?"
            arguments.append(max(1, limit))

            let rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(arguments))
            return rows.compactMap { row in
                guard let chunkID: Int64 = row["chunkID"],
                      let family: String = row["family"],
                      let value: String = row["value"],
                      let confidence: Double = row["confidence"],
                      let modelID: String = row["modelID"],
                      let extractedAt: Date = row["extractedAt"],
                      let chunkText: String = row["chunkText"],
                      let sourceCreatedAt: Date = row["sourceCreatedAt"],
                      let transcriptionID: Int64 = row["transcriptionID"] else {
                    return nil
                }
                return SemanticSignalWithContext(
                    signal: SemanticSignal(
                        id: row["id"],
                        chunkID: chunkID,
                        family: family,
                        value: value,
                        confidence: confidence,
                        modelID: modelID,
                        extractedAt: extractedAt
                    ),
                    chunkText: chunkText,
                    sourceCreatedAt: sourceCreatedAt,
                    targetAppName: row["targetAppName"],
                    transcriptionID: transcriptionID
                )
            }
        }
    }

    func clearSemanticMemory() throws {
        try dbQueue.write { db in
            try Self.deleteAllSemanticMemory(in: db)
        }
        Logger.memory.info("Semantic memory index cleared")
    }

    func fetchSemanticIndexSourceTranscriptions(limit: Int = 1_000) throws -> [Transcription] {
        try dbQueue.read { db in
            try Transcription
                .order(Column("createdAt").desc)
                .limit(max(1, limit))
                .fetchAll(db)
        }
    }

    func fetchSemanticEmbeddingChunkIDs(modelID: String) throws -> Set<Int64> {
        let normalizedModelID = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedModelID.isEmpty else { return [] }
        return try dbQueue.read { db in
            let ids = try Int64.fetchAll(
                db,
                sql: """
                SELECT chunkID
                FROM semantic_embedding
                WHERE modelID = ?
                """,
                arguments: [normalizedModelID]
            )
            return Set(ids)
        }
    }

    func upsertSemanticChunks(for transcription: Transcription, drafts: [SemanticChunkDraft]) throws -> [SemanticChunk] {
        guard let transcriptionID = transcription.id else { return [] }
        return try dbQueue.write { db in
            let existingRows = try SemanticChunk
                .filter(Column("transcriptionID") == transcriptionID)
                .fetchAll(db)
            let draftIndexes = Set(drafts.map(\.chunkIndex))
            let staleChunkIDs = existingRows
                .filter { !draftIndexes.contains($0.chunkIndex) }
                .compactMap(\.id)
            if !staleChunkIDs.isEmpty {
                try db.execute(
                    sql: "DELETE FROM semantic_embedding WHERE chunkID IN \(staleChunkIDs.sqlInList)",
                    arguments: StatementArguments(staleChunkIDs)
                )
                try db.execute(
                    sql: "DELETE FROM semantic_chunk WHERE id IN \(staleChunkIDs.sqlInList)",
                    arguments: StatementArguments(staleChunkIDs)
                )
            }

            var chunks: [SemanticChunk] = []
            for draft in drafts {
                let now = Date()
                if var existing = existingRows.first(where: { $0.chunkIndex == draft.chunkIndex }) {
                    let textChanged = existing.textHash != draft.textHash
                    existing.text = draft.text
                    existing.textHash = draft.textHash
                    existing.sourceCreatedAt = draft.sourceCreatedAt
                    existing.targetAppName = draft.targetAppName
                    existing.targetAppBundleID = draft.targetAppBundleID
                    existing.wordCount = draft.wordCount
                    existing.updatedAt = now
                    try existing.update(db)
                    if textChanged, let chunkID = existing.id {
                        try db.execute(
                            sql: "DELETE FROM semantic_embedding WHERE chunkID = ?",
                            arguments: [chunkID]
                        )
                    }
                    chunks.append(existing)
                } else {
                    var chunk = SemanticChunk(
                        transcriptionID: draft.transcriptionID,
                        chunkIndex: draft.chunkIndex,
                        text: draft.text,
                        textHash: draft.textHash,
                        sourceCreatedAt: draft.sourceCreatedAt,
                        targetAppName: draft.targetAppName,
                        targetAppBundleID: draft.targetAppBundleID,
                        wordCount: draft.wordCount,
                        createdAt: now,
                        updatedAt: now
                    )
                    try chunk.insert(db)
                    if chunk.id == nil {
                        chunk.id = db.lastInsertedRowID
                    }
                    chunks.append(chunk)
                }
            }

            return chunks.sorted { $0.chunkIndex < $1.chunkIndex }
        }
    }

    func saveSemanticEmbedding(
        chunkID: Int64,
        modelID: String,
        providerName: String,
        dimension: Int,
        vectorData: Data,
        generatedAt: Date = Date()
    ) throws {
        let normalizedModelID = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedProviderName = providerName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedModelID.isEmpty, !normalizedProviderName.isEmpty, dimension > 0, !vectorData.isEmpty else {
            return
        }

        try dbQueue.write { db in
            try db.execute(
                sql: """
                INSERT INTO semantic_embedding (chunkID, modelID, providerName, dimension, vectorData, generatedAt)
                VALUES (?, ?, ?, ?, ?, ?)
                ON CONFLICT(chunkID, modelID) DO UPDATE SET
                    providerName = excluded.providerName,
                    dimension = excluded.dimension,
                    vectorData = excluded.vectorData,
                    generatedAt = excluded.generatedAt
                """,
                arguments: [chunkID, normalizedModelID, normalizedProviderName, dimension, vectorData, generatedAt]
            )
        }
    }

    func fetchEmbeddedSemanticChunks(modelID: String, limit: Int = 1_500) throws -> [SemanticEmbeddedChunk] {
        let normalizedModelID = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedModelID.isEmpty else { return [] }

        return try dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT
                    c.id AS chunkID,
                    c.transcriptionID,
                    c.chunkIndex,
                    c.text,
                    c.textHash,
                    c.sourceCreatedAt,
                    c.targetAppName,
                    c.targetAppBundleID,
                    c.wordCount,
                    e.modelID,
                    e.providerName,
                    e.dimension,
                    e.vectorData
                FROM semantic_chunk c
                JOIN semantic_embedding e ON e.chunkID = c.id
                WHERE e.modelID = ?
                ORDER BY c.sourceCreatedAt DESC, c.chunkIndex ASC
                LIMIT ?
                """,
                arguments: [normalizedModelID, max(1, limit)]
            )

            return rows.compactMap { row in
                guard let chunkID: Int64 = row["chunkID"],
                      let transcriptionID: Int64 = row["transcriptionID"],
                      let chunkIndex: Int = row["chunkIndex"],
                      let text: String = row["text"],
                      let textHash: String = row["textHash"],
                      let sourceCreatedAt: Date = row["sourceCreatedAt"],
                      let wordCount: Int = row["wordCount"],
                      let modelID: String = row["modelID"],
                      let providerName: String = row["providerName"],
                      let dimension: Int = row["dimension"],
                      let vectorData: Data = row["vectorData"] else {
                    return nil
                }

                return SemanticEmbeddedChunk(
                    chunkID: chunkID,
                    transcriptionID: transcriptionID,
                    chunkIndex: chunkIndex,
                    text: text,
                    textHash: textHash,
                    sourceCreatedAt: sourceCreatedAt,
                    targetAppName: row["targetAppName"],
                    targetAppBundleID: row["targetAppBundleID"],
                    wordCount: wordCount,
                    modelID: modelID,
                    providerName: providerName,
                    dimension: dimension,
                    vectorData: vectorData
                )
            }
        }
    }

    func replaceSemanticGraph(nodes: [SemanticGraphNode], edges: [SemanticGraphEdge]) throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM semantic_graph_edge")
            try db.execute(sql: "DELETE FROM semantic_graph_node")

            for node in nodes {
                try node.insert(db)
            }
            for edge in edges {
                try edge.insert(db)
            }
        }
    }

    func fetchSemanticGraph(limitNodes: Int = 180, limitEdges: Int = 360) throws -> SemanticMemoryGraph {
        try dbQueue.read { db in
            let nodes = try SemanticGraphNode
                .order(Column("weight").desc, Column("title").asc)
                .limit(max(1, limitNodes))
                .fetchAll(db)
            let nodeIDs = Set(nodes.map(\.nodeID))
            let edges = try SemanticGraphEdge
                .order(Column("weight").desc)
                .fetchAll(db)
                .filter { nodeIDs.contains($0.sourceNodeID) && nodeIDs.contains($0.targetNodeID) }
                .prefix(max(1, limitEdges))
            return SemanticMemoryGraph(nodes: nodes, edges: Array(edges))
        }
    }

    @discardableResult
    func saveSemanticInsightSnapshot(_ report: SemanticInsightReport) throws -> Int64 {
        try dbQueue.write { db in
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let reportData = try encoder.encode(report)
            guard let reportJSONString = String(data: reportData, encoding: .utf8) else {
                throw NSError(
                    domain: "com.orttaai.database",
                    code: 23,
                    userInfo: [NSLocalizedDescriptionKey: "Unable to encode semantic insight snapshot."]
                )
            }

            let record = SemanticInsightSnapshotRecord(
                generatedAt: report.generatedAt,
                graphSignature: report.graphSignature,
                analyzerName: report.analyzerName,
                summaryModelName: report.summaryModelName,
                sourceNodeCount: report.sourceNodeCount,
                sourceEdgeCount: report.sourceEdgeCount,
                sourceChunkCount: report.sourceChunkCount,
                reportJSON: reportJSONString
            )
            try record.insert(db)
            let insertedID = record.id ?? db.lastInsertedRowID

            let count = try SemanticInsightSnapshotRecord.fetchCount(db)
            if count > Self.maxInsightSnapshots {
                let overflow = count - Self.maxInsightSnapshots
                try db.execute(
                    sql: """
                    DELETE FROM semantic_insight_snapshot WHERE id IN (
                        SELECT id FROM semantic_insight_snapshot
                        ORDER BY generatedAt ASC, id ASC
                        LIMIT ?
                    )
                    """,
                    arguments: [overflow]
                )
            }

            return insertedID
        }
    }

    func fetchLatestSemanticInsightSnapshot() throws -> SemanticInsightReport? {
        try dbQueue.read { db in
            guard let record = try SemanticInsightSnapshotRecord
                .order(Column("generatedAt").desc, Column("id").desc)
                .fetchOne(db) else {
                return nil
            }

            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(SemanticInsightReport.self, from: Data(record.reportJSON.utf8))
        }
    }

    func fetchSemanticInsightSnapshots(limit: Int = 30) throws -> [SemanticInsightReport] {
        try dbQueue.read { db in
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let records = try SemanticInsightSnapshotRecord
                .order(Column("generatedAt").desc, Column("id").desc)
                .limit(max(1, limit))
                .fetchAll(db)

            return try records.map { record in
                try decoder.decode(SemanticInsightReport.self, from: Data(record.reportJSON.utf8))
            }
        }
    }

    func fetchSemanticMemoryStats(modelID: String) throws -> SemanticMemoryStats {
        let normalizedModelID = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        return try dbQueue.read { db in
            let chunkCount = try SemanticChunk.fetchCount(db)
            let embeddedChunkCount = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM semantic_embedding WHERE modelID = ?",
                arguments: [normalizedModelID]
            ) ?? 0
            let nodeCount = try SemanticGraphNode.fetchCount(db)
            let edgeCount = try SemanticGraphEdge.fetchCount(db)
            let latestIndexedAt = try Date.fetchOne(
                db,
                sql: "SELECT MAX(generatedAt) FROM semantic_embedding WHERE modelID = ?",
                arguments: [normalizedModelID]
            )

            return SemanticMemoryStats(
                chunkCount: chunkCount,
                embeddedChunkCount: embeddedChunkCount,
                nodeCount: nodeCount,
                edgeCount: edgeCount,
                activeModelID: normalizedModelID,
                latestIndexedAt: latestIndexedAt
            )
        }
    }

    // MARK: - Writing Insights

    @discardableResult
    func saveWritingInsightSnapshot(_ snapshot: WritingInsightSnapshot) throws -> Int64 {
        let insertedID = try dbQueue.write { db in
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

            let record = WritingInsightSnapshotRecord(
                generatedAt: snapshot.generatedAt,
                analyzerName: snapshot.analyzerName,
                usedFallback: snapshot.usedFallback,
                isPinned: false,
                sampleCount: snapshot.sampleCount,
                requestJSON: requestJSONString,
                snapshotJSON: snapshotJSONString
            )
            try record.insert(db)
            let insertedID = record.id ?? db.lastInsertedRowID
            try Self.touchSyncMetadata(
                in: db,
                table: CloudSyncTable.writingInsightSnapshot.rawValue,
                id: insertedID,
                modifiedAt: snapshot.generatedAt
            )

            let count = try WritingInsightSnapshotRecord.fetchCount(db)
            if count > Self.maxInsightSnapshots {
                let toDelete = count - Self.maxInsightSnapshots
                try Self.recordTombstones(
                    in: db,
                    table: .writingInsightSnapshot,
                    where: """
                    id IN (
                        SELECT id FROM writing_insight_snapshot
                        WHERE isPinned = 0
                        ORDER BY generatedAt ASC, id ASC
                        LIMIT \(toDelete)
                    )
                    """
                )
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
                    try Self.recordTombstones(
                        in: db,
                        table: .writingInsightSnapshot,
                        where: """
                        id IN (
                            SELECT id FROM writing_insight_snapshot
                            ORDER BY generatedAt ASC, id ASC
                            LIMIT \(overflow)
                        )
                        """
                    )
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

            return insertedID
        }
        requestCloudSyncIfEnabled()
        return insertedID
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
                SET isPinned = ?,
                    modifiedAt = ?,
                    lastSyncedAt = NULL
                WHERE id = ?
                """,
                arguments: [isPinned, Date(), id]
            )
        }
        requestCloudSyncIfEnabled()
    }

    @discardableResult
    func deleteWritingInsightSnapshot(id: Int64) throws -> Bool {
        let deleted = try dbQueue.write { db in
            try Self.recordTombstone(in: db, table: .writingInsightSnapshot, id: id)
            return try WritingInsightSnapshotRecord.deleteOne(db, key: id)
        }
        if deleted {
            requestCloudSyncIfEnabled()
        }
        return deleted
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

    private func postPersonalMemoryDidChange() {
        NotificationCenter.default.post(name: .personalMemoryDidChange, object: nil)
    }

    private func requestCloudSyncIfEnabled() {
        CloudSyncScheduler.requestSync(reason: .localChange)
    }

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

        let entry = try dbQueue.write { db in
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
                if let id = existing.id {
                    try Self.touchSyncMetadata(in: db, table: CloudSyncTable.dictionaryEntry.rawValue, id: id, modifiedAt: now)
                }
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
            if let id = entry.id {
                try Self.touchSyncMetadata(in: db, table: CloudSyncTable.dictionaryEntry.rawValue, id: id, modifiedAt: now)
            }
            return entry
        }
        postPersonalMemoryDidChange()
        requestCloudSyncIfEnabled()
        return entry
    }

    func deleteDictionaryEntry(id: Int64) throws -> Bool {
        let deleted = try dbQueue.write { db in
            try Self.recordTombstone(in: db, table: .dictionaryEntry, id: id)
            return try DictionaryEntry.deleteOne(db, key: id)
        }
        if deleted {
            postPersonalMemoryDidChange()
            requestCloudSyncIfEnabled()
        }
        return deleted
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

        let entry = try dbQueue.write { db in
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
            if let id = entry.id {
                try Self.touchSyncMetadata(in: db, table: CloudSyncTable.dictionaryEntry.rawValue, id: id, modifiedAt: entry.updatedAt)
            }
            return entry
        }
        postPersonalMemoryDidChange()
        requestCloudSyncIfEnabled()
        return entry
    }

    func incrementDictionaryUsage(id: Int64) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                UPDATE dictionary_entry
                SET usageCount = usageCount + 1,
                    updatedAt = ?,
                    modifiedAt = ?,
                    lastSyncedAt = NULL
                WHERE id = ?
                """,
                arguments: [Date(), Date(), id]
            )
        }
        requestCloudSyncIfEnabled()
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

        let entry = try dbQueue.write { db in
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
                if let id = existing.id {
                    try Self.touchSyncMetadata(in: db, table: CloudSyncTable.snippetEntry.rawValue, id: id, modifiedAt: now)
                }
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
            if let id = entry.id {
                try Self.touchSyncMetadata(in: db, table: CloudSyncTable.snippetEntry.rawValue, id: id, modifiedAt: now)
            }
            return entry
        }
        postPersonalMemoryDidChange()
        requestCloudSyncIfEnabled()
        return entry
    }

    func deleteSnippetEntry(id: Int64) throws -> Bool {
        let deleted = try dbQueue.write { db in
            try Self.recordTombstone(in: db, table: .snippetEntry, id: id)
            return try SnippetEntry.deleteOne(db, key: id)
        }
        if deleted {
            postPersonalMemoryDidChange()
            requestCloudSyncIfEnabled()
        }
        return deleted
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

        let entry = try dbQueue.write { db in
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
            if let id = entry.id {
                try Self.touchSyncMetadata(in: db, table: CloudSyncTable.snippetEntry.rawValue, id: id, modifiedAt: entry.updatedAt)
            }
            return entry
        }
        postPersonalMemoryDidChange()
        requestCloudSyncIfEnabled()
        return entry
    }

    func incrementSnippetUsage(id: Int64) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                UPDATE snippet_entry
                SET usageCount = usageCount + 1,
                    updatedAt = ?,
                    modifiedAt = ?,
                    lastSyncedAt = NULL
                WHERE id = ?
                """,
                arguments: [Date(), Date(), id]
            )
        }
        requestCloudSyncIfEnabled()
    }

    @discardableResult
    func saveLearningSuggestions(_ drafts: [LearningSuggestionDraft]) throws -> Int {
        let changeCount = try dbQueue.write { db in
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
                    if let id = existing.id {
                        try Self.touchSyncMetadata(in: db, table: CloudSyncTable.learningSuggestion.rawValue, id: id, modifiedAt: now)
                    }
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
                try Self.touchSyncMetadata(
                    in: db,
                    table: CloudSyncTable.learningSuggestion.rawValue,
                    id: db.lastInsertedRowID,
                    modifiedAt: now
                )
                changeCount += 1
            }

            return changeCount
        }
        if changeCount > 0 {
            requestCloudSyncIfEnabled()
        }
        return changeCount
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
            let now = Date()
            try db.execute(
                sql: """
                UPDATE learning_suggestion
                SET status = ?,
                    updatedAt = ?,
                    modifiedAt = ?,
                    lastSyncedAt = NULL
                WHERE id = ?
                """,
                arguments: [status.rawValue, now, now, id]
            )
        }
        requestCloudSyncIfEnabled()
    }

    func clearLearningSuggestions(status: LearningSuggestionStatus? = nil) throws {
        try dbQueue.write { db in
            if let status {
                try Self.recordTombstones(
                    in: db,
                    table: .learningSuggestion,
                    where: "status = '\(status.rawValue)'"
                )
                try db.execute(
                    sql: "DELETE FROM learning_suggestion WHERE status = ?",
                    arguments: [status.rawValue]
                )
            } else {
                try Self.recordTombstones(in: db, table: .learningSuggestion)
                try LearningSuggestion.deleteAll(db)
            }
        }
        requestCloudSyncIfEnabled()
    }

    func logSkippedRecording(duration: TimeInterval) {
        Logger.database.info("Skipped recording: \(duration, format: .fixed(precision: 2))s (< 0.5s)")
    }

    // MARK: - Observation

    func observeTranscriptions(
        limit: Int? = 50,
        onChange: @escaping ([Transcription]) -> Void
    ) -> DatabaseCancellable {
        let observation = ValueObservation.tracking { db in
            var request = Transcription
                .order(Column("createdAt").desc)

            if let limit {
                request = request.limit(limit)
            }

            return try request.fetchAll(db)
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

// MARK: - Cloud Sync Export/Import

extension DatabaseManager {
    func cloudSyncSnapshot() throws -> CloudDatabaseSnapshot {
        try dbQueue.write { db in
            try Self.repairMissingCloudSyncMetadata(in: db)

            return CloudDatabaseSnapshot(
                transcriptions: try Self.fetchCloudTranscriptions(in: db),
                dictionaryEntries: try Self.fetchCloudDictionaryEntries(in: db),
                snippetEntries: try Self.fetchCloudSnippetEntries(in: db),
                learningSuggestions: try Self.fetchCloudLearningSuggestions(in: db),
                writingInsightSnapshots: try Self.fetchCloudWritingInsightSnapshots(in: db),
                tombstones: try Self.fetchCloudTombstones(in: db)
            )
        }
    }

    func cloudSyncStats() throws -> CloudSyncStats {
        try cloudSyncSnapshot().stats
    }

    func applyCloudSnapshot(_ snapshot: CloudDatabaseSnapshot, replacingLocalData: Bool) throws {
        try dbQueue.write { db in
            if replacingLocalData {
                try Self.deleteAllSemanticMemory(in: db)
                try db.execute(sql: "DELETE FROM transcription")
                try db.execute(sql: "DELETE FROM dictionary_entry")
                try db.execute(sql: "DELETE FROM snippet_entry")
                try db.execute(sql: "DELETE FROM learning_suggestion")
                try db.execute(sql: "DELETE FROM writing_insight_snapshot")
                try db.execute(sql: "DELETE FROM cloud_sync_tombstone")
            }

            for record in snapshot.transcriptions {
                try Self.upsertCloudTranscription(record, in: db)
                try Self.clearTombstone(in: db, table: .transcription, syncID: record.syncID)
            }
            for record in snapshot.dictionaryEntries {
                try Self.upsertCloudDictionaryEntry(record, in: db)
                try Self.clearTombstone(in: db, table: .dictionaryEntry, syncID: record.syncID)
            }
            for record in snapshot.snippetEntries {
                try Self.upsertCloudSnippetEntry(record, in: db)
                try Self.clearTombstone(in: db, table: .snippetEntry, syncID: record.syncID)
            }
            for record in snapshot.learningSuggestions {
                try Self.upsertCloudLearningSuggestion(record, in: db)
                try Self.clearTombstone(in: db, table: .learningSuggestion, syncID: record.syncID)
            }
            for record in snapshot.writingInsightSnapshots {
                try Self.upsertCloudWritingInsightSnapshot(record, in: db)
                try Self.clearTombstone(in: db, table: .writingInsightSnapshot, syncID: record.syncID)
            }
            for tombstone in snapshot.tombstones {
                try Self.applyCloudTombstone(tombstone, in: db)
            }
        }

        NotificationCenter.default.post(name: .personalMemoryDidChange, object: nil)
    }

    func markCloudSyncCompleted(at date: Date = Date()) throws {
        try dbQueue.write { db in
            for table in CloudSyncTable.allCases {
                try db.execute(
                    sql: """
                    UPDATE \(table.rawValue)
                    SET lastSyncedAt = ?
                    WHERE lastSyncedAt IS NULL OR lastSyncedAt < modifiedAt
                    """,
                    arguments: [date]
                )
            }
            try db.execute(
                sql: """
                UPDATE cloud_sync_tombstone
                SET needsCloudSync = 0
                WHERE needsCloudSync = 1
                """
            )
            try db.execute(
                sql: """
                INSERT INTO cloud_sync_state (key, value, updatedAt)
                VALUES ('lastCompletedAt', ?, ?)
                ON CONFLICT(key) DO UPDATE SET
                    value = excluded.value,
                    updatedAt = excluded.updatedAt
                """,
                arguments: [String(date.timeIntervalSince1970), date]
            )
        }
    }

    private static func repairMissingCloudSyncMetadata(in db: Database) throws {
        let now = Date()
        for table in CloudSyncTable.allCases {
            try db.execute(
                sql: """
                UPDATE \(table.rawValue)
                SET syncID = lower(hex(randomblob(16)))
                WHERE syncID IS NULL OR TRIM(syncID) = ''
                """
            )
            let fallbackColumn: String
            switch table {
            case .transcription:
                fallbackColumn = "createdAt"
            case .dictionaryEntry, .snippetEntry, .learningSuggestion:
                fallbackColumn = "updatedAt"
            case .writingInsightSnapshot:
                fallbackColumn = "generatedAt"
            }
            try db.execute(
                sql: """
                UPDATE \(table.rawValue)
                SET modifiedAt = COALESCE(modifiedAt, \(fallbackColumn), ?)
                WHERE modifiedAt IS NULL
                """,
                arguments: [now]
            )
        }
    }

    private static func fetchCloudTranscriptions(in db: Database) throws -> [CloudSyncTranscription] {
        let rows = try Row.fetchAll(
            db,
            sql: """
            SELECT id, syncID, modifiedAt, createdAt, text, targetAppName, targetAppBundleID,
                   recordingDurationMs, processingDurationMs, settingsSyncDurationMs,
                   transcriptionDurationMs, textProcessingDurationMs, injectionDurationMs,
                   appActivationDurationMs, clipboardRestoreDelayMs, modelId, audioDevice,
                   sourceDeviceID
            FROM transcription
            WHERE syncID IS NOT NULL
            """
        )
        return rows.compactMap { row in
            guard let syncID: String = row["syncID"],
                  let modifiedAt: Date = row["modifiedAt"],
                  let createdAt: Date = row["createdAt"],
                  let text: String = row["text"],
                  let recordingDurationMs: Int = row["recordingDurationMs"],
                  let processingDurationMs: Int = row["processingDurationMs"],
                  let modelId: String = row["modelId"] else {
                return nil
            }
            return CloudSyncTranscription(
                localID: row["id"],
                syncID: syncID,
                modifiedAt: modifiedAt,
                createdAt: createdAt,
                text: text,
                targetAppName: row["targetAppName"],
                targetAppBundleID: row["targetAppBundleID"],
                recordingDurationMs: recordingDurationMs,
                processingDurationMs: processingDurationMs,
                settingsSyncDurationMs: row["settingsSyncDurationMs"],
                transcriptionDurationMs: row["transcriptionDurationMs"],
                textProcessingDurationMs: row["textProcessingDurationMs"],
                injectionDurationMs: row["injectionDurationMs"],
                appActivationDurationMs: row["appActivationDurationMs"],
                clipboardRestoreDelayMs: row["clipboardRestoreDelayMs"],
                modelId: modelId,
                audioDevice: row["audioDevice"],
                sourceDeviceID: row["sourceDeviceID"]
            )
        }
    }

    private static func fetchCloudDictionaryEntries(in db: Database) throws -> [CloudSyncDictionaryEntry] {
        let rows = try Row.fetchAll(
            db,
            sql: """
            SELECT id, syncID, modifiedAt, source, target, normalizedSource, isCaseSensitive,
                   isActive, usageCount, createdAt, updatedAt
            FROM dictionary_entry
            WHERE syncID IS NOT NULL
            """
        )
        return rows.compactMap { row in
            guard let syncID: String = row["syncID"],
                  let modifiedAt: Date = row["modifiedAt"],
                  let source: String = row["source"],
                  let target: String = row["target"],
                  let normalizedSource: String = row["normalizedSource"],
                  let isCaseSensitive: Bool = row["isCaseSensitive"],
                  let isActive: Bool = row["isActive"],
                  let usageCount: Int = row["usageCount"],
                  let createdAt: Date = row["createdAt"],
                  let updatedAt: Date = row["updatedAt"] else {
                return nil
            }
            return CloudSyncDictionaryEntry(
                localID: row["id"],
                syncID: syncID,
                modifiedAt: modifiedAt,
                source: source,
                target: target,
                normalizedSource: normalizedSource,
                isCaseSensitive: isCaseSensitive,
                isActive: isActive,
                usageCount: usageCount,
                createdAt: createdAt,
                updatedAt: updatedAt
            )
        }
    }

    private static func fetchCloudSnippetEntries(in db: Database) throws -> [CloudSyncSnippetEntry] {
        let rows = try Row.fetchAll(
            db,
            sql: """
            SELECT id, syncID, modifiedAt, trigger, expansion, normalizedTrigger, isActive,
                   usageCount, createdAt, updatedAt
            FROM snippet_entry
            WHERE syncID IS NOT NULL
            """
        )
        return rows.compactMap { row in
            guard let syncID: String = row["syncID"],
                  let modifiedAt: Date = row["modifiedAt"],
                  let trigger: String = row["trigger"],
                  let expansion: String = row["expansion"],
                  let normalizedTrigger: String = row["normalizedTrigger"],
                  let isActive: Bool = row["isActive"],
                  let usageCount: Int = row["usageCount"],
                  let createdAt: Date = row["createdAt"],
                  let updatedAt: Date = row["updatedAt"] else {
                return nil
            }
            return CloudSyncSnippetEntry(
                localID: row["id"],
                syncID: syncID,
                modifiedAt: modifiedAt,
                trigger: trigger,
                expansion: expansion,
                normalizedTrigger: normalizedTrigger,
                isActive: isActive,
                usageCount: usageCount,
                createdAt: createdAt,
                updatedAt: updatedAt
            )
        }
    }

    private static func fetchCloudLearningSuggestions(in db: Database) throws -> [CloudSyncLearningSuggestion] {
        let rows = try Row.fetchAll(
            db,
            sql: """
            SELECT id, syncID, modifiedAt, type, candidateSource, candidateTarget,
                   normalizedSource, confidence, status, evidence, createdAt, updatedAt
            FROM learning_suggestion
            WHERE syncID IS NOT NULL
            """
        )
        return rows.compactMap { row in
            guard let syncID: String = row["syncID"],
                  let modifiedAt: Date = row["modifiedAt"],
                  let type: String = row["type"],
                  let candidateSource: String = row["candidateSource"],
                  let candidateTarget: String = row["candidateTarget"],
                  let normalizedSource: String = row["normalizedSource"],
                  let confidence: Double = row["confidence"],
                  let status: String = row["status"],
                  let createdAt: Date = row["createdAt"],
                  let updatedAt: Date = row["updatedAt"] else {
                return nil
            }
            return CloudSyncLearningSuggestion(
                localID: row["id"],
                syncID: syncID,
                modifiedAt: modifiedAt,
                type: type,
                candidateSource: candidateSource,
                candidateTarget: candidateTarget,
                normalizedSource: normalizedSource,
                confidence: confidence,
                status: status,
                evidence: row["evidence"],
                createdAt: createdAt,
                updatedAt: updatedAt
            )
        }
    }

    private static func fetchCloudWritingInsightSnapshots(in db: Database) throws -> [CloudSyncWritingInsightSnapshot] {
        let rows = try Row.fetchAll(
            db,
            sql: """
            SELECT id, syncID, modifiedAt, generatedAt, analyzerName, usedFallback,
                   isPinned, sampleCount, requestJSON, snapshotJSON
            FROM writing_insight_snapshot
            WHERE syncID IS NOT NULL
            """
        )
        return rows.compactMap { row in
            guard let syncID: String = row["syncID"],
                  let modifiedAt: Date = row["modifiedAt"],
                  let generatedAt: Date = row["generatedAt"],
                  let analyzerName: String = row["analyzerName"],
                  let usedFallback: Bool = row["usedFallback"],
                  let isPinned: Bool = row["isPinned"],
                  let sampleCount: Int = row["sampleCount"],
                  let requestJSON: String = row["requestJSON"],
                  let snapshotJSON: String = row["snapshotJSON"] else {
                return nil
            }
            return CloudSyncWritingInsightSnapshot(
                localID: row["id"],
                syncID: syncID,
                modifiedAt: modifiedAt,
                generatedAt: generatedAt,
                analyzerName: analyzerName,
                usedFallback: usedFallback,
                isPinned: isPinned,
                sampleCount: sampleCount,
                requestJSON: requestJSON,
                snapshotJSON: snapshotJSON
            )
        }
    }

    private static func fetchCloudTombstones(in db: Database) throws -> [CloudSyncTombstone] {
        let rows = try Row.fetchAll(
            db,
            sql: """
            SELECT tableName, syncID, deletedAt
            FROM cloud_sync_tombstone
            WHERE needsCloudSync = 1
            """
        )
        return rows.compactMap { row in
            guard let tableName: String = row["tableName"],
                  let table = CloudSyncTable(rawValue: tableName),
                  let syncID: String = row["syncID"],
                  let deletedAt: Date = row["deletedAt"] else {
                return nil
            }
            return CloudSyncTombstone(table: table, syncID: syncID, deletedAt: deletedAt)
        }
    }

    private static func upsertCloudTranscription(_ record: CloudSyncTranscription, in db: Database) throws {
        if let id = try localID(for: .transcription, syncID: record.syncID, in: db) {
            try db.execute(
                sql: """
                UPDATE transcription
                SET createdAt = ?, text = ?, targetAppName = ?, targetAppBundleID = ?,
                    recordingDurationMs = ?, processingDurationMs = ?, settingsSyncDurationMs = ?,
                    transcriptionDurationMs = ?, textProcessingDurationMs = ?, injectionDurationMs = ?,
                    appActivationDurationMs = ?, clipboardRestoreDelayMs = ?, modelId = ?,
                    audioDevice = ?, sourceDeviceID = ?, syncID = ?, modifiedAt = ?
                WHERE id = ?
                """,
                arguments: transcriptionArguments(record) + [id]
            )
        } else {
            try db.execute(
                sql: """
                INSERT INTO transcription (
                    createdAt, text, targetAppName, targetAppBundleID, recordingDurationMs,
                    processingDurationMs, settingsSyncDurationMs, transcriptionDurationMs,
                    textProcessingDurationMs, injectionDurationMs, appActivationDurationMs,
                    clipboardRestoreDelayMs, modelId, audioDevice, sourceDeviceID, syncID, modifiedAt
                )
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: transcriptionArguments(record)
            )
        }
    }

    private static func transcriptionArguments(_ record: CloudSyncTranscription) -> StatementArguments {
        [
            record.createdAt,
            record.text,
            record.targetAppName,
            record.targetAppBundleID,
            record.recordingDurationMs,
            record.processingDurationMs,
            record.settingsSyncDurationMs,
            record.transcriptionDurationMs,
            record.textProcessingDurationMs,
            record.injectionDurationMs,
            record.appActivationDurationMs,
            record.clipboardRestoreDelayMs,
            record.modelId,
            record.audioDevice,
            record.sourceDeviceID,
            record.syncID,
            record.modifiedAt
        ]
    }

    private static func upsertCloudDictionaryEntry(_ record: CloudSyncDictionaryEntry, in db: Database) throws {
        let id = try localID(for: .dictionaryEntry, syncID: record.syncID, in: db)
            ?? Int64.fetchOne(
                db,
                sql: "SELECT id FROM dictionary_entry WHERE normalizedSource = ?",
                arguments: [record.normalizedSource]
            )
        if let id {
            try db.execute(
                sql: """
                UPDATE dictionary_entry
                SET source = ?, target = ?, normalizedSource = ?, isCaseSensitive = ?,
                    isActive = ?, usageCount = ?, createdAt = ?, updatedAt = ?,
                    syncID = ?, modifiedAt = ?
                WHERE id = ?
                """,
                arguments: dictionaryArguments(record) + [id]
            )
        } else {
            try db.execute(
                sql: """
                INSERT INTO dictionary_entry (
                    source, target, normalizedSource, isCaseSensitive, isActive,
                    usageCount, createdAt, updatedAt, syncID, modifiedAt
                )
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: dictionaryArguments(record)
            )
        }
    }

    private static func dictionaryArguments(_ record: CloudSyncDictionaryEntry) -> StatementArguments {
        [
            record.source,
            record.target,
            record.normalizedSource,
            record.isCaseSensitive,
            record.isActive,
            record.usageCount,
            record.createdAt,
            record.updatedAt,
            record.syncID,
            record.modifiedAt
        ]
    }

    private static func upsertCloudSnippetEntry(_ record: CloudSyncSnippetEntry, in db: Database) throws {
        let id = try localID(for: .snippetEntry, syncID: record.syncID, in: db)
            ?? Int64.fetchOne(
                db,
                sql: "SELECT id FROM snippet_entry WHERE normalizedTrigger = ?",
                arguments: [record.normalizedTrigger]
            )
        if let id {
            try db.execute(
                sql: """
                UPDATE snippet_entry
                SET trigger = ?, expansion = ?, normalizedTrigger = ?, isActive = ?,
                    usageCount = ?, createdAt = ?, updatedAt = ?, syncID = ?, modifiedAt = ?
                WHERE id = ?
                """,
                arguments: snippetArguments(record) + [id]
            )
        } else {
            try db.execute(
                sql: """
                INSERT INTO snippet_entry (
                    trigger, expansion, normalizedTrigger, isActive, usageCount,
                    createdAt, updatedAt, syncID, modifiedAt
                )
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: snippetArguments(record)
            )
        }
    }

    private static func snippetArguments(_ record: CloudSyncSnippetEntry) -> StatementArguments {
        [
            record.trigger,
            record.expansion,
            record.normalizedTrigger,
            record.isActive,
            record.usageCount,
            record.createdAt,
            record.updatedAt,
            record.syncID,
            record.modifiedAt
        ]
    }

    private static func upsertCloudLearningSuggestion(_ record: CloudSyncLearningSuggestion, in db: Database) throws {
        if let id = try localID(for: .learningSuggestion, syncID: record.syncID, in: db) {
            try db.execute(
                sql: """
                UPDATE learning_suggestion
                SET type = ?, candidateSource = ?, candidateTarget = ?, normalizedSource = ?,
                    confidence = ?, status = ?, evidence = ?, createdAt = ?, updatedAt = ?,
                    syncID = ?, modifiedAt = ?
                WHERE id = ?
                """,
                arguments: learningSuggestionArguments(record) + [id]
            )
        } else {
            try db.execute(
                sql: """
                INSERT INTO learning_suggestion (
                    type, candidateSource, candidateTarget, normalizedSource, confidence,
                    status, evidence, createdAt, updatedAt, syncID, modifiedAt
                )
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: learningSuggestionArguments(record)
            )
        }
    }

    private static func learningSuggestionArguments(_ record: CloudSyncLearningSuggestion) -> StatementArguments {
        [
            record.type,
            record.candidateSource,
            record.candidateTarget,
            record.normalizedSource,
            record.confidence,
            record.status,
            record.evidence,
            record.createdAt,
            record.updatedAt,
            record.syncID,
            record.modifiedAt
        ]
    }

    private static func upsertCloudWritingInsightSnapshot(
        _ record: CloudSyncWritingInsightSnapshot,
        in db: Database
    ) throws {
        if let id = try localID(for: .writingInsightSnapshot, syncID: record.syncID, in: db) {
            try db.execute(
                sql: """
                UPDATE writing_insight_snapshot
                SET generatedAt = ?, analyzerName = ?, usedFallback = ?, isPinned = ?,
                    sampleCount = ?, requestJSON = ?, snapshotJSON = ?, syncID = ?, modifiedAt = ?
                WHERE id = ?
                """,
                arguments: writingInsightArguments(record) + [id]
            )
        } else {
            try db.execute(
                sql: """
                INSERT INTO writing_insight_snapshot (
                    generatedAt, analyzerName, usedFallback, isPinned, sampleCount,
                    requestJSON, snapshotJSON, syncID, modifiedAt
                )
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: writingInsightArguments(record)
            )
        }
    }

    private static func writingInsightArguments(_ record: CloudSyncWritingInsightSnapshot) -> StatementArguments {
        [
            record.generatedAt,
            record.analyzerName,
            record.usedFallback,
            record.isPinned,
            record.sampleCount,
            record.requestJSON,
            record.snapshotJSON,
            record.syncID,
            record.modifiedAt
        ]
    }

    private static func applyCloudTombstone(_ tombstone: CloudSyncTombstone, in db: Database) throws {
        let deletedTranscriptionID: Int64?
        if tombstone.table == .transcription {
            deletedTranscriptionID = try localID(for: .transcription, syncID: tombstone.syncID, in: db)
        } else {
            deletedTranscriptionID = nil
        }

        try db.execute(
            sql: "DELETE FROM \(tombstone.table.rawValue) WHERE syncID = ?",
            arguments: [tombstone.syncID]
        )
        if let deletedTranscriptionID {
            try deleteSemanticMemory(forTranscriptionID: deletedTranscriptionID, in: db)
        }
        try recordTombstone(
            in: db,
            table: tombstone.table,
            syncID: tombstone.syncID,
            deletedAt: tombstone.deletedAt,
            needsCloudSync: false
        )
    }

    private static func clearTombstone(in db: Database, table: CloudSyncTable, syncID: String) throws {
        try db.execute(
            sql: """
            DELETE FROM cloud_sync_tombstone
            WHERE tableName = ? AND syncID = ?
            """,
            arguments: [table.rawValue, syncID]
        )
    }

    private static func localID(for table: CloudSyncTable, syncID: String, in db: Database) throws -> Int64? {
        try Int64.fetchOne(
            db,
            sql: "SELECT id FROM \(table.rawValue) WHERE syncID = ?",
            arguments: [syncID]
        )
    }
}

private extension Array where Element == Int64 {
    var sqlInList: String {
        guard !isEmpty else { return "(NULL)" }
        return "(" + [String](repeating: "?", count: count).joined(separator: ",") + ")"
    }
}
