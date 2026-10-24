import XCTest
@testable import Orttaai

@MainActor
final class WhatsNewTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "WhatsNewTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private let catalog = [
        WhatsNewRelease(version: "2.0.0", items: [
            WhatsNewItem(id: "a", title: "A", detail: "First.", art: .updates),
        ]),
    ]

    private func center() -> WhatsNewCenter {
        WhatsNewCenter(defaults: defaults, catalog: catalog)
    }

    func testCatalogEntriesFollowTheRules() {
        var versions = Set<String>()
        var ids = Set<String>()
        for release in WhatsNewCatalog.releases {
            XCTAssertTrue(versions.insert(release.version).inserted, "\(release.version) listed twice")
            XCTAssertTrue((1...WhatsNewCatalog.maxItems).contains(release.items.count), "\(release.version): 1 to 3 highlights")
            for item in release.items {
                XCTAssertTrue(ids.insert(item.id).inserted, "\(item.id) used twice")
                XCTAssertFalse(item.title.isEmpty)
                XCTAssertLessThanOrEqual(item.title.count, WhatsNewCatalog.maxTitleLength, item.title)
                XCTAssertLessThanOrEqual(item.detail.count, WhatsNewCatalog.maxDetailLength, item.detail)
            }
        }
        let ordered = WhatsNewCatalog.releases.map(\.version)
        XCTAssertEqual(ordered, ordered.sorted { $0.compare($1, options: .numeric) == .orderedDescending }, "Newest first")
    }

    func testAnUpdatedUserSeesTheNotesOnceAfterClosingThem() {
        defaults.set("1.9.0", forKey: WhatsNewCenter.lastSeenVersionKey)
        let first = center()
        first.evaluate(currentVersion: "2.0.0", isExistingUser: true)
        XCTAssertEqual(first.release?.version, "2.0.0")

        // Quit before it was closed: still there next launch.
        let second = center()
        second.evaluate(currentVersion: "2.0.0", isExistingUser: true)
        XCTAssertEqual(second.release?.version, "2.0.0")
        second.dismiss()
        XCTAssertNil(second.release)

        let third = center()
        third.evaluate(currentVersion: "2.0.0", isExistingUser: true)
        XCTAssertNil(third.release)
    }

    func testUpdatingFromAVersionBeforeWhatsNewShowsTheNotes() {
        let center = center()
        center.evaluate(currentVersion: "2.0.0", isExistingUser: true)
        XCTAssertEqual(center.release?.version, "2.0.0")
    }

    func testAFreshInstallStartsWithoutNotes() {
        let center = center()
        center.evaluate(currentVersion: "2.0.0", isExistingUser: false)
        XCTAssertNil(center.release)
        XCTAssertEqual(defaults.string(forKey: WhatsNewCenter.lastSeenVersionKey), "2.0.0")
    }

    func testAVersionWithoutNotesOrAnOlderOneShowsNothing() {
        defaults.set("2.0.0", forKey: WhatsNewCenter.lastSeenVersionKey)
        let older = center()
        older.evaluate(currentVersion: "1.9.0", isExistingUser: true)
        XCTAssertNil(older.release)

        defaults.set("2.0.0", forKey: WhatsNewCenter.lastSeenVersionKey)
        let unlisted = center()
        unlisted.evaluate(currentVersion: "2.0.1", isExistingUser: true)
        XCTAssertNil(unlisted.release)
        XCTAssertEqual(defaults.string(forKey: WhatsNewCenter.lastSeenVersionKey), "2.0.1")
    }
}
