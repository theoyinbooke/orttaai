// CloudSyncScheduler.swift
// Orttaai

import Foundation
import os

enum CloudSyncTrigger: String, Sendable {
    case launch
    case localChange
    case profileChange
    case periodic
    case systemWake
    case coalesced
}

actor CloudSyncScheduler {
    nonisolated static let shared = CloudSyncScheduler()

    private let syncService: CloudSyncService
    private let periodicIntervalNanoseconds: UInt64
    private let defaultDebounceNanoseconds: UInt64

    private var periodicTask: Task<Void, Never>?
    private var debounceTask: Task<Void, Never>?
    private var isSyncRunning = false
    private var syncRequestedWhileRunning = false

    init(
        syncService: CloudSyncService = .shared,
        periodicInterval: TimeInterval = 120,
        defaultDebounce: TimeInterval = 4
    ) {
        self.syncService = syncService
        self.periodicIntervalNanoseconds = Self.nanoseconds(from: periodicInterval)
        self.defaultDebounceNanoseconds = Self.nanoseconds(from: defaultDebounce)
    }

    nonisolated static func startIfEnabled() {
        Task { await shared.startIfEnabled() }
    }

    nonisolated static func requestSync(reason: CloudSyncTrigger, debounce: TimeInterval? = nil) {
        Task { await shared.requestSync(reason: reason, debounce: debounce) }
    }

    nonisolated static func stop() {
        Task { await shared.stop() }
    }

    func startIfEnabled() {
        guard isSyncEnabled else { return }
        if periodicTask == nil {
            periodicTask = Task { [weak self] in
                await self?.runPeriodicLoop()
            }
        }
        requestSync(reason: .launch, debounce: 1)
    }

    func stop() {
        periodicTask?.cancel()
        periodicTask = nil
        debounceTask?.cancel()
        debounceTask = nil
        syncRequestedWhileRunning = false
    }

    func requestSync(reason: CloudSyncTrigger, debounce: TimeInterval? = nil) {
        guard isSyncEnabled else { return }
        let delay = debounce.map(Self.nanoseconds(from:)) ?? defaultDebounceNanoseconds
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            if delay > 0 {
                do {
                    try await Task.sleep(nanoseconds: delay)
                } catch {
                    return
                }
            }
            await self?.runSync(reason: reason)
        }
    }

    private func runPeriodicLoop() async {
        while !Task.isCancelled {
            do {
                try await Task.sleep(nanoseconds: periodicIntervalNanoseconds)
            } catch {
                return
            }
            await runSync(reason: .periodic)
        }
    }

    private func runSync(reason: CloudSyncTrigger) async {
        guard isSyncEnabled else { return }
        guard !isSyncRunning else {
            syncRequestedWhileRunning = true
            return
        }

        isSyncRunning = true
        do {
            try await syncService.syncNow()
            Logger.database.info("Cloud sync completed [trigger=\(reason.rawValue, privacy: .public)]")
        } catch {
            Logger.database.error("Cloud sync failed [trigger=\(reason.rawValue, privacy: .public)]: \(error.localizedDescription)")
        }
        isSyncRunning = false

        if syncRequestedWhileRunning {
            syncRequestedWhileRunning = false
            requestSync(reason: .coalesced, debounce: 2)
        }
    }

    private var isSyncEnabled: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil
            && UserDefaults.standard.bool(forKey: CloudSyncService.syncEnabledKey)
    }

    private static func nanoseconds(from seconds: TimeInterval) -> UInt64 {
        UInt64(max(0, seconds) * 1_000_000_000)
    }
}
