// CloudSyncService.swift
// Orttaai

import CloudKit
import Foundation
import os
import Security

enum CloudSyncSetupResolution: String, Codable, Sendable {
    case merge
    case useICloud
}

struct CloudSyncSetupPreview: Sendable, Equatable {
    let localStats: CloudSyncStats
    let iCloudStats: CloudSyncStats
    let hasConflict: Bool
}

enum CloudSyncStatus: Equatable {
    case idle
    case checking
    case needsSetup(CloudSyncSetupPreview)
    case syncing
    case synced(Date)
    case failed(String)
}

enum CloudSyncServiceError: LocalizedError {
    case missingCloudKitEntitlement
    case iCloudUnavailable
    case iCloudRestricted
    case noAccount
    case couldNotDecodeRecord(String)
    case emptyMergeWouldEraseData

    var errorDescription: String? {
        switch self {
        case .missingCloudKitEntitlement:
            return "This build is not signed with Orttaai's iCloud container entitlement."
        case .iCloudUnavailable:
            return "iCloud is not available on this Mac."
        case .iCloudRestricted:
            return "iCloud access is restricted for this account."
        case .noAccount:
            return "Sign in to iCloud in System Settings before enabling sync."
        case .couldNotDecodeRecord(let recordName):
            return "Could not read iCloud sync record \(recordName)."
        case .emptyMergeWouldEraseData:
            return "Sync stopped because the merge result was empty while existing data was detected."
        }
    }
}

final class CloudSyncService {
    nonisolated static let shared = CloudSyncService()

    nonisolated static let containerIdentifier = "iCloud.com.orttaai.Orttaai"
    nonisolated static let syncEnabledKey = "cloudSyncEnabled"
    nonisolated static let lastCompletedAtKey = "cloudSyncLastCompletedAt"
    nonisolated static let deviceIDKey = "cloudSyncDeviceID"

    private let containerProvider: () -> CKContainer
    private let requiresEntitlementCheck: Bool
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(container: CKContainer? = nil) {
        let providedContainer = container
        self.containerProvider = {
            providedContainer ?? CKContainer(identifier: CloudSyncService.containerIdentifier)
        }
        self.requiresEntitlementCheck = providedContainer == nil

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    func setupPreview() async throws -> CloudSyncSetupPreview {
        try await ensureAccountAvailable()

        let local = try localFullSnapshot()
        let remote = try await fetchRemoteFullSnapshot()
        return CloudSyncSetupPreview(
            localStats: local.stats,
            iCloudStats: remote.stats,
            hasConflict: local.stats.hasUserData && remote.stats.hasUserData
        )
    }

    func enableSync(resolution: CloudSyncSetupResolution) async throws -> CloudSyncSetupPreview {
        let preview = try await setupPreview()
        let local = try localFullSnapshot()
        let remote = try await fetchRemoteFullSnapshot()

        switch resolution {
        case .merge:
            let mergedDatabase = Self.mergedDatabaseSnapshot(local: local.database, remote: remote.database)
            try Self.validateMergeResult(mergedDatabase, local: local.database, remote: remote.database)
            _ = try DatabaseManager.backupDefaultDatabase(reason: "icloud-merge")
            try DatabaseManager().applyCloudSnapshot(mergedDatabase, replacingLocalData: true)

            let profile = Self.newerProfile(local.profile, remote.profile) ?? local.profile
            profile.apply()
            try await pushLocalSnapshot()

        case .useICloud:
            _ = try DatabaseManager.backupDefaultDatabase(reason: "icloud-profile-replace")
            try DatabaseManager().applyCloudSnapshot(remote.database, replacingLocalData: true)
            remote.profile.apply()
            try await pushLocalSnapshot()
        }

        UserDefaults.standard.set(true, forKey: Self.syncEnabledKey)
        let completedAt = Date()
        try DatabaseManager().markCloudSyncCompleted(at: completedAt)
        markUserDefaultsSyncCompleted(at: completedAt)
        postSyncCompleted(at: completedAt)
        return preview
    }

    func syncIfEnabled() async {
        guard UserDefaults.standard.bool(forKey: Self.syncEnabledKey) else { return }
        do {
            try await syncNow()
        } catch {
            Logger.database.error("Cloud sync failed: \(error.localizedDescription)")
        }
    }

    func syncNow() async throws {
        try await ensureAccountAvailable()
        let local = try localFullSnapshot()
        let remote = try await fetchRemoteFullSnapshot()

        let mergedDatabase = Self.mergedDatabaseSnapshot(local: local.database, remote: remote.database)
        try Self.validateMergeResult(mergedDatabase, local: local.database, remote: remote.database)

        let profile = Self.newerProfile(local.profile, remote.profile) ?? local.profile
        let localDatabaseNeedsUpdate = !Self.databaseContentMatches(local.database, mergedDatabase)
        let remoteDatabaseNeedsUpdate = !Self.databaseContentMatches(remote.database, mergedDatabase)
        let localProfileNeedsUpdate = profile != local.profile
        let remoteProfileNeedsUpdate = profile != remote.profile
        let databaseManager = try DatabaseManager()

        if localDatabaseNeedsUpdate {
            _ = try DatabaseManager.backupDefaultDatabase(reason: "icloud-sync")
            try databaseManager.applyCloudSnapshot(mergedDatabase, replacingLocalData: true)
        }

        if localProfileNeedsUpdate {
            profile.apply()
        }

        if remoteDatabaseNeedsUpdate || remoteProfileNeedsUpdate {
            try await pushLocalSnapshot()
        }

        let completedAt = Date()
        try databaseManager.markCloudSyncCompleted(at: completedAt)
        UserDefaults.standard.set(true, forKey: Self.syncEnabledKey)
        markUserDefaultsSyncCompleted(at: completedAt)
        postSyncCompleted(at: completedAt)

        Logger.database.info(
            "Cloud sync resolved changes [localDatabaseUpdated=\(localDatabaseNeedsUpdate), remoteDatabaseUpdated=\(remoteDatabaseNeedsUpdate), localProfileUpdated=\(localProfileNeedsUpdate), remoteProfileUpdated=\(remoteProfileNeedsUpdate)]"
        )
    }

    private func localFullSnapshot() throws -> CloudFullSnapshot {
        let database = try DatabaseManager().cloudSyncSnapshot()
        let profile = CloudProfileSnapshot.capture()
        return CloudFullSnapshot(database: database, profile: profile, capturedAt: Date())
    }

    private func pushLocalSnapshot() async throws {
        let snapshot = try localFullSnapshot()
        var records: [CKRecord] = []

        records += try snapshot.database.transcriptions.map {
            try makeRecord(type: CloudSyncTable.transcription.recordType, syncID: $0.syncID, modifiedAt: $0.modifiedAt, payload: $0)
        }
        records += try snapshot.database.dictionaryEntries.map {
            try makeRecord(type: CloudSyncTable.dictionaryEntry.recordType, syncID: $0.syncID, modifiedAt: $0.modifiedAt, payload: $0)
        }
        records += try snapshot.database.snippetEntries.map {
            try makeRecord(type: CloudSyncTable.snippetEntry.recordType, syncID: $0.syncID, modifiedAt: $0.modifiedAt, payload: $0)
        }
        records += try snapshot.database.learningSuggestions.map {
            try makeRecord(type: CloudSyncTable.learningSuggestion.recordType, syncID: $0.syncID, modifiedAt: $0.modifiedAt, payload: $0)
        }
        records += try snapshot.database.writingInsightSnapshots.map {
            try makeRecord(type: CloudSyncTable.writingInsightSnapshot.recordType, syncID: $0.syncID, modifiedAt: $0.modifiedAt, payload: $0)
        }
        records += try snapshot.database.tombstones.map {
            try makeRecord(type: "OrttaaiDeletedRecord", syncID: $0.id, modifiedAt: $0.deletedAt, payload: $0)
        }
        records.append(try makeProfileRecord(snapshot.profile))
        records.append(try makeMetadataRecord(stats: snapshot.stats))

        let database = try privateDatabase()
        for batch in records.chunked(maxSize: 200) {
            _ = try await database.modifyRecords(
                saving: batch,
                deleting: [],
                savePolicy: .allKeys,
                atomically: false
            )
        }
    }

    private func fetchRemoteFullSnapshot() async throws -> CloudFullSnapshot {
        var database = CloudDatabaseSnapshot()

        database.transcriptions = try await fetchPayloads(
            recordType: CloudSyncTable.transcription.recordType,
            as: CloudSyncTranscription.self
        )
        database.dictionaryEntries = try await fetchPayloads(
            recordType: CloudSyncTable.dictionaryEntry.recordType,
            as: CloudSyncDictionaryEntry.self
        )
        database.snippetEntries = try await fetchPayloads(
            recordType: CloudSyncTable.snippetEntry.recordType,
            as: CloudSyncSnippetEntry.self
        )
        database.learningSuggestions = try await fetchPayloads(
            recordType: CloudSyncTable.learningSuggestion.recordType,
            as: CloudSyncLearningSuggestion.self
        )
        database.writingInsightSnapshots = try await fetchPayloads(
            recordType: CloudSyncTable.writingInsightSnapshot.recordType,
            as: CloudSyncWritingInsightSnapshot.self
        )
        database.tombstones = try await fetchPayloads(
            recordType: "OrttaaiDeletedRecord",
            as: CloudSyncTombstone.self
        )

        let profile = try await fetchRemoteProfile() ?? CloudProfileSnapshot(values: [:], modifiedAt: nil)
        return CloudFullSnapshot(database: database, profile: profile, capturedAt: Date())
    }

    private func fetchRemoteProfile() async throws -> CloudProfileSnapshot? {
        let recordID = CKRecord.ID(recordName: "profile")
        do {
            let record = try await privateDatabase().record(for: recordID)
            return try decodePayload(from: record, as: CloudProfileSnapshot.self)
        } catch let error as CKError where error.code == .unknownItem {
            return nil
        }
    }

    private func fetchPayloads<T: Decodable>(recordType: String, as type: T.Type) async throws -> [T] {
        let records = try await fetchRecords(recordType: recordType)
        return try records.map { record in
            try decodePayload(from: record, as: type)
        }
    }

    private func fetchRecords(recordType: String) async throws -> [CKRecord] {
        let query = CKQuery(recordType: recordType, predicate: NSPredicate(value: true))
        var records: [CKRecord] = []
        let database = try privateDatabase()

        var response = try await database.records(
            matching: query,
            resultsLimit: CKQueryOperation.maximumResults
        )
        try appendRecords(from: response.matchResults, to: &records)

        while let cursor = response.queryCursor {
            response = try await database.records(continuingMatchFrom: cursor)
            try appendRecords(from: response.matchResults, to: &records)
        }

        return records
    }

    private func appendRecords(
        from results: [(CKRecord.ID, Result<CKRecord, any Error>)],
        to records: inout [CKRecord]
    ) throws {
        for (_, result) in results {
            records.append(try result.get())
        }
    }

    private func makeRecord<T: Encodable>(
        type: String,
        syncID: String,
        modifiedAt: Date,
        payload: T
    ) throws -> CKRecord {
        let record = CKRecord(
            recordType: type,
            recordID: CKRecord.ID(recordName: recordName(type: type, syncID: syncID))
        )
        record["syncID"] = syncID as NSString
        record["modifiedAt"] = modifiedAt as NSDate
        record["payloadData"] = try encoder.encode(payload) as NSData
        record["schemaVersion"] = 1 as NSNumber
        record["sourceDeviceID"] = deviceID() as NSString
        record["sourceDeviceName"] = (Host.current().localizedName ?? "Mac") as NSString
        return record
    }

    private func makeProfileRecord(_ profile: CloudProfileSnapshot) throws -> CKRecord {
        let record = CKRecord(
            recordType: "OrttaaiProfile",
            recordID: CKRecord.ID(recordName: "profile")
        )
        record["syncID"] = "profile" as NSString
        record["modifiedAt"] = (profile.modifiedAt ?? Date()) as NSDate
        record["payloadData"] = try encoder.encode(profile) as NSData
        record["schemaVersion"] = 1 as NSNumber
        record["sourceDeviceID"] = deviceID() as NSString
        return record
    }

    private func makeMetadataRecord(stats: CloudSyncStats) throws -> CKRecord {
        let record = CKRecord(
            recordType: "OrttaaiSyncMetadata",
            recordID: CKRecord.ID(recordName: "metadata")
        )
        record["syncID"] = "metadata" as NSString
        record["modifiedAt"] = Date() as NSDate
        record["payloadData"] = try encoder.encode(stats) as NSData
        record["schemaVersion"] = 1 as NSNumber
        record["sourceDeviceID"] = deviceID() as NSString
        return record
    }

    private func decodePayload<T: Decodable>(from record: CKRecord, as type: T.Type) throws -> T {
        guard let data = record["payloadData"] as? Data else {
            throw CloudSyncServiceError.couldNotDecodeRecord(record.recordID.recordName)
        }
        return try decoder.decode(type, from: data)
    }

    private func recordName(type: String, syncID: String) -> String {
        "\(type)-\(syncID)"
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: "/", with: "-")
    }

    private func deviceID() -> String {
        DeviceIdentity.currentID
    }

    private func markUserDefaultsSyncCompleted(at date: Date) {
        UserDefaults.standard.set(date.timeIntervalSince1970, forKey: Self.lastCompletedAtKey)
    }

    private func postSyncCompleted(at date: Date) {
        NotificationCenter.default.post(
            name: .cloudSyncDidComplete,
            object: self,
            userInfo: [CloudSyncNotificationKey.completedAt: date]
        )
    }

    private func ensureAccountAvailable() async throws {
        let status = try await cloudContainer().accountStatus()
        switch status {
        case .available:
            return
        case .couldNotDetermine:
            throw CloudSyncServiceError.iCloudUnavailable
        case .restricted:
            throw CloudSyncServiceError.iCloudRestricted
        case .noAccount:
            throw CloudSyncServiceError.noAccount
        case .temporarilyUnavailable:
            throw CloudSyncServiceError.iCloudUnavailable
        @unknown default:
            throw CloudSyncServiceError.iCloudUnavailable
        }
    }

    private func cloudContainer() throws -> CKContainer {
        if requiresEntitlementCheck {
            try Self.ensureConfiguredForCloudKit()
        }
        return containerProvider()
    }

    private func privateDatabase() throws -> CKDatabase {
        try cloudContainer().privateCloudDatabase
    }

    private static func ensureConfiguredForCloudKit() throws {
        guard hasRequiredCloudKitEntitlements() else {
            throw CloudSyncServiceError.missingCloudKitEntitlement
        }
    }

    private static func hasRequiredCloudKitEntitlements() -> Bool {
        entitlementValues(for: "com.apple.developer.icloud-services").contains("CloudKit")
            && entitlementValues(for: "com.apple.developer.icloud-container-identifiers").contains(containerIdentifier)
    }

    private static func entitlementValues(for key: String) -> [String] {
        guard
            let task = SecTaskCreateFromSelf(nil),
            let rawValue = SecTaskCopyValueForEntitlement(task, key as CFString, nil)
        else {
            return []
        }

        if let values = rawValue as? [String] {
            return values
        }
        if let values = rawValue as? NSArray {
            return values.compactMap { $0 as? String }
        }
        return []
    }

    private static func newerProfile(
        _ local: CloudProfileSnapshot,
        _ remote: CloudProfileSnapshot
    ) -> CloudProfileSnapshot? {
        switch (local.modifiedAt, remote.modifiedAt) {
        case (.some(let localDate), .some(let remoteDate)):
            return localDate >= remoteDate ? local : remote
        case (.some, .none):
            return local
        case (.none, .some):
            return remote
        case (.none, .none):
            return local.values.isEmpty ? remote : local
        }
    }

    private static func mergedDatabaseSnapshot(
        local: CloudDatabaseSnapshot,
        remote: CloudDatabaseSnapshot
    ) -> CloudDatabaseSnapshot {
        var merged = CloudDatabaseSnapshot()
        merged.transcriptions = mergeRows(local.transcriptions, remote.transcriptions, id: \.syncID, date: \.modifiedAt)
        merged.dictionaryEntries = mergeRows(local.dictionaryEntries, remote.dictionaryEntries, id: \.syncID, date: \.modifiedAt)
        merged.snippetEntries = mergeRows(local.snippetEntries, remote.snippetEntries, id: \.syncID, date: \.modifiedAt)
        merged.learningSuggestions = mergeRows(local.learningSuggestions, remote.learningSuggestions, id: \.syncID, date: \.modifiedAt)
        merged.writingInsightSnapshots = mergeRows(local.writingInsightSnapshots, remote.writingInsightSnapshots, id: \.syncID, date: \.modifiedAt)
        merged.tombstones = mergeRows(local.tombstones, remote.tombstones, id: \.id, date: \.deletedAt)

        merged.transcriptions.removeAll { isDeleted(table: .transcription, syncID: $0.syncID, tombstones: merged.tombstones, modifiedAt: $0.modifiedAt) }
        merged.dictionaryEntries.removeAll { isDeleted(table: .dictionaryEntry, syncID: $0.syncID, tombstones: merged.tombstones, modifiedAt: $0.modifiedAt) }
        merged.snippetEntries.removeAll { isDeleted(table: .snippetEntry, syncID: $0.syncID, tombstones: merged.tombstones, modifiedAt: $0.modifiedAt) }
        merged.learningSuggestions.removeAll { isDeleted(table: .learningSuggestion, syncID: $0.syncID, tombstones: merged.tombstones, modifiedAt: $0.modifiedAt) }
        merged.writingInsightSnapshots.removeAll {
            isDeleted(table: .writingInsightSnapshot, syncID: $0.syncID, tombstones: merged.tombstones, modifiedAt: $0.modifiedAt)
        }
        return merged
    }

    private static func mergeRows<T>(
        _ local: [T],
        _ remote: [T],
        id: KeyPath<T, String>,
        date: KeyPath<T, Date>
    ) -> [T] {
        var merged: [String: T] = [:]
        for row in local + remote {
            let key = row[keyPath: id]
            if let existing = merged[key] {
                if row[keyPath: date] > existing[keyPath: date] {
                    merged[key] = row
                }
            } else {
                merged[key] = row
            }
        }
        return Array(merged.values)
    }

    private static func validateMergeResult(
        _ merged: CloudDatabaseSnapshot,
        local: CloudDatabaseSnapshot,
        remote: CloudDatabaseSnapshot
    ) throws {
        if merged.stats.databaseItemCount == 0
            && (local.stats.databaseItemCount > 0 || remote.stats.databaseItemCount > 0) {
            throw CloudSyncServiceError.emptyMergeWouldEraseData
        }
    }

    private static func isDeleted(
        table: CloudSyncTable,
        syncID: String,
        tombstones: [CloudSyncTombstone],
        modifiedAt: Date
    ) -> Bool {
        tombstones.contains { tombstone in
            tombstone.table == table
                && tombstone.syncID == syncID
                && tombstone.deletedAt >= modifiedAt
        }
    }

    private static func databaseContentMatches(
        _ lhs: CloudDatabaseSnapshot,
        _ rhs: CloudDatabaseSnapshot
    ) -> Bool {
        normalizedTranscriptions(lhs.transcriptions) == normalizedTranscriptions(rhs.transcriptions)
            && normalizedDictionaryEntries(lhs.dictionaryEntries) == normalizedDictionaryEntries(rhs.dictionaryEntries)
            && normalizedSnippetEntries(lhs.snippetEntries) == normalizedSnippetEntries(rhs.snippetEntries)
            && normalizedLearningSuggestions(lhs.learningSuggestions) == normalizedLearningSuggestions(rhs.learningSuggestions)
            && normalizedWritingInsightSnapshots(lhs.writingInsightSnapshots) == normalizedWritingInsightSnapshots(rhs.writingInsightSnapshots)
            && lhs.tombstones.sorted { $0.id < $1.id } == rhs.tombstones.sorted { $0.id < $1.id }
    }

    private static func normalizedTranscriptions(_ rows: [CloudSyncTranscription]) -> [CloudSyncTranscription] {
        rows.map { row in
            var normalized = row
            normalized.localID = nil
            return normalized
        }
        .sorted { $0.syncID < $1.syncID }
    }

    private static func normalizedDictionaryEntries(_ rows: [CloudSyncDictionaryEntry]) -> [CloudSyncDictionaryEntry] {
        rows.map { row in
            var normalized = row
            normalized.localID = nil
            return normalized
        }
        .sorted { $0.syncID < $1.syncID }
    }

    private static func normalizedSnippetEntries(_ rows: [CloudSyncSnippetEntry]) -> [CloudSyncSnippetEntry] {
        rows.map { row in
            var normalized = row
            normalized.localID = nil
            return normalized
        }
        .sorted { $0.syncID < $1.syncID }
    }

    private static func normalizedLearningSuggestions(_ rows: [CloudSyncLearningSuggestion]) -> [CloudSyncLearningSuggestion] {
        rows.map { row in
            var normalized = row
            normalized.localID = nil
            return normalized
        }
        .sorted { $0.syncID < $1.syncID }
    }

    private static func normalizedWritingInsightSnapshots(
        _ rows: [CloudSyncWritingInsightSnapshot]
    ) -> [CloudSyncWritingInsightSnapshot] {
        rows.map { row in
            var normalized = row
            normalized.localID = nil
            return normalized
        }
        .sorted { $0.syncID < $1.syncID }
    }
}

enum CloudSyncNotificationKey {
    static let completedAt = "completedAt"
}

private extension Array {
    func chunked(maxSize: Int) -> [[Element]] {
        guard maxSize > 0, !isEmpty else { return [] }
        var chunks: [[Element]] = []
        var index = startIndex
        while index < endIndex {
            let nextIndex = self.index(index, offsetBy: maxSize, limitedBy: endIndex) ?? endIndex
            chunks.append(Array(self[index..<nextIndex]))
            index = nextIndex
        }
        return chunks
    }
}
