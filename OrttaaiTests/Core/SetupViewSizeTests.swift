// SetupViewSizeTests.swift
// OrttaaiTests

import SwiftUI
import XCTest
@testable import Orttaai

/// The setup window takes its size from SetupView. If the view's size
/// followed its content, a long step would stretch the window past the
/// screen and hide the Continue button.
@MainActor
final class SetupViewSizeTests: XCTestCase {
    func testSetupViewKeepsTheWindowSize() {
        let hosting = NSHostingView(rootView: SetupView())
        XCTAssertEqual(hosting.fittingSize, WindowSize.setup)
        XCTAssertEqual(hosting.intrinsicContentSize, WindowSize.setup)
    }
}
