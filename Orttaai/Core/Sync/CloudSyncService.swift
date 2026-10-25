// CloudSyncService.swift
// Orttaai
//
// What remains of sync v1: the container, the settings keys and the
// entitlement check. Sync itself is ArchiveSyncController (sync v2, shared
// with Orttakey); older versions' iCloud data is read by LegacySyncBridge.

import Foundation
import Security

nonisolated enum CloudSyncService {
    static let containerIdentifier = "iCloud.com.orttaai.Orttaai"
    static let syncEnabledKey = "cloudSyncEnabled"
    static let lastCompletedAtKey = "cloudSyncLastCompletedAt"
    /// The same preference DeviceIdentity uses: this Mac's identity.
    static let deviceIDKey = DeviceIdentity.defaultsKey

    enum ConfigurationError: LocalizedError {
        case missingCloudKitEntitlement

        var errorDescription: String? {
            "This build is not signed with Orttaai's iCloud container entitlement."
        }
    }

    static func ensureConfiguredForCloudKit() throws {
        guard entitlementValues(for: "com.apple.developer.icloud-services").contains("CloudKit"),
              entitlementValues(for: "com.apple.developer.icloud-container-identifiers").contains(containerIdentifier) else {
            throw ConfigurationError.missingCloudKitEntitlement
        }
    }

    private static func entitlementValues(for key: String) -> [String] {
        guard let task = SecTaskCreateFromSelf(nil),
              let rawValue = SecTaskCopyValueForEntitlement(task, key as CFString, nil) else {
            return []
        }
        if let values = rawValue as? [String] { return values }
        if let values = rawValue as? NSArray { return values.compactMap { $0 as? String } }
        return []
    }
}

nonisolated enum CloudSyncNotificationKey {
    static let completedAt = "completedAt"
}
