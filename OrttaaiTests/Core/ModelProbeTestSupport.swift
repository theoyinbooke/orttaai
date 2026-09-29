// ModelProbeTestSupport.swift
// OrttaaiTests
//
// Fakes for the model-folder file-system seam. Nothing here reads the user's
// Documents folder, external drives or Application Support: every root is a
// temporary directory the test creates.

import XCTest
@testable import Orttaai

final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func increment() {
        lock.lock()
        value += 1
        lock.unlock()
    }
}

/// Blocks callers on a semaphore, standing in for a stat that hangs behind a
/// folder-access prompt or an asleep drive.
final class BlockingGate: @unchecked Sendable {
    private let semaphore = DispatchSemaphore(value: 0)

    func wait() {
        semaphore.wait()
    }

    /// Frees any number of blocked callers, so a test can always clean up.
    func openPermanently() {
        for _ in 0..<16 {
            semaphore.signal()
        }
    }
}

enum ModelProbeTestSupport {
    /// Probes that scan real temporary directories and count every file-system
    /// touch. `scanRoot` may be replaced to simulate a hung root.
    static func probes(
        roots: [URL],
        counters: ProbeCounters = ProbeCounters(),
        scanRoot: (@Sendable (URL) -> [String: URL])? = nil,
        beginAccessBase: URL? = nil
    ) -> ModelStorageProbes {
        ModelStorageProbes(
            roots: {
                counters.roots.increment()
                return roots
            },
            scanRoot: { root in
                counters.scanRoot.increment()
                return scanRoot?(root) ?? ModelManager.detectDownloadedVariantDirectories(in: [root])
            },
            byteSize: { directory in
                counters.byteSize.increment()
                return ModelManager.directoryByteSize(directory)
            },
            beginAccess: { _, _ in
                counters.beginAccess.increment()
                guard let beginAccessBase else {
                    throw ModelStorageLocationError.folderMissing("test")
                }
                return ModelStorageAccess(url: beginAccessBase, startsSecurityScope: false)
            },
            snapshot: {
                counters.snapshot.increment()
                return ModelStorageSnapshot(
                    url: roots.first ?? URL(fileURLWithPath: "/"),
                    isCustom: false,
                    isAvailable: true,
                    isWritable: true
                )
            }
        )
    }

    /// A locator that observes its own private notification center, never the
    /// app's, and answers within a fraction of a second.
    static func locator(
        probes: ModelStorageProbes,
        probeTimeout: TimeInterval = 0.3,
        cacheLifetime: TimeInterval = 60,
        notificationCenter: NotificationCenter = NotificationCenter()
    ) -> ModelDirectoryLocator {
        ModelDirectoryLocator(
            probes: probes,
            probeTimeout: probeTimeout,
            metricsTimeout: 5,
            cacheLifetime: cacheLifetime,
            notificationCenter: notificationCenter
        )
    }

    static func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("orttaai-model-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// Creates the three Core ML components `ModelManager` requires of a build.
    static func createFakeModel(at directory: URL) throws {
        let payload = Data(repeating: 0x1, count: 1_024)
        for component in ["MelSpectrogram", "AudioEncoder", "TextDecoder"] {
            let compiled = directory.appendingPathComponent("\(component).mlmodelc", isDirectory: true)
            try FileManager.default.createDirectory(at: compiled, withIntermediateDirectories: true)
            try payload.write(to: compiled.appendingPathComponent("weights.bin"))
        }
    }

    static func createFakeTokenizer(named repositoryName: String, under base: URL) throws {
        let folder = base.appendingPathComponent("models/\(repositoryName)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: folder.appendingPathComponent("tokenizer.json"))
    }

    /// The standard WhisperKit layout below a temporary base:
    /// `<base>/models/argmaxinc/whisperkit-coreml`.
    static func repositoryRoot(under base: URL) -> URL {
        base.appendingPathComponent("models/argmaxinc/whisperkit-coreml", isDirectory: true)
    }

    static func standardizedPath(_ url: URL) -> String {
        url.standardizedFileURL.path
    }
}

final class ProbeCounters: @unchecked Sendable {
    let roots = CallCounter()
    let scanRoot = CallCounter()
    let byteSize = CallCounter()
    let beginAccess = CallCounter()
    let snapshot = CallCounter()

    var total: Int {
        roots.count + scanRoot.count + byteSize.count + beginAccess.count + snapshot.count
    }
}
