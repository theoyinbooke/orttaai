// MacSyncStore.swift
// Orttaai
//
// The SyncStore behind Orttaai's database. Everything goes through
// DatabaseManager's shared queue, so History and Home observe what sync
// writes. Incoming records update rows in place by their sync identity:
// local IDs, embeddings and edit checks survive, and usage counts stay local.

import Foundation
import GRDB
import OrttaaiSyncCore
import os

/// What this Mac says about itself in its Device record.
nonisolated struct SyncDeviceInfo: Sendable {
    var deviceID: String
    var name: String
    var model: String?
    var appVersion: String?
    var osVersion: String?
}

nonisolated final class MacSyncStore: SyncStore, @unchecked Sendable {
    private let dbQueue: DatabaseQueue
    private let device: SyncDeviceInfo
    private let logger = Logger(subsystem: "com.orttaai.sync", category: "store")

    init(dbQueue: DatabaseQueue, device: SyncDeviceInfo) {
        self.dbQueue = dbQueue
        self.device = device
    }

    // MARK: Sending

    func outboxEntries() throws -> [OutboxEntry] {
        try dbQueue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT o.recordName, o.revCounter, o.revModifiedAtMs, o.revWriter, r.zoneName
                FROM sync_outbox o JOIN sync_record r ON r.recordName = o.recordName
                """).compactMap { row -> OutboxEntry? in
                guard let zoneName: String = row["zoneName"], let zone = SyncZone(zoneName: zoneName),
                      let recordName: String = row["recordName"] else { return nil }
                return OutboxEntry(
                    id: SyncRecordID(zone: zone, recordName: recordName),
                    revision: Self.revision(row, counter: "revCounter", ms: "revModifiedAtMs", writer: "revWriter")
                )
            }
        }
    }

    func outgoingRecord(for id: SyncRecordID) throws -> OutgoingRecord? {
        try dbQueue.write { db in
            guard try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM sync_outbox WHERE recordName = ?)", arguments: [id.recordName]) == true,
                  let record = try Row.fetchOne(db, sql: "SELECT * FROM sync_record WHERE recordName = ?", arguments: [id.recordName]),
                  record["zoneName"] as String? == id.zone.zoneName,
                  let kind = id.kind else { return nil }

            let isDeleted: Bool = record["isDeleted"]
            var payload: Data?
            if !isDeleted {
                payload = try currentPayload(kind: kind, record: record, in: db)
                guard payload != nil else {
                    logger.error("No content for \(id.recordName, privacy: .public); not sending")
                    return nil
                }
            }
            var origin: DictationOrigin?
            if kind == .dictation {
                origin = DictationOrigin(
                    deviceID: record["originDeviceID"],
                    kind: (record["originKind"] as String?).flatMap(DeviceKind.init(rawValue:)) ?? .unknown
                )
            }
            let envelope = SyncEnvelope(
                id: id,
                revision: Self.revision(record, counter: "revCounter", ms: "revModifiedAtMs", writer: "revWriter"),
                generation: record["generation"],
                isDeleted: isDeleted,
                deletedAt: record["deletedAt"],
                payload: payload,
                origin: origin,
                createdAt: record["createdAt"]
            )
            return OutgoingRecord(envelope: envelope, systemFields: record["systemFields"])
        }
    }

    /// The payload for a live record, read from its content row (or, for
    /// records kept only here, from sync_record; devices and summaries are
    /// recomputed so they're never stale).
    private func currentPayload(kind: RecordKind, record: Row, in db: Database) throws -> Data? {
        let localID: Int64? = record["localID"]
        switch kind {
        case .dictation:
            guard let localID, let row = try Row.fetchOne(db, sql: "SELECT * FROM transcription WHERE id = ?", arguments: [localID]) else { return nil }
            return try PayloadCoder.encode(Self.dictationPayload(row))
        case .dictionaryEntry:
            guard let localID, let entry = try DictionaryEntry.fetchOne(db, key: localID) else { return nil }
            var payload = DictionaryEntryPayload(source: entry.source, target: entry.target, isCaseSensitive: entry.isCaseSensitive, isActive: entry.isActive, createdAt: entry.createdAt)
            payload.normalizedSource = entry.normalizedSource
            return try PayloadCoder.encode(payload)
        case .snippet:
            guard let localID, let entry = try SnippetEntry.fetchOne(db, key: localID) else { return nil }
            var payload = SnippetPayload(trigger: entry.trigger, expansion: entry.expansion, isActive: entry.isActive, createdAt: entry.createdAt)
            payload.normalizedTrigger = entry.normalizedTrigger
            return try PayloadCoder.encode(payload)
        case .learningSuggestion:
            guard let localID, let entry = try LearningSuggestion.fetchOne(db, key: localID) else { return nil }
            return try PayloadCoder.encode(LearningSuggestionPayload(
                type: entry.type, candidateSource: entry.candidateSource, candidateTarget: entry.candidateTarget,
                normalizedSource: entry.normalizedSource, confidence: entry.confidence, status: entry.status,
                evidence: entry.evidence, createdAt: entry.createdAt
            ))
        case .writingInsight:
            guard let localID, let entry = try WritingInsightSnapshotRecord.fetchOne(db, key: localID) else { return nil }
            return try PayloadCoder.encode(OrttaaiSyncCore.WritingInsightPayload(
                generatedAt: entry.generatedAt, analyzerName: entry.analyzerName, usedFallback: entry.usedFallback,
                isPinned: entry.isPinned, sampleCount: entry.sampleCount, requestJSON: entry.requestJSON, snapshotJSON: entry.snapshotJSON
            ))
        case .device:
            return try PayloadCoder.encode(try devicePayload(in: db))
        case .macSummary:
            return try PayloadCoder.encode(try summaryPayload(in: db))
        case .macPreferences, .toneProfile, .chatConversation:
            return record["payload"]
        }
    }

    func acknowledge(_ acks: [SendAck]) throws {
        try dbQueue.write { db in
            for ack in acks {
                try db.execute(sql: "UPDATE sync_record SET systemFields = ? WHERE recordName = ?", arguments: [ack.systemFields, ack.id.recordName])
                // Only the revision that was sent is done; a newer one stays.
                try db.execute(
                    sql: "DELETE FROM sync_outbox WHERE recordName = ? AND revCounter = ? AND revModifiedAtMs = ? AND revWriter = ?",
                    arguments: [ack.id.recordName, ack.revision.counter, SyncSchema.milliseconds(ack.revision.modifiedAt), ack.revision.writerDeviceID]
                )
            }
        }
    }

    func markSendFailed(_ id: SyncRecordID, reason: String) throws {
        try dbQueue.write { db in
            try db.execute(sql: "UPDATE sync_outbox SET failedReason = ? WHERE recordName = ?", arguments: [reason, id.recordName])
        }
    }

    // MARK: Receiving

    func applyInbound(
        _ records: [InboundRecord],
        decide: (LocalRecordState?, SyncEnvelope) -> InboundDecision
    ) throws -> InboundApplyResult {
        try dbQueue.write { db in
            var result = InboundApplyResult()
            for record in records {
                let envelope = record.envelope
                let local = try Row.fetchOne(db, sql: "SELECT revCounter, revModifiedAtMs, revWriter, isDeleted, generation, zoneName FROM sync_record WHERE recordName = ?", arguments: [envelope.id.recordName])
                let localState = local.map {
                    LocalRecordState(revision: Self.revision($0, counter: "revCounter", ms: "revModifiedAtMs", writer: "revWriter"), isDeleted: $0["isDeleted"], generation: $0["generation"])
                }
                try SyncLedger.observe(envelope.revision, in: db)

                // Mac settings merge key by key instead of record by record,
                // so settings changed on two Macs at once both survive.
                if envelope.kind == .macPreferences, try mergePreferences(record, in: db, into: &result) {
                    continue
                }

                switch decide(localState, envelope) {
                case .acceptRemote:
                    try applyContent(envelope, in: db)
                    try upsertSyncRecord(envelope, systemFields: record.systemFields, in: db)
                    try db.execute(sql: "DELETE FROM sync_outbox WHERE recordName = ?", arguments: [envelope.id.recordName])
                    result.changed.append(envelope.id)

                case .keepLocal:
                    // A dictation deleted here before its zone was known (a
                    // v1 deletion) moves its tombstone to where the record
                    // lives, so the deletion reaches that zone.
                    if let local, local["isDeleted"] as Bool, envelope.kind == .dictation, local["zoneName"] as String != envelope.id.zone.zoneName {
                        try db.execute(
                            sql: "UPDATE sync_record SET zoneName = ?, originDeviceID = ?, originKind = ? WHERE recordName = ?",
                            arguments: [envelope.id.zone.zoneName, envelope.origin?.deviceID, envelope.origin?.kind.rawValue, envelope.id.recordName]
                        )
                    }
                    try db.execute(sql: "UPDATE sync_record SET systemFields = COALESCE(?, systemFields) WHERE recordName = ?", arguments: [record.systemFields, envelope.id.recordName])
                    if let local {
                        try SyncLedger.enqueue(db, recordName: envelope.id.recordName, revision: Self.revision(local, counter: "revCounter", ms: "revModifiedAtMs", writer: "revWriter"))
                    }
                    result.needsSend.append(envelope.id)

                case .alreadyCurrent:
                    try db.execute(sql: "UPDATE sync_record SET systemFields = COALESCE(?, systemFields) WHERE recordName = ?", arguments: [record.systemFields, envelope.id.recordName])
                    try db.execute(
                        sql: "DELETE FROM sync_outbox WHERE recordName = ? AND revCounter = ? AND revModifiedAtMs = ? AND revWriter = ?",
                        arguments: [envelope.id.recordName, envelope.revision.counter, SyncSchema.milliseconds(envelope.revision.modifiedAt), envelope.revision.writerDeviceID]
                    )
                }
            }
            return result
        }
    }

    /// Returns false when the record isn't a readable settings payload, so
    /// the ordinary rule handles it.
    private func mergePreferences(_ record: InboundRecord, in db: Database, into result: inout InboundApplyResult) throws -> Bool {
        let envelope = record.envelope
        guard !envelope.isDeleted, let remoteData = envelope.payload,
              let remote = try? PayloadCoder.decode(MacPreferencesPayload.self, from: remoteData) else { return false }
        let localData = try Data.fetchOne(db, sql: "SELECT payload FROM sync_record WHERE recordName = ?", arguments: [envelope.id.recordName])
        let local = localData.flatMap { try? PayloadCoder.decode(MacPreferencesPayload.self, from: $0) }
        let merged = local.map { MacPreferencesPayload.merged($0, remote) } ?? remote

        if merged == remote {
            // iCloud already has everything this Mac has.
            try upsertSyncRecord(envelope, systemFields: record.systemFields, in: db)
            try db.execute(sql: "DELETE FROM sync_outbox WHERE recordName = ?", arguments: [envelope.id.recordName])
        } else {
            // This Mac has newer values for some keys: keep the merge, give it
            // a new revision and send it, carrying iCloud's change tag.
            let revision = try SyncLedger.nextRevision(db)
            var mergedEnvelope = envelope
            mergedEnvelope.revision = revision
            mergedEnvelope.payload = try PayloadCoder.encode(merged)
            try upsertSyncRecord(mergedEnvelope, systemFields: record.systemFields, in: db)
            try SyncLedger.enqueue(db, recordName: envelope.id.recordName, revision: revision)
            result.needsSend.append(envelope.id)
        }
        if merged != local { result.changed.append(envelope.id) }
        return true
    }

    private func upsertSyncRecord(_ envelope: SyncEnvelope, systemFields: Data?, in db: Database) throws {
        guard let kind = envelope.kind else { return }
        let keepsPayload: Bool
        switch kind {
        case .device, .macSummary, .macPreferences, .toneProfile, .chatConversation: keepsPayload = true
        default: keepsPayload = false
        }
        let localTable = Self.contentTable(for: kind)
        let localID: Int64? = envelope.isDeleted || localTable == nil ? nil : try contentRowID(for: envelope, in: db)
        try db.execute(
            sql: """
            INSERT INTO sync_record (recordName, zoneName, kind, localTable, localID, revCounter, revModifiedAtMs, revWriter, generation, isDeleted, deletedAt, originDeviceID, originKind, createdAt, systemFields, payload)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(recordName) DO UPDATE SET
                localTable = excluded.localTable, localID = excluded.localID,
                revCounter = excluded.revCounter, revModifiedAtMs = excluded.revModifiedAtMs, revWriter = excluded.revWriter,
                generation = excluded.generation,
                isDeleted = excluded.isDeleted, deletedAt = excluded.deletedAt,
                systemFields = COALESCE(excluded.systemFields, sync_record.systemFields), payload = excluded.payload,
                createdAt = COALESCE(sync_record.createdAt, excluded.createdAt)
            """,
            arguments: [
                envelope.id.recordName, envelope.id.zone.zoneName, kind.rawValue,
                envelope.isDeleted ? nil : localTable, localID,
                envelope.revision.counter, SyncSchema.milliseconds(envelope.revision.modifiedAt), envelope.revision.writerDeviceID,
                envelope.generation, envelope.isDeleted, envelope.deletedAt,
                envelope.origin?.deviceID, envelope.origin?.kind.rawValue, envelope.createdAt,
                systemFields, keepsPayload && !envelope.isDeleted ? envelope.payload : nil,
            ]
        )
    }

    static func contentTable(for kind: RecordKind) -> String? {
        switch kind {
        case .dictation: "transcription"
        case .dictionaryEntry: "dictionary_entry"
        case .snippet: "snippet_entry"
        case .learningSuggestion: "learning_suggestion"
        case .writingInsight: "writing_insight_snapshot"
        case .device, .macSummary, .macPreferences, .toneProfile, .chatConversation: nil
        }
    }

    private func contentRowID(for envelope: SyncEnvelope, in db: Database) throws -> Int64? {
        if let linked = try Int64.fetchOne(db, sql: "SELECT localID FROM sync_record WHERE recordName = ? AND localID IS NOT NULL", arguments: [envelope.id.recordName]) {
            return linked
        }
        guard let kind = envelope.kind, let table = Self.contentTable(for: kind) else { return nil }
        switch kind {
        case .dictionaryEntry:
            guard let payload = envelope.payload.flatMap({ try? PayloadCoder.decode(DictionaryEntryPayload.self, from: $0) }) else { return nil }
            return try Int64.fetchOne(db, sql: "SELECT id FROM dictionary_entry WHERE normalizedSource = ?", arguments: [payload.normalizedSource])
        case .snippet:
            guard let payload = envelope.payload.flatMap({ try? PayloadCoder.decode(SnippetPayload.self, from: $0) }) else { return nil }
            return try Int64.fetchOne(db, sql: "SELECT id FROM snippet_entry WHERE normalizedTrigger = ?", arguments: [payload.normalizedTrigger])
        default:
            return try Int64.fetchOne(db, sql: "SELECT id FROM \(table) WHERE syncID = ?", arguments: [envelope.id.localKey])
        }
    }

    /// Writes a remote version into its content table, never through the
    /// ledger (that would send it straight back).
    private func applyContent(_ envelope: SyncEnvelope, in db: Database) throws {
        guard let kind = envelope.kind else { return }
        let existingID = try contentRowID(for: envelope, in: db)

        if envelope.isDeleted {
            guard let existingID, let table = Self.contentTable(for: kind) else { return }
            if kind == .dictation {
                try DatabaseManager.deleteSemanticMemory(forTranscriptionID: existingID, in: db)
                try db.execute(sql: "DELETE FROM semantic_index_queue WHERE transcriptionID = ?", arguments: [existingID])
            }
            try db.execute(sql: "DELETE FROM \(table) WHERE id = ?", arguments: [existingID])
            return
        }
        guard let data = envelope.payload else { return }
        let now = Date()

        switch kind {
        case .dictation:
            let payload = try PayloadCoder.decode(DictationPayload.self, from: data)
            let origin = envelope.origin
            let arguments: StatementArguments = [
                payload.createdAt, payload.text, payload.targetAppName, payload.targetAppBundleID,
                payload.recordingMs ?? 0, payload.processingMs ?? payload.transcriptionMs ?? 0,
                payload.settingsSyncMs, payload.transcriptionMs, payload.textProcessingMs, payload.injectionMs,
                payload.appActivationMs, payload.clipboardRestoreDelayMs, payload.modelID ?? "",
                payload.audioDevice, payload.rawText == payload.text ? nil : payload.rawText,
                origin?.deviceID, origin?.kind.rawValue, payload.injectionMethod, payload.entryKind, payload.editInstruction,
                payload.timeZoneIdentifier,
            ]
            let id: Int64
            if let existingID {
                let previousText = try String.fetchOne(db, sql: "SELECT text FROM transcription WHERE id = ?", arguments: [existingID])
                try db.execute(sql: """
                    UPDATE transcription
                    SET createdAt = ?, text = ?, targetAppName = ?, targetAppBundleID = ?,
                        recordingDurationMs = ?, processingDurationMs = ?, settingsSyncDurationMs = ?,
                        transcriptionDurationMs = ?, textProcessingDurationMs = ?, injectionDurationMs = ?,
                        appActivationDurationMs = ?, clipboardRestoreDelayMs = ?, modelId = ?,
                        audioDevice = ?, rawText = ?, sourceDeviceID = ?, sourceDeviceKind = ?,
                        injectionMethod = ?, entryKind = ?, editInstruction = ?, timeZoneIdentifier = ?, modifiedAt = ?
                    WHERE id = ?
                    """, arguments: arguments + [now, existingID])
                id = existingID
                if previousText != payload.text {
                    // The words changed: everything derived from them is stale.
                    try DatabaseManager.deleteSemanticMemory(forTranscriptionID: id, in: db)
                }
            } else {
                try db.execute(sql: """
                    INSERT INTO transcription (
                        createdAt, text, targetAppName, targetAppBundleID, recordingDurationMs,
                        processingDurationMs, settingsSyncDurationMs, transcriptionDurationMs,
                        textProcessingDurationMs, injectionDurationMs, appActivationDurationMs,
                        clipboardRestoreDelayMs, modelId, audioDevice, rawText, sourceDeviceID, sourceDeviceKind,
                        injectionMethod, entryKind, editInstruction, timeZoneIdentifier, modifiedAt, syncID
                    )
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """, arguments: arguments + [now, envelope.id.localKey])
                id = db.lastInsertedRowID
            }
            try db.execute(
                sql: "INSERT INTO semantic_index_queue (transcriptionID, enqueuedAt) VALUES (?, ?) ON CONFLICT(transcriptionID) DO NOTHING",
                arguments: [id, now]
            )

        case .dictionaryEntry:
            let payload = try PayloadCoder.decode(DictionaryEntryPayload.self, from: data)
            if let existingID {
                try db.execute(sql: """
                    UPDATE dictionary_entry
                    SET source = ?, target = ?, normalizedSource = ?, isCaseSensitive = ?, isActive = ?, updatedAt = ?, modifiedAt = ?
                    WHERE id = ?
                    """, arguments: [payload.source, payload.target, payload.normalizedSource, payload.isCaseSensitive, payload.isActive, envelope.revision.modifiedAt, now, existingID])
            } else {
                // Another local row may hold this source (a rename racing a
                // remote add): fold into it rather than break the unique key.
                try db.execute(sql: """
                    INSERT INTO dictionary_entry (source, target, normalizedSource, isCaseSensitive, isActive, usageCount, createdAt, updatedAt, syncID, modifiedAt)
                    VALUES (?, ?, ?, ?, ?, 0, ?, ?, ?, ?)
                    ON CONFLICT(normalizedSource) DO UPDATE SET
                        source = excluded.source, target = excluded.target, isCaseSensitive = excluded.isCaseSensitive,
                        isActive = excluded.isActive, updatedAt = excluded.updatedAt, modifiedAt = excluded.modifiedAt
                    """, arguments: [payload.source, payload.target, payload.normalizedSource, payload.isCaseSensitive, payload.isActive, payload.createdAt, envelope.revision.modifiedAt, envelope.id.localKey, now])
            }

        case .snippet:
            let payload = try PayloadCoder.decode(SnippetPayload.self, from: data)
            if let existingID {
                try db.execute(sql: """
                    UPDATE snippet_entry
                    SET trigger = ?, expansion = ?, normalizedTrigger = ?, isActive = ?, updatedAt = ?, modifiedAt = ?
                    WHERE id = ?
                    """, arguments: [payload.trigger, payload.expansion, payload.normalizedTrigger, payload.isActive, envelope.revision.modifiedAt, now, existingID])
            } else {
                try db.execute(sql: """
                    INSERT INTO snippet_entry (trigger, expansion, normalizedTrigger, isActive, usageCount, createdAt, updatedAt, syncID, modifiedAt)
                    VALUES (?, ?, ?, ?, 0, ?, ?, ?, ?)
                    ON CONFLICT(normalizedTrigger) DO UPDATE SET
                        trigger = excluded.trigger, expansion = excluded.expansion, isActive = excluded.isActive,
                        updatedAt = excluded.updatedAt, modifiedAt = excluded.modifiedAt
                    """, arguments: [payload.trigger, payload.expansion, payload.normalizedTrigger, payload.isActive, payload.createdAt, envelope.revision.modifiedAt, envelope.id.localKey, now])
            }

        case .learningSuggestion:
            let payload = try PayloadCoder.decode(LearningSuggestionPayload.self, from: data)
            let values: StatementArguments = [payload.type, payload.candidateSource, payload.candidateTarget, payload.normalizedSource, payload.confidence, payload.status, payload.evidence, payload.createdAt, envelope.revision.modifiedAt, now]
            if let existingID {
                try db.execute(sql: """
                    UPDATE learning_suggestion
                    SET type = ?, candidateSource = ?, candidateTarget = ?, normalizedSource = ?, confidence = ?, status = ?, evidence = ?, createdAt = ?, updatedAt = ?, modifiedAt = ?
                    WHERE id = ?
                    """, arguments: values + [existingID])
            } else {
                try db.execute(sql: """
                    INSERT INTO learning_suggestion (type, candidateSource, candidateTarget, normalizedSource, confidence, status, evidence, createdAt, updatedAt, modifiedAt, syncID)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """, arguments: values + [envelope.id.localKey])
            }

        case .writingInsight:
            let payload = try PayloadCoder.decode(OrttaaiSyncCore.WritingInsightPayload.self, from: data)
            let values: StatementArguments = [payload.generatedAt, payload.analyzerName, payload.usedFallback, payload.isPinned, payload.sampleCount, payload.requestJSON, payload.snapshotJSON, now]
            if let existingID {
                try db.execute(sql: """
                    UPDATE writing_insight_snapshot
                    SET generatedAt = ?, analyzerName = ?, usedFallback = ?, isPinned = ?, sampleCount = ?, requestJSON = ?, snapshotJSON = ?, modifiedAt = ?
                    WHERE id = ?
                    """, arguments: values + [existingID])
            } else {
                try db.execute(sql: """
                    INSERT INTO writing_insight_snapshot (generatedAt, analyzerName, usedFallback, isPinned, sampleCount, requestJSON, snapshotJSON, modifiedAt, syncID)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """, arguments: values + [envelope.id.localKey])
            }

        case .device, .macSummary, .macPreferences, .toneProfile, .chatConversation:
            // Kept in sync_record's payload by upsertSyncRecord; the sync
            // service applies settings, tone and chats to this Mac.
            break
        }
    }

    // MARK: Older Orttaai versions

    /// Brings in records read from v1 (LegacySyncBridge). Unlike records from
    /// iCloud, they say nothing about what iCloud holds: a v1 record never
    /// retires a pending upload or touches CloudKit's system fields. One is
    /// adopted only when it's newer than this Mac's copy (or new here), and
    /// then queued to go on to the v2 archive.
    func importLegacy(_ envelopes: [SyncEnvelope]) throws -> [SyncRecordID] {
        try dbQueue.write { db in
            var adopted: [SyncRecordID] = []
            for envelope in envelopes {
                let local = try Row.fetchOne(db, sql: "SELECT revCounter, revModifiedAtMs, revWriter, isDeleted, generation FROM sync_record WHERE recordName = ?", arguments: [envelope.id.recordName])
                let localState = local.map {
                    LocalRecordState(revision: Self.revision($0, counter: "revCounter", ms: "revModifiedAtMs", writer: "revWriter"), isDeleted: $0["isDeleted"], generation: $0["generation"])
                }
                guard Self.legacyAdopts(local: localState, legacy: envelope) else { continue }
                try applyContent(envelope, in: db)
                try upsertSyncRecord(envelope, systemFields: nil, in: db)
                try SyncLedger.enqueue(db, recordName: envelope.id.recordName, revision: envelope.revision)
                adopted.append(envelope.id)
            }
            return adopted
        }
    }

    /// v1's own rule for v1 data: newest wins, a deletion wins a tie.
    /// Dictations keep their terminal deletion, and a record that started
    /// a new life under v2 is never touched by v1 data.
    static func legacyAdopts(local: LocalRecordState?, legacy: SyncEnvelope) -> Bool {
        guard let local else { return true }
        guard let kind = legacy.kind, local.generation == 0, local.revision.counter == 0 else { return false }
        if kind.deletionIsTerminal { return ConflictPolicy.decide(local: local, remote: legacy) == .acceptRemote }
        if legacy.isDeleted, !local.isDeleted { return legacy.revision.modifiedAt >= local.revision.modifiedAt }
        return legacy.revision.modifiedAt > local.revision.modifiedAt
    }

    /// Queues every record iCloud has never confirmed that isn't already
    /// waiting to be sent. Run as sync starts, so nothing is ever stranded.
    @discardableResult
    func enqueueUnconfirmed() throws -> Int {
        try dbQueue.write { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT r.recordName, r.revCounter, r.revModifiedAtMs, r.revWriter FROM sync_record r
                LEFT JOIN sync_outbox o ON o.recordName = r.recordName
                WHERE r.systemFields IS NULL AND o.recordName IS NULL
                """)
            for row in rows {
                try SyncLedger.enqueue(db, recordName: row["recordName"], revision: Self.revision(row, counter: "revCounter", ms: "revModifiedAtMs", writer: "revWriter"))
            }
            return rows.count
        }
    }

    func quarantine(_ records: [QuarantinedRecord]) throws {
        try dbQueue.write { db in
            for record in records {
                try db.execute(sql: """
                    INSERT INTO sync_quarantine (zoneName, recordName, recordType, problem, mayResolveAfterUpdate, archivedRecord, receivedAt)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    """, arguments: [record.zoneName, record.recordName, record.recordType, record.problem.description, record.problem.mayResolveAfterUpdate, record.archivedRecord, record.receivedAt])
            }
        }
    }

    func quarantinedForRetry() throws -> [(id: Int64, archivedRecord: Data)] {
        try dbQueue.read { db in
            try Row.fetchAll(db, sql: "SELECT id, archivedRecord FROM sync_quarantine WHERE mayResolveAfterUpdate = 1 AND archivedRecord IS NOT NULL")
                .map { ($0["id"], $0["archivedRecord"]) }
        }
    }

    func removeQuarantined(_ ids: [Int64]) throws {
        try dbQueue.write { db in
            for id in ids { try db.execute(sql: "DELETE FROM sync_quarantine WHERE id = ?", arguments: [id]) }
        }
    }

    // MARK: System fields and zones

    func clearSystemFields(for ids: [SyncRecordID]) throws {
        try dbQueue.write { db in
            for id in ids {
                try db.execute(sql: "UPDATE sync_record SET systemFields = NULL WHERE recordName = ?", arguments: [id.recordName])
            }
        }
    }

    func clearCloudMetadata(in zone: SyncZone) throws {
        try dbQueue.write { db in
            try db.execute(sql: "UPDATE sync_record SET systemFields = NULL WHERE zoneName = ?", arguments: [zone.zoneName])
        }
    }

    func enqueueAllRecords(in zone: SyncZone) throws -> [SyncRecordID] {
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO sync_outbox (recordName, revCounter, revModifiedAtMs, revWriter, failedReason, enqueuedAt)
                SELECT recordName, revCounter, revModifiedAtMs, revWriter, NULL, ? FROM sync_record WHERE zoneName = ?
                ON CONFLICT(recordName) DO UPDATE SET
                    revCounter = excluded.revCounter, revModifiedAtMs = excluded.revModifiedAtMs,
                    revWriter = excluded.revWriter, failedReason = NULL
                """, arguments: [Date(), zone.zoneName])
            return try String.fetchAll(db, sql: "SELECT recordName FROM sync_record WHERE zoneName = ?", arguments: [zone.zoneName])
                .map { SyncRecordID(zone: zone, recordName: $0) }
        }
    }

    func zoneStates() throws -> [SyncZone: ZoneState] {
        try dbQueue.read { db in
            var states: [SyncZone: ZoneState] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT zoneName, state FROM sync_zone") {
                guard let zone = SyncZone(zoneName: row["zoneName"]), let state = ZoneState(rawValue: row["state"]) else { continue }
                states[zone] = state
            }
            return states
        }
    }

    func setZoneState(_ state: ZoneState, for zone: SyncZone) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "INSERT INTO sync_zone (zoneName, state) VALUES (?, ?) ON CONFLICT(zoneName) DO UPDATE SET state = excluded.state",
                arguments: [zone.zoneName, state.rawValue]
            )
        }
    }

    // MARK: Engine state

    private func value(_ key: String) throws -> Data? {
        try dbQueue.read { db in try Data.fetchOne(db, sql: "SELECT value FROM sync_kv WHERE key = ?", arguments: [key]) }
    }

    private func setValue(_ value: Data?, for key: String) throws {
        try dbQueue.write { db in
            if let value {
                try db.execute(sql: "INSERT INTO sync_kv (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value", arguments: [key, value])
            } else {
                try db.execute(sql: "DELETE FROM sync_kv WHERE key = ?", arguments: [key])
            }
        }
    }

    func loadEngineState() throws -> Data? { try value("engineState") }
    func saveEngineState(_ data: Data?) throws { try setValue(data, for: "engineState") }

    func loadSuspension() throws -> SyncSuspension {
        guard let data = try value("suspension"), let raw = String(data: data, encoding: .utf8) else { return .none }
        return SyncSuspension(rawValue: raw) ?? .none
    }

    func saveSuspension(_ suspension: SyncSuspension) throws {
        try setValue(Data(suspension.rawValue.utf8), for: "suspension")
    }

    func initialFetchCompleted() throws -> Bool { try value("initialFetchCompleted") != nil }
    func setInitialFetchCompleted() throws { try setValue(Data("1".utf8), for: "initialFetchCompleted") }

    // MARK: Account

    /// The iCloud account this database's cloud metadata belongs to.
    func accountScope() throws -> String? {
        try value("accountScope").flatMap { String(data: $0, encoding: .utf8) }
    }

    func setAccountScope(_ scope: String) throws {
        try setValue(Data(scope.utf8), for: "accountScope")
    }

    /// The person chose to sync this Mac with a different iCloud account:
    /// forget everything the old account's iCloud told us and upload all of
    /// this Mac's records, tombstones included, as a first sync.
    func adoptAccount(_ scope: String) throws {
        try dbQueue.write { db in
            try db.execute(sql: "UPDATE sync_record SET systemFields = NULL")
            try db.execute(sql: "DELETE FROM sync_zone")
            try db.execute(sql: "DELETE FROM sync_kv WHERE key IN ('engineState', 'initialFetchCompleted', 'suspension')")
            try db.execute(sql: """
                INSERT INTO sync_outbox (recordName, revCounter, revModifiedAtMs, revWriter, failedReason, enqueuedAt)
                SELECT recordName, revCounter, revModifiedAtMs, revWriter, NULL, ? FROM sync_record
                WHERE kind NOT IN ('Device', 'MacSummary')
                ON CONFLICT(recordName) DO NOTHING
                """, arguments: [Date()])
            try db.execute(sql: "INSERT INTO sync_kv (key, value) VALUES ('accountScope', ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value", arguments: [Data(scope.utf8)])
        }
    }

    // MARK: Device and summary

    private func devicePayload(in db: Database) throws -> DevicePayload {
        let firstSeen = try Date.fetchOne(db, sql: "SELECT MIN(createdAt) FROM transcription WHERE sourceDeviceID = ?", arguments: [device.deviceID]) ?? Date()
        return DevicePayload(
            deviceID: device.deviceID,
            kind: .mac,
            name: device.name,
            model: device.model,
            app: "Orttaai",
            appVersion: device.appVersion,
            osVersion: device.osVersion,
            firstSeenAt: firstSeen,
            lastSeenAt: Date(),
            totals: try totals(in: db, sourceDeviceID: device.deviceID)
        )
    }

    private func totals(in db: Database, sourceDeviceID: String) throws -> DeviceTotals {
        var totals = DeviceTotals()
        let rows = try Row.fetchCursor(db, sql: """
            SELECT text, recordingDurationMs, createdAt FROM transcription
            WHERE sourceDeviceID = ? AND (entryKind IS NULL OR entryKind <> 'edit')
            """, arguments: [sourceDeviceID])
        while let row = try rows.next() {
            Self.add(row, to: &totals)
        }
        return totals
    }

    private static func add(_ row: Row, to totals: inout DeviceTotals) {
        let text: String = row["text"]
        let createdAt: Date = row["createdAt"]
        totals.dictations += 1
        totals.words += WordCount.of(text)
        totals.recordingMs += row["recordingDurationMs"] as Int? ?? 0
        totals.firstAt = min(totals.firstAt ?? createdAt, createdAt)
        totals.lastAt = max(totals.lastAt ?? createdAt, createdAt)
    }

    /// What this Mac knows about the whole archive, for the phone's stats.
    private func summaryPayload(in db: Database) throws -> MacSummaryPayload {
        var all = DeviceTotals()
        var perDevice: [String: DeviceTotals] = [:]
        var apps: [String: Int] = [:]
        var days: [String: DayCount] = [:]
        let calendar = Calendar.current
        let dayFormatter = DateFormatter()
        dayFormatter.locale = Locale(identifier: "en_US_POSIX")
        dayFormatter.calendar = calendar
        dayFormatter.timeZone = calendar.timeZone
        dayFormatter.dateFormat = "yyyy-MM-dd"
        let firstDay = calendar.date(byAdding: .day, value: -29, to: calendar.startOfDay(for: Date())) ?? Date()

        let rows = try Row.fetchCursor(db, sql: """
            SELECT text, recordingDurationMs, createdAt, sourceDeviceID, targetAppName FROM transcription
            WHERE entryKind IS NULL OR entryKind <> 'edit'
            """)
        while let row = try rows.next() {
            Self.add(row, to: &all)
            let device = row["sourceDeviceID"] as String? ?? "unknown"
            Self.add(row, to: &perDevice[device, default: DeviceTotals()])
            if let app = row["targetAppName"] as String?, !app.isEmpty { apps[app, default: 0] += 1 }
            let createdAt: Date = row["createdAt"]
            if createdAt >= firstDay {
                let day = dayFormatter.string(from: createdAt)
                var count = days[day] ?? DayCount(day: day, dictations: 0, words: 0)
                count.dictations += 1
                count.words += WordCount.of(row["text"])
                days[day] = count
            }
        }

        var coverage: [String: Int] = [:]
        for row in try Row.fetchAll(db, sql: "SELECT zoneName, COUNT(*) AS live FROM sync_record WHERE kind = 'Dictation' AND isDeleted = 0 GROUP BY zoneName") {
            coverage[row["zoneName"]] = row["live"]
        }

        var recentDays: [DayCount] = []
        for offset in 0..<30 {
            guard let date = calendar.date(byAdding: .day, value: offset, to: firstDay) else { continue }
            let day = dayFormatter.string(from: date)
            recentDays.append(days[day] ?? DayCount(day: day, dictations: 0, words: 0))
        }

        return MacSummaryPayload(
            publisherDeviceID: device.deviceID,
            publisherName: device.name,
            asOf: Date(),
            timeZoneIdentifier: calendar.timeZone.identifier,
            coverage: coverage,
            totals: all,
            perDevice: perDevice,
            recentDays: recentDays,
            topApps: apps.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }.prefix(5).map { AppCount(name: $0.key, dictations: $0.value) },
            coach: CoachDigest.latest
        )
    }

    // MARK: Helpers

    static func revision(_ row: Row, counter: String, ms: String, writer: String) -> Revision {
        Revision(counter: row[counter], modifiedAt: SyncSchema.date(milliseconds: row[ms]), writerDeviceID: row[writer])
    }

    static func dictationPayload(_ row: Row) -> DictationPayload {
        let text: String = row["text"]
        let modelID: String? = row["modelId"]
        return DictationPayload(
            createdAt: row["createdAt"],
            text: text,
            // NULL in rawText means "same as text" since v18 and "not
            // recorded" before; either way nothing better is known.
            rawText: row["rawText"],
            targetAppName: row["targetAppName"],
            targetAppBundleID: row["targetAppBundleID"],
            modelID: modelID?.isEmpty == true ? nil : modelID,
            recordingMs: row["recordingDurationMs"],
            processingMs: row["processingDurationMs"],
            transcriptionMs: row["transcriptionDurationMs"],
            textProcessingMs: row["textProcessingDurationMs"],
            injectionMs: row["injectionDurationMs"],
            settingsSyncMs: row["settingsSyncDurationMs"],
            appActivationMs: row["appActivationDurationMs"],
            clipboardRestoreDelayMs: row["clipboardRestoreDelayMs"],
            audioDevice: row["audioDevice"],
            injectionMethod: row["injectionMethod"],
            entryKind: row["entryKind"],
            editInstruction: row["editInstruction"],
            timeZoneIdentifier: row["timeZoneIdentifier"]
        )
    }
}
