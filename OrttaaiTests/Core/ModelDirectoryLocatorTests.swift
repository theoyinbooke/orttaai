// ModelDirectoryLocatorTests.swift
// OrttaaiTests

import XCTest
@testable import Orttaai

final class ModelDirectoryLocatorTests: XCTestCase {
    private var temporaryDirectories: [URL] = []

    override func tearDown() {
        for directory in temporaryDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        temporaryDirectories = []
        super.tearDown()
    }

    private func makeRoot(withModels modelIDs: [String]) throws -> URL {
        let root = try ModelProbeTestSupport.makeTemporaryDirectory()
        temporaryDirectories.append(root)
        for modelID in modelIDs {
            try ModelProbeTestSupport.createFakeModel(at: root.appendingPathComponent(modelID, isDirectory: true))
        }
        return root
    }

    func testInventoryMergesRootsInOrderAndCachesTheScan() async throws {
        let first = try makeRoot(withModels: ["openai_whisper-small"])
        let second = try makeRoot(withModels: ["openai_whisper-small", "openai_whisper-tiny"])
        let counters = ProbeCounters()
        let locator = ModelProbeTestSupport.locator(
            probes: ModelProbeTestSupport.probes(roots: [first, second], counters: counters)
        )

        let inventory = await locator.inventory()
        _ = await locator.inventory()

        XCTAssertTrue(inventory.isComplete)
        XCTAssertEqual(Set(inventory.directories.keys), ["openai_whisper-small", "openai_whisper-tiny"])
        XCTAssertEqual(
            ModelProbeTestSupport.standardizedPath(try XCTUnwrap(inventory.directories["openai_whisper-small"])),
            ModelProbeTestSupport.standardizedPath(first.appendingPathComponent("openai_whisper-small")),
            "The first root that holds a build wins"
        )
        XCTAssertEqual(counters.scanRoot.count, 2, "Two roots scanned once; the second inventory comes from cache")
    }

    func testInvalidateForcesARescan() async throws {
        let root = try makeRoot(withModels: [])
        let counters = ProbeCounters()
        let locator = ModelProbeTestSupport.locator(
            probes: ModelProbeTestSupport.probes(roots: [root], counters: counters)
        )

        let before = await locator.inventory()
        try ModelProbeTestSupport.createFakeModel(at: root.appendingPathComponent("openai_whisper-base"))
        await locator.invalidate()
        let after = await locator.inventory()

        XCTAssertTrue(before.directories.isEmpty)
        XCTAssertEqual(Set(after.directories.keys), ["openai_whisper-base"])
        XCTAssertEqual(counters.scanRoot.count, 2)
    }

    func testStorageLocationChangeNotificationInvalidatesTheCache() async throws {
        let root = try makeRoot(withModels: [])
        let counters = ProbeCounters()
        let center = NotificationCenter()
        let locator = ModelProbeTestSupport.locator(
            probes: ModelProbeTestSupport.probes(roots: [root], counters: counters),
            notificationCenter: center
        )

        _ = await locator.inventory()
        center.post(name: ModelStorageLocation.didChangeNotification, object: nil)

        // The observer invalidates asynchronously; keep asking until the
        // rescan shows up.
        let deadline = Date().addingTimeInterval(3)
        while counters.scanRoot.count < 2, Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
            _ = await locator.inventory()
        }
        XCTAssertEqual(counters.scanRoot.count, 2)
    }

    func testHungRootIsUnavailableWithoutBlockingAndOtherRootsStillAnswer() async throws {
        let hungRoot = try makeRoot(withModels: [])
        let goodRoot = try makeRoot(withModels: ["openai_whisper-small"])
        let gate = BlockingGate()
        defer { gate.openPermanently() }
        let counters = ProbeCounters()
        let locator = ModelProbeTestSupport.locator(
            probes: ModelProbeTestSupport.probes(
                roots: [hungRoot, goodRoot],
                counters: counters,
                scanRoot: { root in
                    if root == hungRoot {
                        gate.wait()
                        return [:]
                    }
                    return ModelManager.detectDownloadedVariantDirectories(in: [root])
                }
            ),
            probeTimeout: 0.2
        )

        let start = Date()
        let inventory = await locator.inventory()
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertLessThan(elapsed, 2, "A hung root must not block the caller past the probe timeout")
        XCTAssertFalse(inventory.isComplete)
        XCTAssertEqual(Set(inventory.directories.keys), ["openai_whisper-small"])

        // A build the readable root holds is found; one that is missing might
        // live on the root that did not answer, so it is unavailable, not gone.
        if case .found = await locator.lookup(variantID: "openai_whisper-small") {} else {
            XCTFail("Expected the readable root's build to be found")
        }
        let missing = await locator.lookup(variantID: "openai_whisper-large-v3")
        XCTAssertEqual(missing, .unavailable)
        XCTAssertEqual(
            counters.scanRoot.count,
            2,
            "The hung root is scanned once however many callers ask, so blocked threads never pile up"
        )
    }

    func testLateAnswerFromAHungRootCompletesTheInventory() async throws {
        let slowRoot = try makeRoot(withModels: ["openai_whisper-tiny"])
        let gate = BlockingGate()
        defer { gate.openPermanently() }
        let locator = ModelProbeTestSupport.locator(
            probes: ModelProbeTestSupport.probes(
                roots: [slowRoot],
                scanRoot: { root in
                    gate.wait()
                    return ModelManager.detectDownloadedVariantDirectories(in: [root])
                }
            ),
            probeTimeout: 0.1
        )

        let first = await locator.inventory()
        XCTAssertFalse(first.isComplete)

        // The prompt is answered / the drive wakes up: the blocked scan
        // finishes and its result is what the next inventory reports.
        gate.openPermanently()
        let deadline = Date().addingTimeInterval(3)
        var latest = first
        while !latest.isComplete, Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
            latest = await locator.inventory()
        }
        XCTAssertTrue(latest.isComplete)
        XCTAssertEqual(Set(latest.directories.keys), ["openai_whisper-tiny"])
    }

    func testLookupDistinguishesNotFoundFromFound() async throws {
        let root = try makeRoot(withModels: ["openai_whisper-small"])
        let locator = ModelProbeTestSupport.locator(probes: ModelProbeTestSupport.probes(roots: [root]))

        let found = await locator.lookup(variantID: " openai_whisper-small ")
        let missing = await locator.lookup(variantID: "openai_whisper-large-v3")

        if case .found(let directory) = found {
            XCTAssertEqual(directory.lastPathComponent, "openai_whisper-small")
        } else {
            XCTFail("Expected the build to be found")
        }
        XCTAssertEqual(missing, .notFound)
    }

    func testProbeReturnsNilWhenTheWorkBlocks() async {
        let gate = BlockingGate()
        defer { gate.openPermanently() }
        let locator = ModelProbeTestSupport.locator(
            probes: ModelProbeTestSupport.probes(roots: []),
            probeTimeout: 0.1
        )

        let start = Date()
        let result: Int? = await locator.probe {
            gate.wait()
            return 1
        }

        XCTAssertNil(result)
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
    }

    func testStorageSnapshotFallsBackToUnavailableOnTimeout() async {
        let gate = BlockingGate()
        defer { gate.openPermanently() }
        var probes = ModelProbeTestSupport.probes(roots: [])
        probes.snapshot = {
            gate.wait()
            return ModelStorageSnapshot(url: URL(fileURLWithPath: "/"), isCustom: false, isAvailable: true, isWritable: true)
        }
        let locator = ModelProbeTestSupport.locator(probes: probes, probeTimeout: 0.1)

        let snapshot = await locator.storageSnapshot()

        XCTAssertFalse(snapshot.isAvailable)
        XCTAssertFalse(snapshot.isWritable)
    }

    func testBeginAccessThrowsStorageUnavailableOnTimeout() async {
        let gate = BlockingGate()
        defer { gate.openPermanently() }
        var probes = ModelProbeTestSupport.probes(roots: [])
        probes.beginAccess = { _, _ in
            gate.wait()
            throw ModelStorageLocationError.folderMissing("test")
        }
        let locator = ModelProbeTestSupport.locator(probes: probes, probeTimeout: 0.1)

        do {
            _ = try await locator.beginAccess(createIfNeeded: false, requiresWrite: false)
            XCTFail("Expected a timeout")
        } catch {
            XCTAssertEqual(error as? ModelLoadError, .storageUnavailable)
        }
    }

    func testMetricsMeasureSizesAndReportCompleteness() async throws {
        let root = try makeRoot(withModels: ["openai_whisper-small"])
        let locator = ModelProbeTestSupport.locator(probes: ModelProbeTestSupport.probes(roots: [root]))

        let result = await locator.metrics()

        XCTAssertTrue(result.isComplete)
        XCTAssertEqual(result.metrics.downloadedModelIDs, ["openai_whisper-small"])
        XCTAssertGreaterThan(result.metrics.totalBytes, 0)
    }

    func testDeleteFamilyRemovesTheFamilyAndRefreshesTheInventory() async throws {
        let root = try makeRoot(withModels: ["openai_whisper-small", "openai_whisper-tiny"])
        let locator = ModelProbeTestSupport.locator(probes: ModelProbeTestSupport.probes(roots: [root]))
        let before = await locator.inventory()
        XCTAssertEqual(before.directories.count, 2)

        let removed = try await locator.deleteFamily(canonicalID: "openai_whisper-small")
        let after = await locator.inventory()

        XCTAssertTrue(removed)
        XCTAssertEqual(Set(after.directories.keys), ["openai_whisper-tiny"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("openai_whisper-small").path))
    }

    func testDeleteVariantRemovesOnlyThatBuild() async throws {
        let root = try makeRoot(withModels: ["openai_whisper-large-v3", "openai_whisper-large-v3_947MB"])
        let locator = ModelProbeTestSupport.locator(probes: ModelProbeTestSupport.probes(roots: [root]))

        try await locator.deleteVariant(named: "openai_whisper-large-v3")
        let after = await locator.inventory()

        XCTAssertEqual(Set(after.directories.keys), ["openai_whisper-large-v3_947MB"])
    }
}
