// TrendCardViewTests.swift
// OrttaaiTests

import Combine
import OSLog
import SwiftUI
import XCTest
@testable import Orttaai

/// Picking a range or a device redraws the trend chart inside the picker's
/// animation. Animated, Swift Charts sized its axis labels negatively on
/// every frame of the change, which SwiftUI reports as a runtime issue.
@MainActor
final class TrendCardViewTests: XCTestCase {
    func testPickingARangeLaysOutNoInvalidFrames() async throws {
        let model = TrendModel()
        model.points = Self.points(days: 30)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 360),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = NSHostingView(rootView: TrendHost(model: model))
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        try await Task.sleep(for: .milliseconds(300))
        let started = Date()

        for days in [7, 90, 30, 365, 7] {
            withAnimation(.easeOut(duration: 0.16)) {
                model.points = Self.points(days: days)
            }
            try await Task.sleep(for: .milliseconds(400))
        }

        let store = try OSLogStore(scope: .currentProcessIdentifier)
        let entries = try store.getEntries(
            at: store.position(date: started),
            matching: NSPredicate(format: "subsystem == %@", "com.apple.runtime-issues")
        )
        let invalidFrames = entries
            .compactMap { $0 as? OSLogEntryLog }
            .filter { $0.composedMessage.contains("Invalid frame dimension") }
        XCTAssertEqual(invalidFrames.count, 0, "The trend chart laid out views with negative or non-finite sizes")
    }

    private static func points(days: Int) -> [DashboardTrendPoint] {
        let start = Calendar.current.startOfDay(for: Date()).addingTimeInterval(-Double(days) * 86_400)
        return (0..<days).map { day in
            DashboardTrendPoint(
                dayStart: start.addingTimeInterval(Double(day) * 86_400),
                words: (day * 37) % 400 * (days == 7 ? 3 : 1),
                sessions: day % 9,
                averageWPM: 100 + day % 40
            )
        }
    }
}

private final class TrendModel: ObservableObject {
    @Published var points: [DashboardTrendPoint] = []
}

private struct TrendHost: View {
    @ObservedObject var model: TrendModel

    var body: some View {
        TrendCardView(points: model.points, showsLegend: true)
            .frame(width: 860)
    }
}
