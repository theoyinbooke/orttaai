// HomeRefreshMeasureTests.swift
// OrttaaiTests

import GRDB
import XCTest
@testable import Orttaai

/// Opt-in measurement on a copy of a real database: run with
/// TEST_RUNNER_HOME_MEASURE_DB set to the copy. Reports how long the main
/// thread stalls while Home opens, refreshes, and takes in a new and a
/// deleted dictation, in <copy>.measure.txt because xcodebuild doesn't pass
/// a test's output on. Timings only, never dictation text; each round adds
/// one made-up dictation to the copy and deletes it again.
@MainActor
final class HomeRefreshMeasureTests: XCTestCase {
    private var report: [String] = []
    private let monitor = StallMonitor()

    func testMeasureMainThreadStalls() async throws {
        guard let path = ProcessInfo.processInfo.environment["HOME_MEASURE_DB"] else {
            throw XCTSkip("Set HOME_MEASURE_DB to a copy of orttaai.db")
        }
        defer { try? report.joined(separator: "\n").write(toFile: path + ".measure.txt", atomically: true, encoding: .utf8) }
        // Home weighs the star prompt after loading, which writes these.
        let promptKeys = ["githubStarPromptCompleted", "githubStarPromptShownCount", "githubStarPromptLastShownAtEpoch"]
        let savedPromptValues = promptKeys.map { UserDefaults.standard.object(forKey: $0) }
        defer {
            for (key, value) in zip(promptKeys, savedPromptValues) {
                UserDefaults.standard.set(value, forKey: key)
            }
        }

        let queue = try DatabaseQueue(path: path)
        let db = try DatabaseManager(dbQueue: queue)
        monitor.start()
        defer { monitor.stop() }

        weak var previousViewModel: HomeViewModel?
        for round in 1...3 {
            if previousViewModel != nil {
                report.append("round \(round): the last round's view model is still alive")
            }
            // Each visit to Home makes a new view model.
            let viewModel = HomeViewModel(statsService: DashboardStatsService(databaseManager: db), insightsService: nil, settings: AppSettings())
            previousViewModel = viewModel

            try await measure("round \(round), open", viewModel, until: { viewModel.hasLoaded }) {
                viewModel.load()
            }
            try await measure("round \(round), Refresh", viewModel, until: { !viewModel.isLoading }) {
                viewModel.refresh()
            }
            let sessionsToday = viewModel.payload.today.sessions
            var newID: Int64 = 0
            var pauseOverrun: Duration = .zero
            try await measure("round \(round), new dictation", viewModel, until: { viewModel.payload.today.sessions == sessionsToday + 1 }) {
                // As DictationCoordinator does: save the text, type it, then
                // note the delivery on the saved row.
                newID = try db.saveTranscriptionEntry(text: "one two three four five", appName: "Measure", bundleID: nil, recordingMs: 2_000, processingMs: 300, modelId: "measure", audioDevice: nil, rawText: nil, latency: Self.noLatency, injectionMethod: nil)
                let pauseStarted = ContinuousClock.now
                try await Task.sleep(for: .milliseconds(120))
                pauseOverrun = pauseStarted.duration(to: .now) - .milliseconds(120)
                try db.completeTranscriptionEntry(id: newID, processingMs: 500, latency: Self.noLatency, injectionMethod: "paste")
            }
            report.append("round \(round), new dictation: a 120 ms wait right after the save, as before pasting, ended \(StallMonitor.ms(pauseOverrun)) ms late")
            try await measure("round \(round), delete it", viewModel, until: { !viewModel.payload.recent.contains { $0.id == newID } }) {
                viewModel.deleteRecentDictation(id: newID)
            }
            report.append("round \(round): \(viewModel.payload.header.activeDays) active days shown")
        }
    }

    private func measure(
        _ label: String,
        _ viewModel: HomeViewModel,
        until isShown: @escaping () -> Bool,
        _ action: () async throws -> Void
    ) async throws {
        try await Task.sleep(for: .milliseconds(300))
        monitor.reset()
        let started = ContinuousClock.now
        let shownAt = Task { @MainActor () -> ContinuousClock.Instant? in
            while !isShown() {
                guard started.duration(to: .now) < .seconds(10) else { return nil }
                try? await Task.sleep(for: .milliseconds(1))
            }
            return .now
        }
        try await action()
        let call = started.duration(to: .now)
        guard let shown = await shownAt.value.map({ started.duration(to: $0) }) else {
            report.append("\(label): never shown")
            return
        }
        // Long enough for refreshes the change set off after it first showed
        // (the database observation's) to run and finish.
        try await Task.sleep(for: .milliseconds(800))
        while viewModel.isLoading {
            try await Task.sleep(for: .milliseconds(1))
        }
        let stalls = monitor.stalls.map { "\(StallMonitor.ms($0))" }.joined(separator: ", ")
        report.append("\(label): call \(StallMonitor.ms(call)) ms, shown after \(StallMonitor.ms(shown)) ms, main-thread stalls over 16 ms: [\(stalls)], longest \(StallMonitor.ms(monitor.longest)) ms")
    }

    private static let noLatency = DictationLatencyTelemetry(
        settingsSyncMs: nil,
        transcriptionMs: nil,
        textProcessingMs: nil,
        injectionMs: nil,
        appActivationMs: nil,
        clipboardRestoreDelayMs: nil
    )
}

