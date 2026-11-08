// MacLinkHost.swift
// Orttaai
//
// Orttaai Link's view of this Mac's archive: what linked devices send is
// saved like records from iCloud and queued for iCloud, and what changed is
// read back from the change feed.

import Foundation
import GRDB
import OrttaaiLink
import OrttaaiSyncCore

nonisolated final class MacLinkHost: LinkHost, @unchecked Sendable {
    private let store: MacSyncStore

    init(dbQueue: DatabaseQueue, device: SyncDeviceInfo) {
        store = MacSyncStore(dbQueue: dbQueue, device: device)
    }

    func existingRecordNames(_ names: [String]) async throws -> Set<String> {
        try store.existingRecordNames(names)
    }

    func apply(_ envelopes: [SyncEnvelope], from device: LinkedDevice) async throws -> LinkPushOutcome {
        let result = try store.applyFromLinkedDevice(envelopes)
        if !result.changed.isEmpty {
            let changed = result.changed
            await MainActor.run { ArchiveSyncController.shared.linkedDeviceChanged(changed) }
        }
        return LinkPushOutcome(accepted: result.accepted, newer: result.newer)
    }

    func changes(after cursor: Int64, limit: Int, for device: LinkedDevice) async throws -> LinkChangePage {
        let page = try store.linkChanges(after: cursor, limit: limit) { LinkRules.reads($0, device: device) }
        return LinkChangePage(records: page.records, cursor: page.cursor, more: page.more)
    }

    func iCloudStatus() async -> ICloudStatus {
        let (state, lastSentAt) = await MainActor.run { ArchiveSyncController.shared.linkICloudState }
        return ICloudStatus(state: ICloudStatus.State(rawValue: state) ?? .off, lastSentAt: lastSentAt)
    }

    func deviceTotals(_ ids: [String]) throws -> [String: DeviceTotals] {
        try store.deviceTotals(ids)
    }
}
