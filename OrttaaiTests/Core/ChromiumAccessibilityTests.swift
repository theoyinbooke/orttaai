// ChromiumAccessibilityTests.swift
// OrttaaiTests

import XCTest
@testable import Orttaai

final class ChromiumAccessibilityTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// An app bundle holding the given files under Contents/Frameworks.
    private func bundle(_ name: String, files: [String]) throws -> URL {
        let app = root.appendingPathComponent("\(name).app", isDirectory: true)
        let frameworks = app.appendingPathComponent("Contents/Frameworks", isDirectory: true)
        try FileManager.default.createDirectory(at: frameworks, withIntermediateDirectories: true)
        for file in files {
            let url = frameworks.appendingPathComponent(file)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: url.path, contents: Data())
        }
        return app
    }

    func testEnginesAreToldApartByTheirFrameworks() throws {
        let electron = try bundle("Claude", files: ["Electron Framework.framework/Versions/A/Electron Framework"])
        let chrome = try bundle("Chrome", files: ["Google Chrome Framework.framework/Versions/Current/Helpers/chrome_crashpad_handler"])
        let chatGPT = try bundle("ChatGPT", files: ["Codex Framework.framework/Versions/Current/Helpers/browser_crashpad_handler"])
        let native = try bundle("Notes", files: ["Sparkle.framework/Versions/Current/Sparkle"])

        XCTAssertEqual(ChromiumAccessibility.engine(ofBundleAt: electron), .electron)
        XCTAssertEqual(ChromiumAccessibility.engine(ofBundleAt: chrome), .chromium)
        XCTAssertEqual(ChromiumAccessibility.engine(ofBundleAt: chatGPT), .chromium)
        XCTAssertEqual(ChromiumAccessibility.engine(ofBundleAt: native), .other)
        XCTAssertEqual(ChromiumAccessibility.engine(ofBundleAt: root.appendingPathComponent("Missing.app")), .other)
    }

    func testEachEngineGetsItsSwitchAndEditorsAreLeftAlone() {
        XCTAssertEqual(ChromiumAccessibility.attributes(for: .electron, bundleID: "com.anthropic.claudefordesktop"),
                       ["AXManualAccessibility"])
        XCTAssertEqual(ChromiumAccessibility.attributes(for: .chromium, bundleID: "com.google.Chrome"),
                       ["AXManualAccessibility", "AXEnhancedUserInterface"])
        XCTAssertEqual(ChromiumAccessibility.attributes(for: .other, bundleID: "com.apple.TextEdit"), [])
        // VS Code switches to screen reader mode when Accessibility comes on.
        XCTAssertEqual(ChromiumAccessibility.attributes(for: .electron, bundleID: "com.microsoft.VSCode"), [])
    }
}
