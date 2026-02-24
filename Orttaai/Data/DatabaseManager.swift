// DatabaseManager.swift
// Orttaai

import Foundation
import GRDB
import os

final class DatabaseManager {
    private let dbQueue: DatabaseQueue
    private static let maxRecords = 500

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

        return migrator
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

    func search(query: String) throws -> [Transcription] {
        try dbQueue.read { db in
            try Transcription
                .filter(Column("text").like("%\(query)%"))
                .order(Column("createdAt").desc)
                .fetchAll(db)
        }
    }

    func deleteAll() throws {
        try dbQueue.write { db in
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

    func logSkippedRecording(duration: TimeInterval) {
        Logger.database.info("Skipped recording: \(duration, format: .fixed(precision: 2))s (< 0.5s)")
    }

    // MARK: - Observation

    func observeTranscriptions(
        limit: Int = 50,
        onChange: @escaping ([Transcription]) -> Void
    ) -> DatabaseCancellable {
        let observation = DatabaseRegionObservation(tracking: Transcription.all())
        return observation.start(
            in: dbQueue,
            onError: { error in
                Logger.database.error("Observation error: \(error.localizedDescription)")
            },
            onChange: { _ in
                do {
                    let records = try self.fetchRecent(limit: limit)
                    onChange(records)
                } catch {
                    Logger.database.error("Observation fetch failed: \(error.localizedDescription)")
                }
            }
        )
    }
}
