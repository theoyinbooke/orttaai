// CloudSyncScheduler.swift
// Orttaai
//
// The app's hooks into sync (launch, local writes, settings changes, Home,
// wake), forwarded to ArchiveSyncController. CKSyncEngine schedules the
// actual fetches and sends; these only tell it something changed.

import Foundation

enum CloudSyncTrigger: String, Sendable {
    case launch
    case localChange
    case profileChange
    case homeReturn
    case periodic
    case systemWake
    case coalesced
}

enum CloudSyncScheduler {
    nonisolated static func startIfEnabled() {
        Task { @MainActor in await ArchiveSyncController.shared.startIfEnabled() }
    }

    nonisolated static func requestSync(reason: CloudSyncTrigger, debounce: TimeInterval? = nil) {
        Task { @MainActor in
            let controller = ArchiveSyncController.shared
            switch reason {
            case .localChange, .coalesced:
                controller.localDataChanged()
            case .profileChange:
                controller.localDataChanged(profileChanged: true)
            case .launch:
                await controller.startIfEnabled()
            case .homeReturn, .periodic, .systemWake:
                guard controller.phase == .running else { return }
                await controller.syncNow()
            }
        }
    }

    nonisolated static func stop() {}
}
