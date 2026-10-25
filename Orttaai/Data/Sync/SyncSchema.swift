// SyncSchema.swift
// Orttaai
//
// The tables behind iCloud sync v2 and the migration that fills them from an
// existing database. Content tables (transcription, dictionary_entry, ...)
// keep their shape, so History, Home, search and analytics read them as
// before; sync keeps its own record of each one beside them:
//
// - sync_record: one row per synced record: its iCloud name and zone, its
//   revision, origin, CloudKit system fields, and durable tombstones for
//   deleted records (so a stale device can never bring one back).
// - sync_outbox: changes iCloud hasn't confirmed yet, written in the same
//   transaction as the change itself.
// - sync_zone, sync_kv, sync_quarantine: zone states, engine state and
//   flags, and records this version can't read yet.
// - semantic_index_queue: dictations whose semantic index needs building,
//   so a backfill of older dictations from the phone gets indexed too.

import Foundation
import GRDB
import OrttaaiSyncCore

nonisolated enum SyncSchema {
    static let migrationIdentifier = "v19_sync_v2"
    static let generationMigrationIdentifier = "v20_sync_generation"

    /// Revivable records' generation (SyncEnvelope.generation). Added only
    /// if missing, so databases that ran an early v19 get it too.
    static func addGeneration(_ db: Database) throws {
        guard !(try db.columns(in: "sync_record").contains { $0.name == "generation" }) else { return }
        try db.alter(table: "sync_record") { t in
            t.add(column: "generation", .integer).notNull().defaults(to: 0)
        }
    }

    /// Revision dates are stored as whole milliseconds so comparing an
    /// acknowledged revision with the stored one is exact.
    static func milliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1000).rounded())
    }

    static func date(milliseconds: Int64) -> Date {
        Date(timeIntervalSince1970: Double(milliseconds) / 1000)
    }

    static func migrate(_ db: Database, thisDeviceID: String) throws {
        try db.create(table: "sync_record") { t in
            t.column("recordName", .text).primaryKey()
            t.column("zoneName", .text).notNull()
            t.column("kind", .text).notNull()
            // The content row it mirrors; NULL for records kept only here
            // (devices, summaries, Mac settings) and for tombstones.
            t.column("localTable", .text)
            t.column("localID", .integer)
            t.column("revCounter", .integer).notNull()
            t.column("revModifiedAtMs", .integer).notNull()
            t.column("revWriter", .text).notNull()
            t.column("isDeleted", .boolean).notNull().defaults(to: false)
            t.column("deletedAt", .datetime)
            t.column("originDeviceID", .text)
            t.column("originKind", .text)
            t.column("createdAt", .datetime)
            t.column("systemFields", .blob)
            // The payload of records that have no content table.
            t.column("payload", .blob)
        }
        try db.create(index: "idx_sync_record_local", on: "sync_record", columns: ["localTable", "localID"])
        try db.create(index: "idx_sync_record_zone", on: "sync_record", columns: ["zoneName"])
        try db.create(index: "idx_sync_record_kind", on: "sync_record", columns: ["kind"])

        try db.create(table: "sync_outbox") { t in
            t.column("recordName", .text).primaryKey()
            t.column("revCounter", .integer).notNull()
            t.column("revModifiedAtMs", .integer).notNull()
            t.column("revWriter", .text).notNull()
            t.column("failedReason", .text)
            t.column("enqueuedAt", .datetime).notNull()
        }

        try db.create(table: "sync_zone") { t in
            t.column("zoneName", .text).primaryKey()
            t.column("state", .text).notNull()
        }

        try db.create(table: "sync_kv") { t in
            t.column("key", .text).primaryKey()
            t.column("value", .blob)
        }

        try db.create(table: "sync_quarantine") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("zoneName", .text).notNull()
            t.column("recordName", .text).notNull()
            t.column("recordType", .text).notNull()
            t.column("problem", .text).notNull()
            t.column("mayResolveAfterUpdate", .boolean).notNull()
            t.column("archivedRecord", .blob)
            t.column("receivedAt", .datetime).notNull()
        }

        try db.create(table: "semantic_index_queue") { t in
            t.column("transcriptionID", .integer).primaryKey()
            t.column("enqueuedAt", .datetime).notNull()
        }

        try db.alter(table: "transcription") { t in
            // mac, iphone, ipad or unknown: the kind of device it was said on.
            t.add(column: "sourceDeviceKind", .text)
        }

        try backfill(db, thisDeviceID: thisDeviceID)
    }

    /// Gives every existing row its sync record at revision 0 (older than any
    /// change made from now on) and queues it for the first upload. The
    /// v1 tombstones stay in cloud_sync_tombstone as barriers for the bridge.
    private static func backfill(_ db: Database, thisDeviceID: String) throws {
        let now = Date()

        // Dictations: the zone is where they were made. NULL never means
        // "this Mac": it may be an old row from another Mac.
        let transcriptions = try Row.fetchAll(db, sql: "SELECT id, syncID, sourceDeviceID, createdAt, modifiedAt FROM transcription")
        for row in transcriptions {
            guard let id: Int64 = row["id"], let syncID: String = row["syncID"], !syncID.isEmpty else { continue }
            let sourceDeviceID: String? = row["sourceDeviceID"]
            let kind: DeviceKind = sourceDeviceID == nil ? .unknown : .mac
            let zone = SyncRecordID.dictationZone(originDeviceID: sourceDeviceID)
            let recordID = SyncRecordID.dictation(syncID: syncID, zone: zone)
            try db.execute(sql: "UPDATE transcription SET sourceDeviceKind = ? WHERE id = ?", arguments: [kind.rawValue, id])
            try insertBackfilled(
                db,
                recordID: recordID,
                kind: .dictation,
                localTable: "transcription",
                localID: id,
                modifiedAt: row["modifiedAt"] ?? row["createdAt"] ?? now,
                writer: thisDeviceID,
                origin: DictationOrigin(deviceID: zone == .legacyDictations ? nil : sourceDeviceID, kind: kind),
                createdAt: row["createdAt"]
            )
        }

        // Dictionary and snippets get their shared name; if two local rows
        // land on one name, the newer one keeps it.
        for (table, keyColumn, kind) in [("dictionary_entry", "normalizedSource", RecordKind.dictionaryEntry), ("snippet_entry", "normalizedTrigger", .snippet)] {
            let rows = try Row.fetchAll(db, sql: "SELECT id, \(keyColumn) AS key, modifiedAt, updatedAt FROM \(table) ORDER BY modifiedAt DESC, id DESC")
            for row in rows {
                guard let id: Int64 = row["id"], let key: String = row["key"] else { continue }
                let recordID = kind == .dictionaryEntry
                    ? SyncRecordID.dictionaryEntry(normalizedSource: key)
                    : SyncRecordID.snippet(normalizedTrigger: key)
                let exists = try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM sync_record WHERE recordName = ?)", arguments: [recordID.recordName]) ?? false
                guard !exists else { continue }
                try insertBackfilled(db, recordID: recordID, kind: kind, localTable: table, localID: id, modifiedAt: row["modifiedAt"] ?? row["updatedAt"] ?? now, writer: thisDeviceID)
            }
        }

        try backfillV1Tombstones(db, thisDeviceID: thisDeviceID)

        for (table, kind) in [("learning_suggestion", RecordKind.learningSuggestion), ("writing_insight_snapshot", .writingInsight)] {
            let rows = try Row.fetchAll(db, sql: "SELECT id, syncID, modifiedAt FROM \(table)")
            for row in rows {
                guard let id: Int64 = row["id"], let syncID: String = row["syncID"], !syncID.isEmpty else { continue }
                let recordID = kind == .learningSuggestion
                    ? SyncRecordID.learningSuggestion(syncID: syncID)
                    : SyncRecordID.writingInsight(syncID: syncID)
                try insertBackfilled(db, recordID: recordID, kind: kind, localTable: table, localID: id, modifiedAt: row["modifiedAt"] ?? now, writer: thisDeviceID)
            }
        }
    }

    /// Deletions made under v1 become durable tombstones, so a copy another
    /// Mac still holds can't bring them back. Dictations and records with a
    /// v1 syncID map directly; dictionary words and snippets lost their
    /// source with their row, and stay covered by the bridge's barriers.
    /// Skips any that already exist, so it can run again (v20).
    static func backfillV1Tombstones(_ db: Database, thisDeviceID: String) throws {
        for row in try Row.fetchAll(db, sql: "SELECT tableName, syncID, deletedAt FROM cloud_sync_tombstone") {
            let syncID: String = row["syncID"]
            let deletedAt: Date = row["deletedAt"]
            let recordID: SyncRecordID
            let kind: RecordKind
            switch row["tableName"] as String {
            case "transcription":
                recordID = .dictation(syncID: syncID, zone: .legacyDictations)
                kind = .dictation
            case "learning_suggestion":
                recordID = .learningSuggestion(syncID: syncID)
                kind = .learningSuggestion
            case "writing_insight_snapshot":
                recordID = .writingInsight(syncID: syncID)
                kind = .writingInsight
            default:
                continue
            }
            guard try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM sync_record WHERE recordName = ?)", arguments: [recordID.recordName]) == false else { continue }
            let ms = milliseconds(deletedAt)
            try db.execute(sql: """
                INSERT INTO sync_record (recordName, zoneName, kind, revCounter, revModifiedAtMs, revWriter, isDeleted, deletedAt, originKind)
                VALUES (?, ?, ?, 0, ?, ?, 1, ?, ?)
                """, arguments: [recordID.recordName, recordID.zone.zoneName, kind.rawValue, ms, thisDeviceID, deletedAt, kind == .dictation ? DeviceKind.unknown.rawValue : nil])
            try db.execute(sql: "INSERT INTO sync_outbox (recordName, revCounter, revModifiedAtMs, revWriter, enqueuedAt) VALUES (?, 0, ?, ?, ?)",
                           arguments: [recordID.recordName, ms, thisDeviceID, Date()])
        }
    }

    private static func insertBackfilled(
        _ db: Database,
        recordID: SyncRecordID,
        kind: RecordKind,
        localTable: String,
        localID: Int64,
        modifiedAt: Date,
        writer: String,
        origin: DictationOrigin? = nil,
        createdAt: Date? = nil
    ) throws {
        let ms = milliseconds(modifiedAt)
        try db.execute(
            sql: """
            INSERT INTO sync_record (recordName, zoneName, kind, localTable, localID, revCounter, revModifiedAtMs, revWriter, isDeleted, originDeviceID, originKind, createdAt)
            VALUES (?, ?, ?, ?, ?, 0, ?, ?, 0, ?, ?, ?)
            """,
            arguments: [recordID.recordName, recordID.zone.zoneName, kind.rawValue, localTable, localID, ms, writer, origin?.deviceID, origin?.kind.rawValue, createdAt]
        )
        try db.execute(
            sql: """
            INSERT INTO sync_outbox (recordName, revCounter, revModifiedAtMs, revWriter, enqueuedAt)
            VALUES (?, 0, ?, ?, ?)
            """,
            arguments: [recordID.recordName, ms, writer, Date()]
        )
    }
}
