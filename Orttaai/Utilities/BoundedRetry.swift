// BoundedRetry.swift
// Orttaai

import Foundation

/// Runs a throwing operation up to `attempts` times with a delay between
/// tries. Used for persistence writes that must not fail silently: the caller
/// gets a definitive success/failure instead of a swallowed `try?`.
enum BoundedRetry {
    struct Failure {
        let attempts: Int
        let lastError: Error
    }

    /// Returns nil on success, or details of the final failure after all
    /// attempts are exhausted. `sleep` is injectable for tests.
    @discardableResult
    static func run(
        attempts: Int,
        delayNs: UInt64,
        sleep: (UInt64) async -> Void = { try? await Task.sleep(nanoseconds: $0) },
        operation: () throws -> Void
    ) async -> Failure? {
        precondition(attempts >= 1, "BoundedRetry requires at least one attempt")
        var lastError: Error?
        for attempt in 1...attempts {
            do {
                try operation()
                return nil
            } catch {
                lastError = error
                if attempt < attempts {
                    await sleep(delayNs)
                }
            }
        }
        // lastError is always set when we reach this point.
        return Failure(attempts: attempts, lastError: lastError ?? CocoaError(.fileWriteUnknown))
    }
}
