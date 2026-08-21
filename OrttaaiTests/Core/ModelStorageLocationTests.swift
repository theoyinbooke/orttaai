// ModelStorageLocationTests.swift
// OrttaaiTests

import XCTest
@testable import Orttaai

final class ModelStorageLocationTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var tempRoot: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        suiteName = "ModelStorageLocationTests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("orttaai-model-storage-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempRoot)
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        tempRoot = nil
        try super.tearDownWithError()
    }

    func testDefaultLocationMatchesWhisperKitSharedLibrary() {
        let url = ModelStorageLocation.defaultDownloadBaseURL()

        XCTAssertEqual(url.lastPathComponent, "huggingface")
        XCTAssertEqual(url.deletingLastPathComponent().lastPathComponent, "Documents")
    }

    func testCustomLocationPersistsAndResolvesBookmark() throws {
        let custom = tempRoot.appendingPathComponent("External Models", isDirectory: true)
        try FileManager.default.createDirectory(at: custom, withIntermediateDirectories: true)

        try ModelStorageLocation.setCustomLocation(custom, defaults: defaults)

        XCTAssertNotNil(defaults.data(forKey: ModelStorageLocation.customBookmarkKey))
        XCTAssertEqual(
            ModelStorageLocation.selectedDownloadBaseURL(defaults: defaults),
            custom.standardizedFileURL
        )
        let snapshot = ModelStorageLocation.snapshot(defaults: defaults)
        XCTAssertTrue(snapshot.isCustom)
        XCTAssertTrue(snapshot.isAvailable)
        XCTAssertTrue(snapshot.isWritable)
        XCTAssertTrue(
            try FileManager.default.contentsOfDirectory(atPath: custom.path).isEmpty,
            "The write probe must always clean itself up"
        )
    }

    func testUnavailableCustomLocationDoesNotSilentlyFallBack() throws {
        let missing = tempRoot.appendingPathComponent("Disconnected SSD", isDirectory: true)
        defaults.set(missing.path, forKey: ModelStorageLocation.customPathKey)

        let snapshot = ModelStorageLocation.snapshot(defaults: defaults)
        XCTAssertTrue(snapshot.isCustom)
        XCTAssertEqual(snapshot.url, missing.standardizedFileURL)
        XCTAssertFalse(snapshot.isAvailable)

        XCTAssertThrowsError(
            try ModelStorageLocation.beginAccess(
                createIfNeeded: true,
                requiresWrite: true,
                defaults: defaults
            )
        ) { error in
            XCTAssertEqual(error as? ModelStorageLocationError, .folderMissing(missing.standardizedFileURL.path))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
    }

    func testResetReturnsToDefaultWithoutDeletingCustomFolder() throws {
        let custom = tempRoot.appendingPathComponent("Models", isDirectory: true)
        try FileManager.default.createDirectory(at: custom, withIntermediateDirectories: true)
        try ModelStorageLocation.setCustomLocation(custom, defaults: defaults)

        ModelStorageLocation.resetToDefault(defaults: defaults)

        XCTAssertFalse(ModelStorageLocation.snapshot(defaults: defaults).isCustom)
        XCTAssertTrue(FileManager.default.fileExists(atPath: custom.path))
    }

    func testContainmentRequiresAPathBoundary() {
        let root = URL(fileURLWithPath: "/Volumes/Models", isDirectory: true)
        XCTAssertTrue(ModelStorageLocation.contains(
            URL(fileURLWithPath: "/Volumes/Models/models/model.bin"),
            in: root
        ))
        XCTAssertFalse(ModelStorageLocation.contains(
            URL(fileURLWithPath: "/Volumes/Models-Backup/model.bin"),
            in: root
        ))
    }
}
