import XCTest
import Sparkle
@testable import Orttaai

@MainActor
final class AppUpdateServiceTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "AppUpdateServiceTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

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

    private func service(autoDownload: Bool) -> (AppUpdateService, checks: () -> Int) {
        defaults.set(autoDownload, forKey: AppUpdateService.automaticDownloadsKey)
        let service = AppUpdateService(defaults: defaults)
        var checks = 0
        service.requestCheck = { checks += 1 }
        return (service, { checks })
    }

    func testFoundUpdateWaitsForAClickWhenDownloadsAreManual() throws {
        let (service, checks) = service(autoDownload: false)
        var choices: [SPUUserUpdateChoice] = []
        service.showUpdateFound(with: try item(), state: try state(.notDownloaded)) { choices.append($0) }
        XCTAssertEqual(service.phase, .available(version: "1.99"))
        XCTAssertEqual(choices, [.dismiss])
        service.dismissUpdateInstallation()
        XCTAssertEqual(service.phase, .available(version: "1.99"), "The button outlasts Sparkle's session")

        service.performPrimaryAction()
        XCTAssertEqual(checks(), 1)
        XCTAssertEqual(service.phase, .downloading(version: "1.99", fraction: nil))
        service.showUserInitiatedUpdateCheck {}
        XCTAssertEqual(service.phase, .downloading(version: "1.99", fraction: nil), "No 'Checking' flash after the click")
        service.showUpdateFound(with: try item(), state: try state(.notDownloaded)) { choices.append($0) }
        XCTAssertEqual(choices.last, .install)
    }

    func testDownloadShowsWholePercentsThenInstallsAfterAClick() throws {
        let (service, _) = service(autoDownload: false)
        service.showUpdateFound(with: try item(), state: try state(.notDownloaded)) { _ in }
        service.performPrimaryAction()
        service.showUpdateFound(with: try item(), state: try state(.notDownloaded)) { _ in }
        service.showDownloadInitiated {}
        service.showDownloadDidReceiveExpectedContentLength(1_000)
        service.showDownloadDidReceiveData(ofLength: 425)
        XCTAssertEqual(service.phase, .downloading(version: "1.99", fraction: 0.42))
        service.showDownloadDidReceiveData(ofLength: 575)
        XCTAssertEqual(service.phase, .downloading(version: "1.99", fraction: 1))
        service.showDownloadDidStartExtractingUpdate()
        XCTAssertEqual(service.phase, .preparing(version: "1.99"))
        var choice: SPUUserUpdateChoice?
        service.showReady { choice = $0 }
        XCTAssertEqual(choice, .install, "The click asked for the restart")
        XCTAssertEqual(service.phase, .installing(version: "1.99"))
    }

    func testAutomaticDownloadShowsProgressThenWaitsToRestart() throws {
        let (service, checks) = service(autoDownload: true)
        var choices: [SPUUserUpdateChoice] = []
        service.showUpdateFound(with: try item(), state: try state(.notDownloaded)) { choices.append($0) }
        XCTAssertEqual(choices, [.install])
        XCTAssertEqual(service.phase, .downloading(version: "1.99", fraction: nil))
        service.showDownloadInitiated {}
        service.showDownloadDidStartExtractingUpdate()
        service.showReady { choices.append($0) }
        XCTAssertEqual(choices.last, .dismiss, "Kept to install on quit, never restarted unasked")
        XCTAssertEqual(service.phase, .ready(version: "1.99"))
        service.dismissUpdateInstallation()
        XCTAssertEqual(service.phase, .ready(version: "1.99"))

        service.performPrimaryAction()
        XCTAssertEqual(checks(), 1)
        XCTAssertEqual(service.phase, .installing(version: "1.99"))
        service.showUpdateFound(with: try item(), state: try state(.installing)) { choices.append($0) }
        XCTAssertEqual(choices.last, .install)
    }

    func testAPreparedUpdateFoundAgainIsReadyNotRedownloaded() throws {
        let (service, _) = service(autoDownload: false)
        var choice: SPUUserUpdateChoice?
        service.showUpdateFound(with: try item(), state: try state(.downloaded)) { choice = $0 }
        XCTAssertEqual(service.phase, .ready(version: "1.99"))
        XCTAssertEqual(choice, .dismiss)
    }

    func testQuietCheckFailureStaysQuietButAFailedDownloadShows() throws {
        let (service, checks) = service(autoDownload: true)
        service.showUpdaterError(NSError(domain: "test", code: 1)) {}
        XCTAssertEqual(service.phase, .idle)

        service.showUpdateFound(with: try item(), state: try state(.notDownloaded)) { _ in }
        service.showDownloadInitiated {}
        service.showUpdaterError(NSError(domain: "test", code: 2)) {}
        XCTAssertEqual(service.phase, .failed)
        service.dismissUpdateInstallation()
        XCTAssertEqual(service.phase, .failed)
        service.performPrimaryAction()
        XCTAssertEqual(checks(), 1, "Clicking a failure tries again")
    }

    func testRequestedCheckShowsCheckingThenUpToDate() throws {
        let (service, _) = service(autoDownload: true)
        service.showUserInitiatedUpdateCheck {}
        XCTAssertEqual(service.phase, .checking)
        var acknowledged = false
        service.showUpdateNotFoundWithError(NSError(domain: "test", code: 0)) { acknowledged = true }
        XCTAssertTrue(acknowledged)
        XCTAssertEqual(service.phase, .upToDate)
        service.dismissUpdateInstallation()
        XCTAssertEqual(service.phase, .upToDate)
    }

    func testCheckForUpdatesActsOnAnUpdateAlreadyShown() throws {
        let (service, checks) = service(autoDownload: false)
        service.showUpdateFound(with: try item(), state: try state(.notDownloaded)) { _ in }
        service.checkForUpdates()
        XCTAssertEqual(service.phase, .available(version: "1.99"), "Not supported until started")
        XCTAssertEqual(checks(), 0)
    }

    func testAutomaticDownloadsCarryOverSparklesSetting() {
        defaults.set(false, forKey: "SUAutomaticallyUpdate")
        XCTAssertFalse(AppUpdateService(defaults: defaults).automaticallyDownloadsUpdates)
        let service = AppUpdateService(defaults: defaults)
        service.setAutomaticallyDownloadsUpdates(true)
        XCTAssertTrue(AppUpdateService(defaults: defaults).automaticallyDownloadsUpdates)
    }
}

private final class UpdateStateCoder: NSCoder {
    let stage: SPUUserUpdateStage
    init(stage: SPUUserUpdateStage) { self.stage = stage; super.init() }
    override var allowsKeyedCoding: Bool { true }
    override func decodeInteger(forKey key: String) -> Int { stage.rawValue }
    override func decodeBool(forKey key: String) -> Bool { false }
}
