// ArchiveSyncController.swift
// Orttaai
//
// iCloud sync v2 on the Mac: one archive with Orttakey on iPhone and iPad,
// and with other Macs. Owns the CKSyncEngine host for the signed-in iCloud
// account, records settings changes, runs the bridge to older Orttaai
// versions, publishes this Mac's summary (the stats the phone shows), and
// keeps the Settings screen's status. The decisions themselves live in the
// OrttaaiSync package's SyncCoordinator.

import AppKit
import CloudKit
import Foundation
import GRDB
import Observation
import OrttaaiSyncCloudKit
import OrttaaiSyncCore
import os

@MainActor
@Observable
final class ArchiveSyncController {
    static let shared = ArchiveSyncController()

    enum Phase: Equatable {
        case off
        case starting
        case running
        /// Another iCloud account is signed in than the one this Mac's
        /// archive synced with: the person chooses.
        case needsAccountChoice
        case unavailable(String)
    }

    private(set) var phase: Phase = .off
    private(set) var status = SyncStatus()
    private(set) var devices: [DevicePayload] = []
    private(set) var legacyActivity: LegacyActivity?
    private(set) var pendingCount = 0
    private(set) var quarantinedCount = 0
    private(set) var lastError: String?

    @ObservationIgnored private var host: CloudSyncEngineHost?
    @ObservationIgnored private var store: MacSyncStore?
    @ObservationIgnored private var bridge: LegacySyncBridge?
    @ObservationIgnored private var pendingAccountScope: String?
    @ObservationIgnored private var localChangeTask: Task<Void, Never>?
    @ObservationIgnored private var summaryPublishedAt: Date?
    @ObservationIgnored private var periodicTask: Task<Void, Never>?
    @ObservationIgnored private let logger = Logger(subsystem: "com.orttaai.sync", category: "controller")

    private static let profileBaselineKey = "profileBaselineEstablished"
    private static let summaryInterval: TimeInterval = 10 * 60

    var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: CloudSyncService.syncEnabledKey)
    }

    private var isTesting: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    private static var environment: String {
        #if DEBUG
        "development"
        #else
        "production"
        #endif
    }

    // MARK: Turning on and off

    func startIfEnabled() async {
        guard isEnabled, !isTesting, host == nil, phase != .starting else { return }
        await start()
    }

    /// The person turned sync on.
    func enable() async {
        UserDefaults.standard.set(true, forKey: CloudSyncService.syncEnabledKey)
        await start()
    }

    /// The person turned sync off. Local data and pending changes stay, so
    /// turning it on again picks up where it left off.
    func disable() async {
        UserDefaults.standard.set(false, forKey: CloudSyncService.syncEnabledKey)
        await stopEngine()
        phase = .off
    }

    private func start() async {
        phase = .starting
        lastError = nil
        do {
            try CloudSyncService.ensureConfiguredForCloudKit()
            let container = CKContainer(identifier: CloudSyncService.containerIdentifier)
            switch try await container.accountStatus() {
            case .available: break
            case .noAccount:
                phase = .unavailable("Sign in to iCloud in System Settings to sync.")
                return
            case .restricted:
                phase = .unavailable("iCloud is restricted for this account.")
                return
            default:
                phase = .unavailable("iCloud isn't available right now.")
                return
            }

            let scope = try await CloudSyncEngineHost.accountScope(container: container, environment: Self.environment)
            let database = try DatabaseManager()
            let store = MacSyncStore(dbQueue: database.dbQueue, device: Self.deviceInfo())
            if let known = try store.accountScope() {
                guard known == scope else {
                    pendingAccountScope = scope
                    phase = .needsAccountChoice
                    return
                }
            } else {
                try store.setAccountScope(scope)
            }

            let coordinator = SyncCoordinator(store: store, platform: .mac, deviceID: DeviceIdentity.currentID, observer: self)
            let host = CloudSyncEngineHost(container: container, coordinator: coordinator, diagnostics: { message in
                Logger(subsystem: "com.orttaai.sync", category: "engine").info("\(message, privacy: .public)")
            })
            let requeued = try store.enqueueUnconfirmed()
            if requeued > 0 { logger.notice("Queued \(requeued) records iCloud hadn't confirmed") }
            if UserDefaults.standard.bool(forKey: Self.profileBaselineKey) {
                // The stored copy holds every change: apply it, in case the
                // app stopped between saving one and applying it.
                MacProfileSync.applyRemote(dbQueue: database.dbQueue)
            }
            self.store = store
            self.host = host
            self.bridge = LegacySyncBridge(database: container.privateCloudDatabase, dbQueue: database.dbQueue, store: store)
            try await host.start()
            // The account is the one this archive syncs with (checked
            // above): a sign-in held for that check can go ahead.
            try await host.perform { try await $0.confirmAccount() }
            phase = await host.isRunning ? .running : .off
            status = await coordinator.currentStatus
            NSApplication.shared.registerForRemoteNotifications()

            try publishDevice()
            localDataChanged()
            refreshDetails()
            startPeriodicChecks()
        } catch {
            logger.error("Starting sync failed: \(error.localizedDescription, privacy: .public)")
            lastError = error.localizedDescription
            phase = .unavailable(error.localizedDescription)
        }
    }

    private func stopEngine() async {
        periodicTask?.cancel()
        periodicTask = nil
        localChangeTask?.cancel()
        await host?.stop()
        host = nil
        bridge = nil
    }

    // MARK: Account choice

    /// Sync this Mac's archive with the iCloud account now signed in: a first
    /// sync that uploads everything this Mac has.
    func useCurrentAccount() async {
        guard let scope = pendingAccountScope else { return }
        do {
            let database = try DatabaseManager()
            try MacSyncStore(dbQueue: database.dbQueue, device: Self.deviceInfo()).adoptAccount(scope)
            UserDefaults.standard.set(false, forKey: Self.profileBaselineKey)
            pendingAccountScope = nil
            await stopEngine()
            await start()
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Signed in again while running: the same account resumes; another one
    /// waits for the person's choice.
    private func checkAccountAfterSignIn() async {
        do {
            let container = CKContainer(identifier: CloudSyncService.containerIdentifier)
            let scope = try await CloudSyncEngineHost.accountScope(container: container, environment: Self.environment)
            if scope == (try store?.accountScope()) {
                try await host?.perform { try await $0.confirmAccount() }
            } else {
                await accountSwitched()
            }
        } catch {
            logger.error("Checking the iCloud account failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// iCloud signed in as someone else while sync ran: stop, and ask.
    private func accountSwitched() async {
        await stopEngine()
        do {
            let container = CKContainer(identifier: CloudSyncService.containerIdentifier)
            pendingAccountScope = try await CloudSyncEngineHost.accountScope(container: container, environment: Self.environment)
            phase = .needsAccountChoice
        } catch {
            phase = .unavailable("Sign in to iCloud in System Settings to sync.")
        }
    }

    /// Keep this Mac's archive apart from the new account: sync stays off.
    func keepArchiveSeparate() async {
        pendingAccountScope = nil
        await disable()
    }

    // MARK: Changes

    /// Called after every local write (DatabaseManager) and settings change.
    /// Settings changes are recorded at once, sync running or not, so the
    /// shared copy always holds this Mac's latest before anything incoming
    /// is applied over it.
    func localDataChanged(profileChanged: Bool = false) {
        if profileChanged, UserDefaults.standard.bool(forKey: Self.profileBaselineKey) {
            do {
                _ = try MacProfileSync.recordLocalChanges(dbQueue: try DatabaseManager().dbQueue)
            } catch {
                logger.error("Recording settings failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        guard host != nil else { return }
        localChangeTask?.cancel()
        localChangeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            await self?.sendLocalChanges(profileChanged: profileChanged)
        }
    }

    private func sendLocalChanges(profileChanged: Bool) async {
        guard let host, let store else { return }
        do {
            let ids = try store.outboxEntries().map(\.id)
            await host.noteLocalChanges(ids)
            pendingCount = ids.count
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// - Parameter includingOlderMacs: also scan what older Orttaai
    ///   versions keep in iCloud (the Sync Now button; a full scan is too
    ///   heavy for every return to Home).
    func syncNow(includingOlderMacs: Bool = false) async {
        guard let host else {
            await startIfEnabled()
            return
        }
        do {
            try await host.syncNow()
            if includingOlderMacs { await runLegacyBridge(force: true) }
        } catch {
            lastError = error.localizedDescription
        }
    }

    func resumeAfterStorageFreed() async {
        try? await host?.perform { try await $0.resumeAfterQuota() }
    }

    /// "Restore your iCloud copy" after it went missing or was deleted.
    func restoreICloudCopy() async {
        do {
            if host == nil { await start() }
            try await host?.perform { try await $0.restoreAll() }
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: After fetches

    private func fetchFinished() async {
        await runLegacyBridge(force: false)
        await establishProfileBaselineIfNeeded()
        publishSummaryIfDue()
        refreshDetails()
    }

    /// The first time this Mac syncs, settings already in iCloud (from v2, or
    /// a newer v1 profile) win over this Mac's, as v1's "Use iCloud profile"
    /// did; after that, each change is recorded as it happens.
    private func establishProfileBaselineIfNeeded() async {
        guard !UserDefaults.standard.bool(forKey: Self.profileBaselineKey) else { return }
        do {
            let dbQueue = try DatabaseManager().dbQueue
            let hasShared = try await dbQueue.read { db in
                try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM sync_record WHERE recordName = ? AND isDeleted = 0 AND systemFields IS NOT NULL)", arguments: [SyncRecordID.macPreferences.recordName]) ?? false
            }
            if hasShared {
                MacProfileSync.applyRemote(dbQueue: dbQueue)
            } else if let bridge {
                let localDate = UserDefaults.standard.double(forKey: CloudProfileSnapshot.modifiedAtKey)
                if let legacy = try await bridge.newerLegacyProfile(thanLocal: localDate > 0 ? Date(timeIntervalSince1970: localDate) : nil) {
                    legacy.apply()
                }
            }
            UserDefaults.standard.set(true, forKey: Self.profileBaselineKey)
            _ = try MacProfileSync.recordLocalChanges(dbQueue: dbQueue)
            localDataChanged()
        } catch {
            logger.error("Settings baseline failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func runLegacyBridge(force: Bool) async {
        guard let bridge else { return }
        do {
            let result = try await bridge.runIfNeeded(force: force, thisDeviceID: DeviceIdentity.currentID)
            legacyActivity = result.activity
            if !result.imported.isEmpty {
                remoteChangesApplied(result.imported)
                localDataChanged()
            }
        } catch {
            logger.error("Legacy bridge failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// The phone shows this Mac's summary; it's recomputed when sent.
    private func publishSummaryIfDue(force: Bool = false) {
        if !force, let summaryPublishedAt, Date().timeIntervalSince(summaryPublishedAt) < Self.summaryInterval { return }
        do {
            try DatabaseManager().dbQueue.write { db in
                try SyncLedger.noteRecordChange(in: db, recordID: .macSummary(macDeviceID: DeviceIdentity.currentID), payload: Data("{}".utf8))
            }
            summaryPublishedAt = Date()
            localDataChanged()
        } catch {
            logger.error("Queuing the summary failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func publishDevice() throws {
        try DatabaseManager().dbQueue.write { db in
            try SyncLedger.noteRecordChange(in: db, recordID: .device(DeviceIdentity.currentID), payload: Data("{}".utf8))
        }
    }

    private func startPeriodicChecks() {
        periodicTask?.cancel()
        periodicTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15 * 60))
                guard !Task.isCancelled, let self else { return }
                await self.runLegacyBridge(force: false)
                try? self.publishDevice()
                self.publishSummaryIfDue()
            }
        }
    }

    // MARK: Remote changes

    private func remoteChangesApplied(_ ids: [SyncRecordID]) {
        let kinds = Set(ids.compactMap(\.kind))
        if !kinds.isDisjoint(with: [.macPreferences, .toneProfile, .chatConversation]), let dbQueue = try? DatabaseManager().dbQueue {
            MacProfileSync.applyRemote(dbQueue: dbQueue)
        }
        if !kinds.isDisjoint(with: [.dictionaryEntry, .snippet, .learningSuggestion]) {
            NotificationCenter.default.post(name: .personalMemoryDidChange, object: nil)
        }
        if kinds.contains(.dictation) || kinds.contains(.writingInsight) {
            // Home, milestones and analytics refresh on this, and the
            // semantic index picks up the queued dictations.
            NotificationCenter.default.post(name: .cloudSyncDidComplete, object: self, userInfo: [CloudSyncNotificationKey.completedAt: Date()])
        }
        if kinds.contains(.device) { refreshDetails() }
    }

    private func refreshDetails() {
        guard let store else { return }
        do {
            let dbQueue = try DatabaseManager().dbQueue
            let (devices, quarantined) = try dbQueue.read { db -> ([DevicePayload], Int) in
                let devices = try Row.fetchAll(db, sql: "SELECT payload FROM sync_record WHERE kind = 'Device' AND isDeleted = 0 AND systemFields IS NOT NULL")
                    .compactMap { ($0["payload"] as Data?).flatMap { try? PayloadCoder.decode(DevicePayload.self, from: $0) } }
                let quarantined = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sync_quarantine") ?? 0
                return (devices, quarantined)
            }
            self.devices = devices.sorted { $0.lastSeenAt > $1.lastSeenAt }
            self.quarantinedCount = quarantined
            self.pendingCount = try store.outboxEntries().count
        } catch {
            logger.error("Reading sync details failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: Device

    private static func deviceInfo() -> SyncDeviceInfo {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var model = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("hw.model", &model, &size, nil, 0)
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return SyncDeviceInfo(
            deviceID: DeviceIdentity.currentID,
            name: Host.current().localizedName ?? "Mac",
            model: String(cString: model),
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
            osVersion: "macOS \(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
        )
    }
}

extension ArchiveSyncController: SyncCoordinatorObserver {
    nonisolated func syncDidApplyRemoteChanges(_ ids: [SyncRecordID]) {
        Task { @MainActor in self.remoteChangesApplied(ids) }
    }

    nonisolated func syncStatusDidChange(_ status: SyncStatus) {
        Task { @MainActor in
            self.status = status
            if status.suspension == .accountChanged, self.phase != .needsAccountChoice {
                await self.accountSwitched()
            } else if status.suspension == .awaitingAccountCheck {
                await self.checkAccountAfterSignIn()
            }
        }
    }

    nonisolated func syncDidFinishFetch() {
        Task { @MainActor in await self.fetchFinished() }
    }
}
