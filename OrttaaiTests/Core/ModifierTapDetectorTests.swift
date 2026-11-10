// ModifierTapDetectorTests.swift
// OrttaaiTests

import XCTest
@testable import Orttaai

final class ModifierTapDetectorTests: XCTestCase {
    private let rightOption = ModifierTapDetector.rightOptionKeyCode
    private let leftShift: UInt16 = 56
    private var detector = ModifierTapDetector()

    override func setUp() {
        super.setUp()
        detector = ModifierTapDetector()
    }

    private func press(at time: TimeInterval, othersDown: Bool = false) -> Bool {
        detector.modifiersChanged(keyCode: rightOption, keyIsDown: true, otherModifiersDown: othersDown, at: time)
    }

    private func release(at time: TimeInterval, othersDown: Bool = false) -> Bool {
        detector.modifiersChanged(keyCode: rightOption, keyIsDown: false, otherModifiersDown: othersDown, at: time)
    }

    func testQuickPressAndReleaseIsTap() {
        XCTAssertFalse(press(at: 10.0), "The press alone is never the tap")
        XCTAssertTrue(release(at: 10.15))
    }

    func testPressAtThresholdIsNotTap() {
        _ = press(at: 0.0)
        XCTAssertFalse(release(at: ModifierTapDetector.tapMaxDuration), "Holding the key is not a tap")
    }

    func testLongHoldIsNotTap() {
        _ = press(at: 10.0)
        XCTAssertFalse(release(at: 12.0))
    }

    func testTypingAnOptionCharacterIsNotTap() {
        // ⌥E for an accent: a key goes down while Right Option is held.
        _ = press(at: 10.0)
        detector.otherInput()
        XCTAssertFalse(release(at: 10.1))
    }

    func testClickingWhileHeldIsNotTap() {
        _ = press(at: 10.0)
        detector.otherInput()
        XCTAssertFalse(release(at: 10.1), "⌥-click must not start dictation")
    }

    func testAddingAnotherModifierIsNotTap() {
        _ = press(at: 10.0)
        _ = detector.modifiersChanged(keyCode: leftShift, keyIsDown: true, otherModifiersDown: true, at: 10.05)
        _ = detector.modifiersChanged(keyCode: leftShift, keyIsDown: true, otherModifiersDown: false, at: 10.08)
        XCTAssertFalse(release(at: 10.1), "⇧⌥ is a shortcut, not a tap")
    }

    func testPressingWhileAnotherModifierIsHeldIsNotTap() {
        XCTAssertFalse(press(at: 10.0, othersDown: true))
        XCTAssertFalse(release(at: 10.1, othersDown: true), "⌘ then Right Option is a shortcut")
    }

    func testKeysTypedBeforeThePressDoNotSpoilIt() {
        detector.otherInput()
        _ = press(at: 10.0)
        XCTAssertTrue(release(at: 10.1))
    }

    func testReleaseWithoutPressIsIgnored() {
        XCTAssertFalse(release(at: 10.0))
    }

    func testEachTapIsCountedOnce() {
        _ = press(at: 10.0)
        XCTAssertTrue(release(at: 10.1))
        XCTAssertFalse(release(at: 10.2), "A stray second release is not another tap")

        _ = press(at: 11.0)
        XCTAssertTrue(release(at: 11.1), "The next clean tap counts again")
    }

    func testComboDoesNotSpoilTheNextTap() {
        _ = press(at: 10.0)
        detector.otherInput()
        XCTAssertFalse(release(at: 10.1))

        _ = press(at: 11.0)
        XCTAssertTrue(release(at: 11.1))
    }

    func testClockGoingBackwardsIsNotTap() {
        _ = press(at: 10.0)
        XCTAssertFalse(release(at: 9.9))
    }

    func testResetForgetsThePress() {
        _ = press(at: 10.0)
        detector.reset()
        XCTAssertFalse(release(at: 10.1))
    }

    func testTapMatchesTheShortcutTap() {
        XCTAssertEqual(ModifierTapDetector.tapMaxDuration, HotkeyGestureInterpreter.tapMaxDuration)
    }

    // MARK: - Right Command

    func testRightCommandTapIsSeenOnlyByItsOwnDetector() {
        var command = ModifierTapDetector(keyCode: ModifierTapDetector.rightCommandKeyCode)
        let rightCommand = ModifierTapDetector.rightCommandKeyCode

        XCTAssertFalse(command.modifiersChanged(keyCode: rightCommand, keyIsDown: true, otherModifiersDown: false, at: 1.0))
        XCTAssertTrue(command.modifiersChanged(keyCode: rightCommand, keyIsDown: false, otherModifiersDown: false, at: 1.1))

        _ = press(at: 2.0)
        XCTAssertFalse(
            detector.modifiersChanged(keyCode: rightCommand, keyIsDown: false, otherModifiersDown: false, at: 2.05),
            "The Right Option detector ignores Right Command"
        )
    }

    func testRightCommandNeedsABriskTap() {
        var command = ModifierTapDetector(
            keyCode: ModifierTapDetector.rightCommandKeyCode,
            maxTapDuration: ModifierTapDetector.rightCommandTapMaxDuration
        )
        let rightCommand = ModifierTapDetector.rightCommandKeyCode

        _ = command.modifiersChanged(keyCode: rightCommand, keyIsDown: true, otherModifiersDown: false, at: 1.0)
        XCTAssertFalse(
            command.modifiersChanged(keyCode: rightCommand, keyIsDown: false, otherModifiersDown: false, at: 1.35),
            "A press as long as a quick ⌘Tab is not a tap"
        )
        _ = command.modifiersChanged(keyCode: rightCommand, keyIsDown: true, otherModifiersDown: false, at: 2.0)
        XCTAssertTrue(command.modifiersChanged(keyCode: rightCommand, keyIsDown: false, otherModifiersDown: false, at: 2.15))
    }

    func testRightCommandShortcutIsNotATap() {
        var command = ModifierTapDetector(keyCode: ModifierTapDetector.rightCommandKeyCode)
        let rightCommand = ModifierTapDetector.rightCommandKeyCode

        _ = command.modifiersChanged(keyCode: rightCommand, keyIsDown: true, otherModifiersDown: false, at: 1.0)
        command.otherInput() // the C of ⌘C
        XCTAssertFalse(command.modifiersChanged(keyCode: rightCommand, keyIsDown: false, otherModifiersDown: false, at: 1.1))
    }
}
