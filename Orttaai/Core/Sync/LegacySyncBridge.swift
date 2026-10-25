// LegacySyncBridge.swift
// Orttaai
//
// Reads what older Orttaai versions (1.14 and before) keep in iCloud's
// default zone, so a Mac that hasn't updated yet still reaches the new
// archive. Read-only: it never writes or deletes v1 records, so older Macs
// keep syncing among themselves. Imported records carry revision 0, older
// than any change made since, so replaying v1 data can never override a
// newer edit or bring back something deleted. Removed in a later release.

import CloudKit
import Foundation
import GRDB
import OrttaaiSyncCore
import os

nonisolated struct LegacyActivity: Equatable, Sendable {
    var deviceName: String
    var lastSeenAt: Date
}

nonisolated final class LegacySyncBridge: @unchecked Sendable {
    /// Imported v1 records sort below every v2 writer on a tie.
    static let legacyWriter = ""
    private static let lastScanKey = "legacyLastFullScanAt"
    private static let metadataTagKey = "legacyMetadataTag"
    private static let fullScanInterval: TimeInterval = 24 * 60 * 60

    private let database: CKDatabase
    private let dbQueue: DatabaseQueue
    private let store: MacSyncStore
    private let logger = Logger(subsystem: "com.orttaai.sync", category: "legacy")

    init(database: CKDatabase, dbQueue: DatabaseQueue, store: MacSyncStore) {
        self.database = database
        self.dbQueue = dbQueue
        self.store = store
    }

    /// Checks the v1 metadata record (one request) and scans everything when
    /// it changed, a day has passed, or `force` is set. Returns the records
    /// imported (to send on to v2) and what it saw of older Macs.
    func runIfNeeded(force: Bool = false, thisDeviceID: String) async throws -> (imported: [SyncRecordID], activity: LegacyActivity?) {
        let metadata = try await fetchMetadata()
        let tag = metadata?.recordChangeTag
        var activity: LegacyActivity?
        if let metadata, let source = metadata["sourceDeviceID"] as? String, source != thisDeviceID {
            activity = LegacyActivity(
                deviceName: metadata["sourceDeviceName"] as? String ?? "another Mac",
                lastSeenAt: metadata.modificationDate ?? metadata["modifiedAt"] as? Date ?? Date()
            )
        }

        let lastScan = try value(Self.lastScanKey).flatMap { Double(String(decoding: $0, as: UTF8.self)) }.map(Date.init(timeIntervalSince1970:))
        let seenTag = try value(Self.metadataTagKey).map { String(decoding: $0, as: UTF8.self) }
        let due = force || lastScan == nil || Date().timeIntervalSince(lastScan!) > Self.fullScanInterval || (tag != nil && tag != seenTag)
        guard due else { return ([], activity) }

        let imported = try await scan()
        // Only after a complete, successful import.
        try setValue(Data(String(Date().timeIntervalSince1970).utf8), for: Self.lastScanKey)
        if let tag { try setValue(Data(tag.utf8), for: Self.metadataTagKey) }
        logger.info("Legacy scan imported \(imported.count) records")
        return (imported, activity)
    }

    // MARK: Scanning

    private func scan() async throws -> [SyncRecordID] {
        var envelopes: [SyncEnvelope] = []
        var dictionaryNames: [String: String] = [:]
        var snippetNames: [String: String] = [:]

        for record in try await fetchAll(recordType: CloudSyncTable.transcription.recordType) {
            guard let payload = decode(CloudSyncTranscription.self, record) else { continue }
            let origin = payload.sourceDeviceID
            let zone = SyncRecordID.dictationZone(originDeviceID: origin)
            let dictation = DictationPayload(
                createdAt: payload.createdAt,
                text: payload.text,
                rawText: payload.rawText,
                targetAppName: payload.targetAppName,
                targetAppBundleID: payload.targetAppBundleID,
                modelID: payload.modelId.isEmpty ? nil : payload.modelId,
                recordingMs: payload.recordingDurationMs,
                processingMs: payload.processingDurationMs,
                transcriptionMs: payload.transcriptionDurationMs,
                textProcessingMs: payload.textProcessingDurationMs,
                injectionMs: payload.injectionDurationMs,
                settingsSyncMs: payload.settingsSyncDurationMs,
                appActivationMs: payload.appActivationDurationMs,
                clipboardRestoreDelayMs: payload.clipboardRestoreDelayMs,
                audioDevice: payload.audioDevice,
                injectionMethod: payload.injectionMethod,
                entryKind: payload.entryKind,
                editInstruction: payload.editInstruction
            )
            envelopes.append(SyncEnvelope(
                id: .dictation(syncID: payload.syncID, zone: zone),
                revision: legacyRevision(payload.modifiedAt),
                payload: try PayloadCoder.encode(dictation),
                origin: DictationOrigin(deviceID: zone == .legacyDictations ? nil : origin, kind: zone == .legacyDictations ? .unknown : .mac),
                createdAt: payload.createdAt
            ))
        }

        for record in try await fetchAll(recordType: CloudSyncTable.dictionaryEntry.recordType) {
            guard let payload = decode(CloudSyncDictionaryEntry.self, record) else { continue }
            var entry = DictionaryEntryPayload(source: payload.source, target: payload.target, isCaseSensitive: payload.isCaseSensitive, isActive: payload.isActive, createdAt: payload.createdAt)
            entry.normalizedSource = payload.normalizedSource
            let id = SyncRecordID.dictionaryEntry(normalizedSource: payload.normalizedSource)
            dictionaryNames[payload.syncID] = id.recordName
            envelopes.append(SyncEnvelope(id: id, revision: legacyRevision(payload.modifiedAt), payload: try PayloadCoder.encode(entry)))
        }

        for record in try await fetchAll(recordType: CloudSyncTable.snippetEntry.recordType) {
            guard let payload = decode(CloudSyncSnippetEntry.self, record) else { continue }
            var snippet = SnippetPayload(trigger: payload.trigger, expansion: payload.expansion, isActive: payload.isActive, createdAt: payload.createdAt)
            snippet.normalizedTrigger = payload.normalizedTrigger
            let id = SyncRecordID.snippet(normalizedTrigger: payload.normalizedTrigger)
            snippetNames[payload.syncID] = id.recordName
            envelopes.append(SyncEnvelope(id: id, revision: legacyRevision(payload.modifiedAt), payload: try PayloadCoder.encode(snippet)))
        }

        for record in try await fetchAll(recordType: CloudSyncTable.learningSuggestion.recordType) {
            guard let payload = decode(CloudSyncLearningSuggestion.self, record) else { continue }
            let suggestion = LearningSuggestionPayload(
                type: payload.type, candidateSource: payload.candidateSource, candidateTarget: payload.candidateTarget,
                normalizedSource: payload.normalizedSource, confidence: payload.confidence, status: payload.status,
                evidence: payload.evidence, createdAt: payload.createdAt
            )
            envelopes.append(SyncEnvelope(id: .learningSuggestion(syncID: payload.syncID), revision: legacyRevision(payload.modifiedAt), payload: try PayloadCoder.encode(suggestion)))
        }

        for record in try await fetchAll(recordType: CloudSyncTable.writingInsightSnapshot.recordType) {
            guard let payload = decode(CloudSyncWritingInsightSnapshot.self, record) else { continue }
            let insight = OrttaaiSyncCore.WritingInsightPayload(
                generatedAt: payload.generatedAt, analyzerName: payload.analyzerName, usedFallback: payload.usedFallback,
                isPinned: payload.isPinned, sampleCount: payload.sampleCount, requestJSON: payload.requestJSON, snapshotJSON: payload.snapshotJSON
            )
            envelopes.append(SyncEnvelope(id: .writingInsight(syncID: payload.syncID), revision: legacyRevision(payload.modifiedAt), payload: try PayloadCoder.encode(insight)))
        }

        // Deletions made on older Macs.
        let localNames = try localLegacyNames()
        for record in try await fetchAll(recordType: "OrttaaiDeletedRecord") {
            guard let tombstone = decode(CloudSyncTombstone.self, record) else { continue }
            let recordName: String?
            switch tombstone.table {
            case .transcription: recordName = "dictation.\(tombstone.syncID)"
            case .dictionaryEntry: recordName = dictionaryNames[tombstone.syncID] ?? localNames["dictionary_entry:\(tombstone.syncID)"]
            case .snippetEntry: recordName = snippetNames[tombstone.syncID] ?? localNames["snippet_entry:\(tombstone.syncID)"]
            case .learningSuggestion: recordName = "suggestion.\(tombstone.syncID)"
            case .writingInsightSnapshot: recordName = "insight.\(tombstone.syncID)"
            }
            guard let recordName, let zone = try zoneOfLocalRecord(recordName) else { continue }
            // Re-added in v1 after this deletion: the newer record stands.
            if envelopes.contains(where: { $0.id.recordName == recordName && !$0.isDeleted && $0.revision.modifiedAt > tombstone.deletedAt }) { continue }
            envelopes.removeAll { $0.id.recordName == recordName && $0.revision.modifiedAt <= tombstone.deletedAt }
            envelopes.append(SyncEnvelope(
                id: SyncRecordID(zone: zone, recordName: recordName),
                revision: legacyRevision(tombstone.deletedAt),
                isDeleted: true,
                deletedAt: tombstone.deletedAt,
                payload: nil,
                origin: tombstone.table == .transcription ? try originOfLocalDictation(recordName) : nil
            ))
        }

        // This Mac's own v1 deletions are barriers too.
        let barriers = try localTombstoneBarriers()
        envelopes.removeAll { envelope in
            guard !envelope.isDeleted, let deletedAt = barriers[envelope.id.recordName] else { return false }
            return deletedAt >= envelope.revision.modifiedAt
        }

        let valid = envelopes.filter { $0.problem == nil }
        guard !valid.isEmpty else { return [] }
        // Adopted records are queued for the v2 archive by the store.
        return try store.importLegacy(valid)
    }

    private func legacyRevision(_ date: Date) -> Revision {
        Revision(counter: 0, modifiedAt: SyncDate.rounded(date), writerDeviceID: Self.legacyWriter)
    }

    // MARK: Local lookups

    /// v1 syncIDs of this Mac's dictionary and snippet rows, to their records.
    private func localLegacyNames() throws -> [String: String] {
        try dbQueue.read { db in
            var names: [String: String] = [:]
            for row in try Row.fetchAll(db, sql: """
                SELECT 'dictionary_entry' AS t, d.syncID AS syncID, r.recordName AS name FROM dictionary_entry d JOIN sync_record r ON r.localTable = 'dictionary_entry' AND r.localID = d.id
                UNION ALL
                SELECT 'snippet_entry', s.syncID, r.recordName FROM snippet_entry s JOIN sync_record r ON r.localTable = 'snippet_entry' AND r.localID = s.id
                """) {
                if let syncID: String = row["syncID"] { names["\(row["t"] as String):\(syncID)"] = row["name"] }
            }
            return names
        }
    }

    private func zoneOfLocalRecord(_ recordName: String) throws -> SyncZone? {
        try dbQueue.read { db in
            try String.fetchOne(db, sql: "SELECT zoneName FROM sync_record WHERE recordName = ?", arguments: [recordName]).flatMap(SyncZone.init(zoneName:))
        }
    }

    private func originOfLocalDictation(_ recordName: String) throws -> DictationOrigin? {
        try dbQueue.read { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT originDeviceID, originKind FROM sync_record WHERE recordName = ?", arguments: [recordName]) else { return nil }
            return DictationOrigin(deviceID: row["originDeviceID"], kind: (row["originKind"] as String?).flatMap(DeviceKind.init(rawValue:)) ?? .unknown)
        }
    }

    private func localTombstoneBarriers() throws -> [String: Date] {
        try dbQueue.read { db in
            var barriers: [String: Date] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT tableName, syncID, deletedAt FROM cloud_sync_tombstone") {
                let syncID: String = row["syncID"]
                switch row["tableName"] as String {
                case "transcription": barriers["dictation.\(syncID)"] = row["deletedAt"]
                case "learning_suggestion": barriers["suggestion.\(syncID)"] = row["deletedAt"]
                case "writing_insight_snapshot": barriers["insight.\(syncID)"] = row["deletedAt"]
                default: break
                }
            }
            return barriers
        }
    }

    // MARK: CloudKit

    private func fetchMetadata() async throws -> CKRecord? {
        do {
            return try await database.record(for: CKRecord.ID(recordName: "metadata"))
        } catch let error as CKError where error.code == .unknownItem {
            return nil
        }
    }

    private func fetchAll(recordType: String) async throws -> [CKRecord] {
        let query = CKQuery(recordType: recordType, predicate: NSPredicate(value: true))
        var records: [CKRecord] = []
        do {
            var response = try await database.records(matching: query, resultsLimit: CKQueryOperation.maximumResults)
            records += response.matchResults.compactMap { try? $0.1.get() }
            while let cursor = response.queryCursor {
                response = try await database.records(continuingMatchFrom: cursor)
                records += response.matchResults.compactMap { try? $0.1.get() }
            }
        } catch let error as CKError where error.code == .unknownItem || error.code == .invalidArguments {
            // The type doesn't exist in this container: nothing to import.
            return []
        }
        return records
    }

    private func decode<T: Decodable>(_ type: T.Type, _ record: CKRecord) -> T? {
        guard let data = record["payloadData"] as? Data else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(type, from: data)
    }

    private func value(_ key: String) throws -> Data? {
        try dbQueue.read { db in try Data.fetchOne(db, sql: "SELECT value FROM sync_kv WHERE key = ?", arguments: [key]) }
    }

    private func setValue(_ value: Data, for key: String) throws {
        try dbQueue.write { db in
            try db.execute(sql: "INSERT INTO sync_kv (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value", arguments: [key, value])
        }
    }

    // MARK: v1 profile

    /// The v1 profile, when another Mac wrote one newer than this Mac's.
    func newerLegacyProfile(thanLocal localModifiedAt: Date?) async throws -> CloudProfileSnapshot? {
        let record: CKRecord
        do {
            record = try await database.record(for: CKRecord.ID(recordName: "profile"))
        } catch let error as CKError where error.code == .unknownItem {
            return nil
        }
        guard let snapshot = decode(CloudProfileSnapshot.self, record), let remoteDate = snapshot.modifiedAt else { return nil }
        if let localModifiedAt, localModifiedAt >= remoteDate { return nil }
        return snapshot
    }
}
