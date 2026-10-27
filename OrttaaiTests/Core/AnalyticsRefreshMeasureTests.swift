// AnalyticsRefreshMeasureTests.swift
// OrttaaiTests

import XCTest
import GRDB
@testable import Orttaai

/// Opt-in measurement on a copy of a real database: run with
/// TEST_RUNNER_ANALYTICS_MEASURE_DB set to the copy. Reports how long the main
/// thread stalls while the dashboard opens and switches device and range.
/// Prints timings only, never dictation text.
@MainActor
final class AnalyticsRefreshMeasureTests: XCTestCase {
    func testMeasureMainThreadStalls() async throws {
        guard let path = ProcessInfo.processInfo.environment["ANALYTICS_MEASURE_DB"] else {
            throw XCTSkip("Set ANALYTICS_MEASURE_DB to a copy of orttaai.db")
        }
        let db = try DatabaseManager(dbQueue: try DatabaseQueue(path: path))
        let viewModel = AnalyticsDashboardViewModel(settings: AppSettings(), makeDatabase: { db })
        var report: [String] = []
        defer { try? report.joined(separator: "\n").write(toFile: path + ".measure.txt", atomically: true, encoding: .utf8) }
        let monitor = StallMonitor()
        monitor.start()
        defer { monitor.stop() }

        let steps: [(String, () -> Void)] = [
            ("open, 30 days", { viewModel.load() }),
            ("This Mac", { viewModel.setDeviceFilter(.thisMac) }),
            ("iPhone", { viewModel.setDeviceFilter(.iphone) }),
            ("all devices", { viewModel.setDeviceFilter(.all) }),
            ("90 days", { viewModel.setSelectedRange(.ninetyDays) }),
            ("all time", { viewModel.setSelectedRange(.allTime) }),
            ("30 days", { viewModel.setSelectedRange(.thirtyDays) }),
        ]
        for round in 1...2 {
            for (label, action) in steps {
                try await Task.sleep(for: .milliseconds(200))
                monitor.reset()
                let started = ContinuousClock.now
                action()
                let call = started.duration(to: .now)
                await viewModel.waitForRefresh()
                let shown = started.duration(to: .now)
                try await Task.sleep(for: .milliseconds(100))
                report.append("round \(round), \(label): longest main-thread stall \(StallMonitor.ms(monitor.longest)) ms, call \(StallMonitor.ms(call)) ms, shown after \(StallMonitor.ms(shown)) ms, \(viewModel.totalSessions) dictations")
            }
            viewModel.setDeviceFilter(.all)
            viewModel.setSelectedRange(.thirtyDays)
            await viewModel.waitForRefresh()
        }
    }
}
