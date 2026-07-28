// LLMCircuitBreaker.swift
// Orttaai

import Foundation

/// Shared backoff policy for local LLM hot paths (dictation polish, voice
/// edit commands). Extracted from LocalLLMTextProcessor so every feature that
/// dials the local provider shares one failure-handling contract instead of
/// duplicating it.
actor LLMCircuitBreaker {
    private var timeoutCount: Int = 0
    private var unreachableCount: Int = 0
    private var cooldownUntil: Date = .distantPast

    func canAttempt(now: Date = Date()) -> Bool {
        now >= cooldownUntil
    }

    func recordSuccess() {
        timeoutCount = 0
        unreachableCount = 0
        cooldownUntil = .distantPast
    }

    func recordTimeout(now: Date = Date()) {
        timeoutCount += 1
        let backoffSeconds = min(20.0, pow(2.0, Double(max(0, timeoutCount - 1))) * 1.2)
        cooldownUntil = now.addingTimeInterval(backoffSeconds)
    }

    func recordFailure(now: Date = Date()) {
        // Short cooldown prevents repeated failed requests from adding latency.
        cooldownUntil = now.addingTimeInterval(5.0)
    }

    /// No local provider is listening (connection refused / host down).
    /// With polish enabled by default, most such users simply don't run
    /// Ollama — back off long and escalate so dictation never keeps
    /// re-dialing a dead port. The failed connect itself is the fast
    /// reachability check (loopback refusal is sub-millisecond).
    func recordUnreachable(now: Date = Date()) {
        unreachableCount += 1
        let backoffSeconds = min(600.0, pow(2.0, Double(max(0, unreachableCount - 1))) * 60.0)
        cooldownUntil = now.addingTimeInterval(backoffSeconds)
    }
}

/// Classifies local-LLM request errors so callers can pick the right
/// circuit-breaker action. Mirrors the long-standing LocalLLMTextProcessor
/// behavior; extracted for reuse by the edit-command path.
enum LLMRequestErrorClassifier {
    static func isTimeoutError(_ error: Error) -> Bool {
        if let urlError = error as? URLError {
            return urlError.code == .timedOut
        }
        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorTimedOut
    }

    /// The provider is up but the configured model isn't installed (Ollama
    /// answers 404 for unknown models).
    static func isModelMissingError(_ error: Error) -> Bool {
        if case OllamaClientError.httpError(let status, _) = error {
            return status == 404
        }
        return false
    }

    /// Connection-level failures that mean no provider is listening at all,
    /// as opposed to a provider that is up but slow or erroring.
    static func isUnreachableError(_ error: Error) -> Bool {
        let unreachableCodes: [URLError.Code] = [
            .cannotConnectToHost,
            .cannotFindHost,
            .networkConnectionLost,
            .notConnectedToInternet,
        ]
        if let urlError = error as? URLError {
            return unreachableCodes.contains(urlError.code)
        }
        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain
            && unreachableCodes.map(\.rawValue).contains(nsError.code)
    }
}
