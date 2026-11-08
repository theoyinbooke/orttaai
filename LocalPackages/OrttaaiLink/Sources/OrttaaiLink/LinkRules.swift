// LinkRules.swift
// OrttaaiLink
//
// What a linked device may read and write (docs/orttaai-link-protocol.md §1).
// Which version of a record wins is not decided here: that is the same
// conflict policy as iCloud's, applied by the Mac's sync store.

import Foundation
import OrttaaiSyncCore

public enum LinkRules {
    /// Whether the device receives this record in its changes. Mac settings
    /// and the tone profile are one Mac's own and stay there.
    public static func reads(_ id: SyncRecordID, device: LinkedDevice) -> Bool {
        guard let kind = id.kind, id.isWellFormed else { return false }
        switch kind {
        case .macPreferences, .toneProfile: return false
        default: return id.zone.isFetched(by: device.syncPlatform, deviceID: device.id)
        }
    }

    /// Why the device may not send this record, or nil when it may.
    /// - Parameter exists: whether the Mac already holds a record by this
    ///   name; a device may change another device's dictation, never start one.
    public static func refusal(_ envelope: SyncEnvelope, from device: LinkedDevice, exists: Bool) -> String? {
        if let problem = envelope.problem { return problem.description }
        guard let kind = envelope.kind else { return "unknown record type" }
        guard envelope.revision.writerDeviceID == device.id else { return "written by another device" }
        let isMac = device.syncPlatform == .mac

        switch kind {
        case .macSummary, .macPreferences, .toneProfile:
            return "only a Mac writes this"
        case .device:
            guard envelope.id == .device(device.id) else { return "another device's record" }
            if let payload = envelope.payload {
                guard let info = try? PayloadCoder.decode(DevicePayload.self, from: payload),
                      info.deviceID == device.id, info.kind == device.kind else { return "device record doesn't match this device" }
            }
            return nil
        case .dictionaryEntry:
            return nil
        case .snippet, .learningSuggestion, .writingInsight, .chatConversation:
            return isMac ? nil : "phones don't sync this"
        case .dictation:
            if envelope.id.zone == device.dictationZone {
                guard envelope.origin?.deviceID == device.id, envelope.origin?.kind == device.kind else {
                    return "dictation origin doesn't match this device"
                }
                return nil
            }
            guard isMac else { return "phones send only their own dictations" }
            return exists ? nil : "a new dictation must be this device's own"
        }
    }
}
