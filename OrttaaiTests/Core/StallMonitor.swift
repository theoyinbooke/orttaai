// StallMonitor.swift
// OrttaaiTests

import Foundation

/// How long the main thread was busy at a stretch, from the gaps between
/// ticks of a 1 ms main-thread timer. For the opt-in measure tests.
@MainActor
final class StallMonitor {
    private var timer: Timer?
    private var last = ContinuousClock.now
    private(set) var longest: Duration = .zero
    /// Every stretch longer than a 60 Hz frame, in order.
    private(set) var stalls: [Duration] = []

    func start() {
        last = .now
        timer = Timer.scheduledTimer(withTimeInterval: 0.001, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    func reset() {
        last = .now
        longest = .zero
        stalls = []
    }

    func stop() {
        timer?.invalidate()
    }

    private func tick() {
        let now = ContinuousClock.now
        let gap = last.duration(to: now)
        longest = max(longest, gap)
        if gap > .milliseconds(16) {
            stalls.append(gap)
        }
        last = now
    }

    static func ms(_ duration: Duration) -> Int {
        Int(duration.components.seconds * 1_000 + duration.components.attoseconds / 1_000_000_000_000_000)
    }
}
