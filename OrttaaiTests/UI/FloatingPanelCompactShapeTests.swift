// FloatingPanelCompactShapeTests.swift
// OrttaaiTests

import XCTest
import SwiftUI
@testable import Orttaai

/// The recording pill never displays transcript text and keeps exactly one
/// compact shape while recording — there is no transcript-driven resize path
/// left anywhere in the floating panel.
@MainActor
final class FloatingPanelCompactShapeTests: XCTestCase {

    func testRecordingPanelKeepsOneCompactSizeAcrossContentUpdates() {
        let controller = FloatingPanelController()

        controller.transitionToRecording(
            content: WaveformView(audioLevel: 0, elapsedSeconds: 0)
        )
        XCTAssertEqual(controller.currentSize, WindowSize.floatingPanelRecording)

        // Everything that can change mid-recording (levels, elapsed time,
        // countdown, hands-free promotion, edit badge) flows through
        // updateContent, which never resizes the panel.
        controller.updateContent(
            WaveformView(
                audioLevel: 0.9,
                elapsedSeconds: 42,
                countdownSeconds: 9,
                isHandsFree: true,
                isEditMode: true
            )
        )
        XCTAssertEqual(
            controller.currentSize,
            WindowSize.floatingPanelRecording,
            "The recording pill must keep its single compact size for the whole recording"
        )
    }

    func testWaveformViewExposesNoTranscriptDisplayInput() {
        // The recording pill's only content view must have no way to receive
        // transcript text: the C1 pill-transcript rendering is gone for good.
        let view = WaveformView(audioLevel: 0, elapsedSeconds: 0)
        let propertyNames = Mirror(reflecting: view).children.compactMap(\.label)
        XCTAssertFalse(
            propertyNames.contains { $0.lowercased().contains("transcript") },
            "WaveformView must not accept transcript content; found: \(propertyNames)"
        )
    }
}
