// MacProfileSync.swift
// Orttaai
//
// Mac settings, the tone profile and chats, as sync records. v1 kept them in
// one profile record, so changing one setting could undo another Mac's
// change, and a long chat history could outgrow CloudKit's 1 MB limit. Now:
// settings are one record with a revision per key, the tone profile is its
// own record, and each chat conversation is its own record. Device-specific
// settings stay excluded, as before (CloudProfileSnapshot.syncedUserDefaultsKeys).

import Foundation
import GRDB
import OrttaaiSyncCore
import os

nonisolated enum MacProfileSync {
    static let toneKey = "toneOfVoiceProfile"
    static let chatsKey = "chatAIConversations"
    /// Conversations deleted on this Mac, waiting to become tombstones. Local
    /// to this Mac (never in the synced settings).
    static let deletedChatsKey = "chatAIDeletedConversationIDs"

    /// ChatAIView calls this when a conversation is deleted: a missing
    /// conversation is never taken as a deletion (the chat list is also
    /// trimmed to its newest 80), only this explicit one.
    static func noteChatDeleted(_ id: UUID, defaults: UserDefaults = .standard) {
        var pending = defaults.stringArray(forKey: deletedChatsKey) ?? []
        pending.append(id.uuidString.lowercased())
        defaults.set(pending, forKey: deletedChatsKey)
    }
    private static let logger = Logger(subsystem: "com.orttaai.sync", category: "profile")

    /// Settings that are plain preferences (tone and chats have records of
    /// their own).
    static var preferenceKeys: [String] {
        CloudProfileSnapshot.syncedUserDefaultsKeys.filter { $0 != toneKey && $0 != chatsKey }
    }

    // MARK: This Mac → records

    /// Records local settings, tone and chats that changed since they were
    /// last recorded. Returns the records that now need sending.
    @MainActor
    static func recordLocalChanges(dbQueue: DatabaseQueue, defaults: UserDefaults = .standard) throws -> [SyncRecordID] {
        let values = CloudProfileSnapshot.capturedValues(defaults: defaults)
        let tone = defaults.data(forKey: toneKey)
        let chats = chatPayloads(from: defaults.data(forKey: chatsKey))

        let pendingDeletions = defaults.stringArray(forKey: deletedChatsKey) ?? []
        let changed = try dbQueue.write { db in
            var changed: [SyncRecordID] = []

            // Settings: a new revision for each key whose value changed.
            let stored = try payload(MacPreferencesPayload.self, for: .macPreferences, in: db) ?? MacPreferencesPayload(entries: [:])
            var entries = stored.entries
            for key in preferenceKeys {
                let value = values[key].map(Self.preferenceValue)
                if entries[key]?.value != value, !(entries[key] == nil && value == nil) {
                    entries[key] = .init(value: value, revision: try SyncLedger.nextRevision(db))
                }
            }
            if entries != stored.entries {
                try SyncLedger.noteRecordChange(in: db, recordID: .macPreferences, payload: try PayloadCoder.encode(MacPreferencesPayload(entries: entries)))
                changed.append(.macPreferences)
            }

            // Tone profile. A missing local profile never deletes the shared
            // one (the v1 rule: preserve it when missing).
            if let tone {
                let storedTone = try payload(BlobPayload.self, for: .toneProfile, in: db)
                if storedTone?.data != tone {
                    try SyncLedger.noteRecordChange(in: db, recordID: .toneProfile, payload: try PayloadCoder.encode(BlobPayload(data: tone)))
                    changed.append(.toneProfile)
                }
            }

            // Chats: one record each. New and changed ones are recorded; only
            // conversations deleted on purpose become tombstones.
            let deleted = Set(defaults.stringArray(forKey: deletedChatsKey) ?? [])
            var storedByName: [String: Data] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT recordName, payload FROM sync_record WHERE kind = 'ChatConversation' AND isDeleted = 0") {
                storedByName[row["recordName"]] = row["payload"]
            }
            // A conversation deleted anywhere stays deleted: an ID is never
            // reused, so one still in this Mac's list is a stale copy.
            let tombstoned = Set(try String.fetchAll(db, sql: "SELECT recordName FROM sync_record WHERE kind = 'ChatConversation' AND isDeleted = 1"))
            for (conversationID, data) in chats where !deleted.contains(conversationID) {
                let id = SyncRecordID.chatConversation(conversationID)
                guard !tombstoned.contains(id.recordName) else { continue }
                let encoded = try PayloadCoder.encode(BlobPayload(data: data))
                if storedByName[id.recordName] != encoded {
                    try SyncLedger.noteRecordChange(in: db, recordID: id, payload: encoded)
                    changed.append(id)
                }
            }
            for conversationID in deleted {
                let id = SyncRecordID.chatConversation(conversationID)
                guard storedByName[id.recordName] != nil else { continue }
                try SyncLedger.noteRecordChange(in: db, recordID: id, payload: nil)
                changed.append(id)
            }
            return changed
        }
        // Only once they're recorded: a failed write keeps them pending.
        if !pendingDeletions.isEmpty {
            let remaining = (defaults.stringArray(forKey: deletedChatsKey) ?? []).filter { !pendingDeletions.contains($0) }
            defaults.set(remaining, forKey: deletedChatsKey)
        }
        return changed
    }

    // MARK: Records → this Mac

    /// Applies the synced settings, tone profile and chats to this Mac.
    @MainActor
    static func applyRemote(dbQueue: DatabaseQueue, defaults: UserDefaults = .standard) {
        do {
            let (preferences, tone, chats, hasChatRecords) = try dbQueue.read { db in
                (
                    try payload(MacPreferencesPayload.self, for: .macPreferences, in: db),
                    try payload(BlobPayload.self, for: .toneProfile, in: db),
                    try Row.fetchAll(db, sql: "SELECT payload FROM sync_record WHERE kind = 'ChatConversation' AND isDeleted = 0")
                        .compactMap { ($0["payload"] as Data?).flatMap { try? PayloadCoder.decode(BlobPayload.self, from: $0).data } },
                    try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM sync_record WHERE kind = 'ChatConversation')") ?? false
                )
            }
            let allowed = Set(preferenceKeys)
            CloudProfileChangeTracker.shared.performWithoutTracking {
                if let preferences {
                    for (key, entry) in preferences.entries where allowed.contains(key) {
                        if let value = entry.value {
                            defaults.set(objectValue(value), forKey: key)
                        } else {
                            defaults.removeObject(forKey: key)
                        }
                    }
                }
                if let tone { defaults.set(tone.data, forKey: toneKey) }
                // Every chat deleted: the list is empty, not left as it was.
                if let merged = mergedChats(chats) {
                    defaults.set(merged, forKey: chatsKey)
                } else if hasChatRecords {
                    defaults.set(Data("[]".utf8), forKey: chatsKey)
                }
            }
            // An open chat window reloads instead of saving over these.
            NotificationCenter.default.post(name: .syncedChatsDidChange, object: nil)
        } catch {
            logger.error("Applying synced settings failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: Helpers

    private static func payload<T: Decodable>(_ type: T.Type, for id: SyncRecordID, in db: Database) throws -> T? {
        guard let data = try Data.fetchOne(db, sql: "SELECT payload FROM sync_record WHERE recordName = ? AND isDeleted = 0", arguments: [id.recordName]) else { return nil }
        return try? PayloadCoder.decode(type, from: data)
    }

    static func preferenceValue(_ value: UserDefaultsSyncValue) -> PreferenceValue {
        switch value {
        case .string(let value): .string(value)
        case .bool(let value): .bool(value)
        case .int(let value): .int(value)
        case .double(let value): .double(value)
        case .data(let value): .data(value)
        }
    }

    static func objectValue(_ value: PreferenceValue) -> Any {
        switch value {
        case .string(let value): value
        case .bool(let value): value
        case .int(let value): value
        case .double(let value): value
        case .data(let value): value
        }
    }

    /// Each conversation as its own JSON object, keyed by its ID.
    static func chatPayloads(from data: Data?) -> [(String, Data)] {
        guard let data, let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return array.compactMap { conversation in
            guard let id = conversation["id"] as? String, let json = try? JSONSerialization.data(withJSONObject: conversation, options: [.sortedKeys]) else { return nil }
            return (id.lowercased(), json)
        }
    }

    /// The conversations back as the array ChatAIView reads, newest first,
    /// capped as ChatAIView caps them.
    static func mergedChats(_ conversations: [Data]) -> Data? {
        let objects = conversations.compactMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        guard !objects.isEmpty else { return nil }
        let sorted = objects.sorted { ($0["updatedAt"] as? Double ?? 0) > ($1["updatedAt"] as? Double ?? 0) }.prefix(80)
        return try? JSONSerialization.data(withJSONObject: Array(sorted))
    }
}

extension Notification.Name {
    /// Synced settings, tone or chats were applied to this Mac.
    static let syncedChatsDidChange = Notification.Name("Orttaai.syncedChatsDidChange")
}
