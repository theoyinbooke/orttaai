// ModelDirectoryLocator.swift
// Orttaai

import Foundation
import os

/// Every model build found across the model roots.
nonisolated struct ModelInventory: Sendable, Equatable {
    /// Exact build id (directory name) to its directory. The first root that
    /// holds a build wins.
    let directories: [String: URL]
    /// False when a root could not be read in time. A build missing from an
    /// incomplete inventory may still exist on the unreachable root.
    let isComplete: Bool

    /// Build ids with any quantization suffix removed, one entry per family build.
    var downloadedModelIDs: Set<String> {
        Set(directories.keys.map(ModelManager.normalizedModelID).filter { !$0.isEmpty })
    }
}

nonisolated enum ModelVariantLookup: Sendable, Equatable {
    case found(URL)
    /// Every root was read and none holds the build.
    case notFound
    /// The build was not found, but a root could not be read in time.
    case unavailable
}

/// The file-system work the locator performs, as closures so tests can
/// replace or count it. Every closure may block: the locator only ever runs
/// them off the calling thread and never waits for one longer than its timeout.
nonisolated struct ModelStorageProbes: Sendable {
    /// Directories that can hold model builds. Pure path computation plus
    /// resolving the user's chosen folder.
    var roots: @Sendable () -> [URL]
    /// Valid model builds found directly inside one root.
    var scanRoot: @Sendable (URL) -> [String: URL]
    var byteSize: @Sendable (URL) -> Int64
    var beginAccess: @Sendable (_ createIfNeeded: Bool, _ requiresWrite: Bool) throws -> ModelStorageAccess
    var snapshot: @Sendable () -> ModelStorageSnapshot

    static let live = ModelStorageProbes(
        roots: { ModelManager.modelStorageRoots() },
        scanRoot: { ModelManager.detectDownloadedVariantDirectories(in: [$0]) },
        byteSize: { ModelManager.directoryByteSize($0) },
        beginAccess: { createIfNeeded, requiresWrite in
            try ModelStorageLocation.beginAccess(createIfNeeded: createIfNeeded, requiresWrite: requiresWrite)
        },
        snapshot: { ModelStorageLocation.snapshot() }
    )
}

/// Finds downloaded speech models without ever blocking the caller on the file
/// system.
///
/// The model folders can sit behind a macOS folder-access prompt (Documents,
/// removable volumes) or on a drive that is unmounted or asleep, and a stat on
/// such a path can block indefinitely. Every probe therefore runs on a
/// dedicated dispatch queue and is raced against a timeout; a root that does
/// not answer in time is reported as unavailable while the others still
/// answer. A root that is hung is scanned once, not once per caller, and
/// results are cached briefly until the storage location changes.
actor ModelDirectoryLocator {
    static let shared = ModelDirectoryLocator()

    static let defaultProbeTimeout: TimeInterval = 3

    private struct CachedScan {
        let directories: [String: URL]
        let date: Date
    }

    private struct InFlightScan {
        let id: UUID
        let task: Task<[String: URL], Never>
    }

    private let probes: ModelStorageProbes
    private let probeTimeout: TimeInterval
    private let metricsTimeout: TimeInterval
    private let cacheLifetime: TimeInterval
    private let queue = DispatchQueue(
        label: "com.orttaai.model-probe",
        qos: .utility,
        attributes: .concurrent
    )
    private var scanCache: [String: CachedScan] = [:]
    private var inFlightScans: [String: InFlightScan] = [:]
    /// Bumped on every invalidation so a scan that started before it never
    /// writes its stale result into the cache.
    private var generation = 0

    /// Locators live for the whole app run, so the observer is never removed.
    init(
        probes: ModelStorageProbes = .live,
        probeTimeout: TimeInterval = ModelDirectoryLocator.defaultProbeTimeout,
        metricsTimeout: TimeInterval = 30,
        cacheLifetime: TimeInterval = 10,
        notificationCenter: NotificationCenter = .default
    ) {
        self.probes = probes
        self.probeTimeout = probeTimeout
        self.metricsTimeout = metricsTimeout
        self.cacheLifetime = cacheLifetime
        notificationCenter.addObserver(
            forName: ModelStorageLocation.didChangeNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            Task { await self?.invalidate() }
        }
    }

    /// Forgets cached scans. Call after anything that adds or removes models.
    func invalidate() {
        generation += 1
        scanCache.removeAll()
        inFlightScans.removeAll()
    }

    // MARK: - Inventory

    func inventory() async -> ModelInventory {
        let probes = self.probes
        guard let roots = await probe({ probes.roots() }) else {
            return ModelInventory(directories: [:], isComplete: false)
        }

        var results = [[String: URL]?](repeating: nil, count: roots.count)
        await withTaskGroup(of: (Int, [String: URL]?).self) { group in
            for (index, root) in roots.enumerated() {
                group.addTask { (index, await self.directories(in: root)) }
            }
            for await (index, directories) in group {
                results[index] = directories
            }
        }

        var merged: [String: URL] = [:]
        for directories in results {
            for (variantID, directory) in directories ?? [:] where merged[variantID] == nil {
                merged[variantID] = directory
            }
        }
        return ModelInventory(directories: merged, isComplete: !results.contains { $0 == nil })
    }

    func lookup(variantID: String) async -> ModelVariantLookup {
        let exactID = variantID.trimmingCharacters(in: .whitespacesAndNewlines)
        let inventory = await inventory()
        if let directory = inventory.directories[exactID] {
            return .found(directory)
        }
        return inventory.isComplete ? .notFound : .unavailable
    }

    /// The inventory with on-disk sizes. `isComplete` is false when a root, or
    /// the size walk itself, did not finish in time; sizes are then zero.
    func metrics() async -> (metrics: DownloadedModelMetrics, isComplete: Bool) {
        let inventory = await inventory()
        let byteSize = probes.byteSize
        let directories = inventory.directories
        if let measured = await probe(timeout: metricsTimeout, {
            ModelManager.metrics(forVariantDirectories: directories, byteSize: byteSize)
        }) {
            return (measured, inventory.isComplete)
        }
        return (ModelManager.metrics(forVariantDirectories: directories, byteSize: { _ in 0 }), false)
    }

    // MARK: - Storage location

    func storageSnapshot() async -> ModelStorageSnapshot {
        let snapshot = probes.snapshot
        if let result = await probe({ snapshot() }) {
            return result
        }
        let placeholder = ModelStorageLocation.placeholderSnapshot()
        return ModelStorageSnapshot(
            url: placeholder.url,
            isCustom: placeholder.isCustom,
            isAvailable: false,
            isWritable: false
        )
    }

    /// Starts access to the selected storage location. Throws
    /// `ModelLoadError.storageUnavailable` when it does not answer in time, and
    /// the underlying `ModelStorageLocationError` when it answers unusably.
    func beginAccess(createIfNeeded: Bool, requiresWrite: Bool) async throws -> ModelStorageAccess {
        let beginAccess = probes.beginAccess
        guard let outcome = await probe({
            Result { try beginAccess(createIfNeeded, requiresWrite) }
        }) else {
            throw ModelLoadError.storageUnavailable
        }
        return try outcome.get()
    }

    // MARK: - Removal

    /// Deletes every directory of one model family. Removal is not a probe and
    /// may legitimately take a while, so it has no timeout, but it still runs
    /// off the calling thread.
    func deleteFamily(canonicalID: String) async throws -> Bool {
        let roots = probes.roots
        let removed = try await perform {
            try ModelManager.deleteModelFamily(canonicalID: canonicalID, in: roots())
        }
        invalidate()
        return removed
    }

    func deleteVariant(named variantID: String) async throws {
        let roots = probes.roots
        try await perform {
            try ModelManager.deleteDownloadedVariant(named: variantID, in: roots())
        }
        invalidate()
    }

    // MARK: - Running blocking work

    /// Runs `work` off the calling thread and gives up after `timeout`,
    /// returning nil. The work keeps running on its own thread if it is stuck;
    /// nothing waits for it.
    func probe<T: Sendable>(
        timeout: TimeInterval? = nil,
        _ work: @escaping @Sendable () -> T
    ) async -> T? {
        let queue = self.queue
        return await Self.race(timeout: timeout ?? probeTimeout) {
            await Self.runBlocking(on: queue, work)
        }
    }

    private func perform<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        let queue = self.queue
        return try await Self.runBlocking(on: queue) { Result { try work() } }.get()
    }

    private func directories(in root: URL) async -> [String: URL]? {
        let key = root.path
        if let cached = scanCache[key], Date().timeIntervalSince(cached.date) < cacheLifetime {
            return cached.directories
        }
        let scan = inFlightScans[key] ?? startScan(of: root, key: key)
        return await Self.race(timeout: probeTimeout) { await scan.task.value }
    }

    private func startScan(of root: URL, key: String) -> InFlightScan {
        let scanRoot = probes.scanRoot
        let queue = self.queue
        let launchGeneration = generation
        let id = UUID()
        let task = Task {
            let directories = await Self.runBlocking(on: queue) { scanRoot(root) }
            self.finishScan(id: id, key: key, generation: launchGeneration, directories: directories)
            return directories
        }
        let scan = InFlightScan(id: id, task: task)
        inFlightScans[key] = scan
        return scan
    }

    private func finishScan(id: UUID, key: String, generation launchGeneration: Int, directories: [String: URL]) {
        if inFlightScans[key]?.id == id {
            inFlightScans[key] = nil
        }
        if launchGeneration == generation {
            scanCache[key] = CachedScan(directories: directories, date: Date())
        }
    }

    nonisolated private static func runBlocking<T: Sendable>(
        on queue: DispatchQueue,
        _ work: @escaping @Sendable () -> T
    ) async -> T {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: work()) }
        }
    }

    /// Returns the operation's result, or nil once `timeout` has passed. The
    /// operation is not cancelled: it may be waiting on a blocked thread.
    nonisolated private static func race<T: Sendable>(
        timeout: TimeInterval,
        _ operation: @escaping @Sendable () async -> T
    ) async -> T? {
        await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
            let gate = ResumeOnce(continuation)
            Task { gate.resume(await operation()) }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
                gate.resume(nil)
            }
        }
    }
}

/// Resumes a continuation exactly once, from whichever of two racing paths
/// finishes first.
private nonisolated final class ResumeOnce<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T?, Never>?

    init(_ continuation: CheckedContinuation<T?, Never>) {
        self.continuation = continuation
    }

    func resume(_ value: T?) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(returning: value)
    }
}
