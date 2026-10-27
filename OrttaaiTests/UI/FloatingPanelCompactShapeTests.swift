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

    func testHandleKeepsNoViewAfterADictation() async throws {
        // A hidden hosting view still runs its view's animations, so the
        // handle must not keep the processing shimmer (or anything else).
        let controller = FloatingPanelController()
        controller.show()
        controller.transitionToRecording(content: WaveformView(audioLevel: 0.4, elapsedSeconds: 3))
        controller.transitionToProcessing(
            content: ProcessingIndicatorView(estimateText: nil, errorMessage: nil)
        )
        XCTAssertTrue(controller.holdsContent)

        controller.transitionToHandle()
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertFalse(controller.holdsContent, "The handle must release the last view")
    }

    func testHandleKeepsNoViewAfterTheHintHides() async throws {
        let controller = FloatingPanelController()
        controller.show()
        controller.mouseEntered(with: Self.event(.mouseEntered))
        XCTAssertTrue(controller.holdsContent)

        controller.mouseExited(with: Self.event(.mouseExited))
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertFalse(controller.holdsContent, "The hint's animated backdrop must not keep running hidden")
    }

    func testRecordingStartedDuringTheShrinkKeepsItsPill() async throws {
        let controller = FloatingPanelController()
        controller.show()
        controller.transitionToProcessing(
            content: ProcessingIndicatorView(estimateText: nil, errorMessage: nil)
        )
        controller.transitionToHandle()
        controller.transitionToRecording(content: WaveformView(audioLevel: 0.4, elapsedSeconds: 0))
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertTrue(controller.holdsContent, "The handle's late completion must not clear a new recording")
    }

    private static func event(_ type: NSEvent.EventType) -> NSEvent {
        NSEvent.enterExitEvent(
            with: type, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
            context: nil, eventNumber: 0, trackingNumber: 0, userData: nil
        )!
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
