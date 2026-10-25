// TranscriptionRecord.swift
// Orttaai

import Foundation
import GRDB

struct Transcription: Codable, Identifiable, FetchableRecord, PersistableRecord {
    var id: Int64?
    var createdAt: Date
    var text: String
    var targetAppName: String?
    var targetAppBundleID: String?
    var recordingDurationMs: Int
    var processingDurationMs: Int
    var settingsSyncDurationMs: Int?
    var transcriptionDurationMs: Int?
    var textProcessingDurationMs: Int?
    var injectionDurationMs: Int?
    var appActivationDurationMs: Int?
    var clipboardRestoreDelayMs: Int?
    var modelId: String
    var audioDevice: String?
    // What the speech model heard before dictionary, polish and formatting;
    // NULL when it matches `text` and on rows from before it was kept.
    var rawText: String? = nil
    // NULL on rows created before device tagging or synced from older app
    // versions; readers treat NULL as belonging to this device.
    var sourceDeviceID: String?
    // How the text landed in the target app ("paste", "ax", "typed",
    // "failed"). NULL on rows written before verified injection shipped.
    var injectionMethod: String?
    // "edit" for voice edit commands; NULL means a plain dictation (rows
    // written before edit commands shipped included).
    var entryKind: String?
    // The spoken instruction that produced an edit entry; NULL on dictations.
    var editInstruction: String?
    // mac, iphone, ipad or unknown: the kind of device it was said on. NULL
    // only on rows written before sync v2's migration filled it in.
    var sourceDeviceKind: String? = nil
    // Where it was said (an IANA identifier). NULL on rows from before v21
    // and from devices that don't send it.
    var timeZoneIdentifier: String? = nil

    static let databaseTableName = "transcription"

    /// entryKind value for voice edit command rows.
    static let editEntryKind = "edit"

    var isEditCommand: Bool {
        entryKind == Self.editEntryKind
    }

    /// Said on Orttakey on an iPhone or iPad.
    var isFromMobile: Bool {
        sourceDeviceKind == "iphone" || sourceDeviceKind == "ipad"
    }

    /// The app it went into, or where it came from when that isn't known:
    /// iOS never tells a keyboard which app it's typing in.
    var displayAppName: String? {
        if let name = targetAppName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty { return name }
        switch sourceDeviceKind {
        case "iphone": return "Orttakey on iPhone"
        case "ipad": return "Orttakey on iPad"
        default: return nil
        }
    }

    /// What the speech model heard, when it was kept and differs from the
    /// text. NULL never means "the same" for old rows, so nothing is shown.
    var distinctRawText: String? {
        guard let rawText, rawText != text, !rawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return rawText
    }
}

extension Transcription {
    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
