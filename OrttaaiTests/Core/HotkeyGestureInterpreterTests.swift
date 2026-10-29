// HotkeyGestureInterpreterTests.swift
// OrttaaiTests

import XCTest
@testable import Orttaai

final class HotkeyGestureInterpreterTests: XCTestCase {
    private var interpreter = HotkeyGestureInterpreter()

    override func setUp() {
        super.setUp()
        interpreter = HotkeyGestureInterpreter()
    }

    func testQuickReleaseIsTapWhenHandsFreeEnabled() {
        interpreter.recordPress(at: 100.0)
        let action = interpreter.evaluateRelease(at: 100.1, handsFreeEnabled: true)
        XCTAssertEqual(action, .promoteToHandsFree)
    }

    func testReleaseJustUnderThresholdIsTap() {
        interpreter.recordPress(at: 100.0)
        let action = interpreter.evaluateRelease(
            at: 100.0 + HotkeyGestureInterpreter.tapMaxDuration - 0.001,
            handsFreeEnabled: true
        )
        XCTAssertEqual(action, .promoteToHandsFree, "A hold shorter than the threshold is, by definition, a tap")
    }

    func testDeliberatePressShorterThanMinimumRecordingIsTap() {
        // A 0.42s press used to read as a hold, stop at once, and be thrown
        // away as shorter than the 0.5s minimum — the press did nothing.
        interpreter.recordPress(at: 100.0)
        let action = interpreter.evaluateRelease(at: 100.42, handsFreeEnabled: true)
        XCTAssertEqual(action, .promoteToHandsFree)
    }

    func testReleaseExactlyAtThresholdIsHold() {
        // Zero-based timestamps keep the subtraction exact in binary floating
        // point, so this genuinely exercises the `duration == threshold` edge.
        interpreter.recordPress(at: 0.0)
        let action = interpreter.evaluateRelease(
            at: HotkeyGestureInterpreter.tapMaxDuration,
            handsFreeEnabled: true
        )
        XCTAssertEqual(action, .stopRecording, "The threshold boundary itself must classify as a hold")
    }

    func testLongHoldReleaseStops() {
        interpreter.recordPress(at: 100.0)
        let action = interpreter.evaluateRelease(at: 103.0, handsFreeEnabled: true)
        XCTAssertEqual(action, .stopRecording)
    }

    func testQuickReleaseStopsWhenHandsFreeDisabled() {
        interpreter.recordPress(at: 100.0)
        let action = interpreter.evaluateRelease(at: 100.05, handsFreeEnabled: false)
        XCTAssertEqual(action, .stopRecording, "With hands-free disabled every release stops — pure push-to-talk")
    }

    func testReleaseWithoutPressIsIgnored() {
        let action = interpreter.evaluateRelease(at: 100.0, handsFreeEnabled: true)
        XCTAssertEqual(action, .ignore)
    }

    func testReleaseAfterResetIsIgnored() {
        interpreter.recordPress(at: 100.0)
        interpreter.reset()
        let action = interpreter.evaluateRelease(at: 100.1, handsFreeEnabled: true)
        XCTAssertEqual(action, .ignore)
    }

    func testEvaluateConsumesThePress() {
        interpreter.recordPress(at: 100.0)
        _ = interpreter.evaluateRelease(at: 100.1, handsFreeEnabled: true)
        let second = interpreter.evaluateRelease(at: 100.2, handsFreeEnabled: true)
        XCTAssertEqual(second, .ignore, "A second release without a new press must do nothing")
    }

    func testNonMonotonicClockClassifiesAsHold() {
        interpreter.recordPress(at: 100.0)
        let action = interpreter.evaluateRelease(at: 99.0, handsFreeEnabled: true)
        XCTAssertEqual(action, .stopRecording, "Clock weirdness must never leave recording running unexpectedly")
    }
}
