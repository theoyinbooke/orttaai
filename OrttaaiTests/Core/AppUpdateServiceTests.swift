import XCTest
import Sparkle
@testable import Orttaai

@MainActor
final class AppUpdateServiceTests: XCTestCase {
    private func item() throws -> SUAppcastItem {
        try XCTUnwrap(SUAppcastItem(dictionary: [
            "enclosure": [
                "url": "https://example.invalid/Orttaai.zip",
                "sparkle:version": "1.99.0",
                "sparkle:shortVersionString": "1.99",
            ],
        ]))
    }

    private func state(_ stage: SPUUserUpdateStage) throws -> SPUUserUpdateState {
        try XCTUnwrap(SPUUserUpdateState(coder: UpdateStateCoder(stage: stage)))
    }

    private func controller(for service: AppUpdateService) -> SPUStandardUpdaterController {
        SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: service, userDriverDelegate: service)
    }

    func testDownloadAndExtractionDoNotAdvertiseAnUnpreparedUpdate() throws {
        let service = AppUpdateService()
        let controller = controller(for: service)
        let item = try item()
        let delegate: SPUUpdaterDelegate = service
        var installs = 0
        service.installReadyUpdate()
        delegate.updater?(controller.updater, didDownloadUpdate: item)
        delegate.updater?(controller.updater, didExtractUpdate: item)
        XCTAssertNil(service.readyVersion)
        XCTAssertTrue(delegate.updater?(
            controller.updater, willInstallUpdateOnQuit: item,
            immediateInstallationBlock: { installs += 1 }
        ) == true)
        XCTAssertEqual(service.readyVersion, "1.99")
        XCTAssertEqual(installs, 0, "Downloading must not trigger a relaunch")
        service.installReadyUpdate()
        XCTAssertEqual(installs, 1)
        service.installReadyUpdate()
        XCTAssertEqual(installs, 2, "Sparkle supports retrying if termination was canceled")
    }

    func testDownloadFailureClearsTheReadyButtonAndInstallHandler() throws {
        let service = AppUpdateService()
        let controller = controller(for: service)
        var installs = 0
        _ = service.updater(controller.updater, willInstallUpdateOnQuit: try item()) { installs += 1 }
        let delegate: SPUUpdaterDelegate = service
        delegate.updater?(controller.updater, didAbortWithError: NSError(domain: "test", code: 1))
        XCTAssertNil(service.readyVersion)
        service.installReadyUpdate()
        XCTAssertEqual(installs, 0)
    }

    func testCancelOrNewDownloadClearsStaleReadiness() throws {
        let service = AppUpdateService()
        let controller = controller(for: service)
        let item = try item()
        _ = service.updater(controller.updater, willInstallUpdateOnQuit: item) {}
        let delegate: SPUUpdaterDelegate = service
        delegate.userDidCancelDownload?(controller.updater)
        XCTAssertNil(service.readyVersion)
        _ = service.updater(controller.updater, willInstallUpdateOnQuit: item) {}
        delegate.updater?(controller.updater, willDownloadUpdate: item, with: NSMutableURLRequest(url: URL(string: "https://example.invalid")!))
        XCTAssertNil(service.readyVersion)
    }

    func testRemindLaterRetainsDownloadedUpdateButSkipClearsIt() throws {
        let service = AppUpdateService()
        let controller = controller(for: service)
        let item = try item()
        let downloaded = try state(.downloaded)
        let userDriver: SPUStandardUserDriverDelegate = service
        userDriver.standardUserDriverWillHandleShowingUpdate?(true, forUpdate: item, state: downloaded)
        XCTAssertEqual(service.readyVersion, "1.99")
        let delegate: SPUUpdaterDelegate = service
        delegate.updater?(controller.updater, userDidMake: .dismiss, forUpdate: item, state: downloaded)
        XCTAssertEqual(service.readyVersion, "1.99")
        delegate.updater?(controller.updater, userDidMake: .skip, forUpdate: item, state: downloaded)
        XCTAssertNil(service.readyVersion)
    }

    func testUndownloadedAndInstallingStatesMatchReadiness() throws {
        let service = AppUpdateService()
        let item = try item()
        service.standardUserDriverWillHandleShowingUpdate(true, forUpdate: item, state: try state(.installing))
        XCTAssertEqual(service.readyVersion, "1.99")
        service.standardUserDriverWillHandleShowingUpdate(true, forUpdate: item, state: try state(.notDownloaded))
        XCTAssertNil(service.readyVersion)
    }

    func testSparkleCheckboxPreferenceChangesReachTheObservedState() {
        let service = AppUpdateService()
        let controller = controller(for: service)
        let updater = controller.updater
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: "SUAutomaticallyUpdate")
        defer {
            if let previous { defaults.set(previous, forKey: "SUAutomaticallyUpdate") }
            else { defaults.removeObject(forKey: "SUAutomaticallyUpdate") }
        }
        service.observePreferences(of: updater)
        updater.automaticallyDownloadsUpdates = true
        XCTAssertTrue(service.automaticallyDownloadsUpdates)
        updater.automaticallyDownloadsUpdates = false
        XCTAssertFalse(service.automaticallyDownloadsUpdates)
    }
}

private final class UpdateStateCoder: NSCoder {
    let stage: SPUUserUpdateStage
    init(stage: SPUUserUpdateStage) { self.stage = stage; super.init() }
    override var allowsKeyedCoding: Bool { true }
    override func decodeInteger(forKey key: String) -> Int { stage.rawValue }
    override func decodeBool(forKey key: String) -> Bool { false }
}
