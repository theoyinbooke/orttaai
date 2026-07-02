// DeviceIdentity.swift
// Orttaai

import Foundation

/// Stable per-device identifier used to attribute records to the Mac that
/// produced them. Persisted in UserDefaults under the same key CloudSync has
/// always used to stamp CKRecords, so existing installs keep their identity.
enum DeviceIdentity {
    static let defaultsKey = "cloudSyncDeviceID"

    static var currentID: String {
        let defaults = UserDefaults.standard
        if let existing = defaults.string(forKey: defaultsKey), !existing.isEmpty {
            return existing
        }
        let id = UUID().uuidString.lowercased()
        defaults.set(id, forKey: defaultsKey)
        return id
    }
}
