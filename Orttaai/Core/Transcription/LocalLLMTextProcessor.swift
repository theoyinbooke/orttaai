// LocalLLMTextProcessor.swift
// Orttaai

import Foundation
import os

final class LocalLLMTextProcessor: TextProcessor {
    private actor CircuitBreaker {
        private var timeoutCount: Int = 0
        private var cooldownUntil: Date = .distantPast

        func canAttempt(now: Date = Date()) -> Bool {
            now >= cooldownUntil
        }

        func recordSuccess() {
            timeoutCount = 0
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
    }

    private let baseProcessor: TextProcessor
    private let settings: AppSettings
    private let ollamaClient: OllamaClient
    private let circuitBreaker = CircuitBreaker()

    init(
        baseProcessor: TextProcessor,
        settings: AppSettings,
        ollamaClient: OllamaClient = OllamaClient()
    ) {
        self.baseProcessor = baseProcessor
        self.settings = settings
        self.ollamaClient = ollamaClient
    }

    func process(_ input: TextProcessorInput) async throws -> TextProcessorOutput {
        let baseOutput = try await baseProcessor.process(input)

        guard settings.localLLMPolishEnabled else {
            return baseOutput
        }

        let normalizedInput = baseOutput.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalizedInput.count >= 8 else {
            return baseOutput
        }

        let maxChars = settings.clampedLocalLLMPolishMaxChars
        guard normalizedInput.count <= maxChars else {
            Logger.ai.debug("Skipping local polish (text too long: \(normalizedInput.count) > \(maxChars))")
            return baseOutput
        }

        let model = settings.normalizedLocalLLMPolishModel
        guard !model.isEmpty else {
            Logger.ai.debug("Skipping local polish (missing local LLM model setting)")
            return baseOutput
        }

        guard await circuitBreaker.canAttempt() else {
            return baseOutput
        }

        let prompt = makePolishPrompt(text: normalizedInput, targetApp: input.targetApp)
        let requestedTimeoutMs = settings.clampedLocalLLMPolishTimeoutMs
        let timeoutMs = effectiveTimeoutMs(
            requestedTimeoutMs: requestedTimeoutMs,
            model: model
        )
        if timeoutMs != requestedTimeoutMs {
            Logger.ai.debug("Local polish timeout adjusted for model [model=\(model), requestedMs=\(requestedTimeoutMs), effectiveMs=\(timeoutMs)]")
        }
        let startedAt = Date()
        Logger.ai.debug("Local polish request started [model=\(model), chars=\(normalizedInput.count), timeoutMs=\(timeoutMs)]")

        do {
            let rawResponse = try await ollamaClient.generate(
                baseURLString: settings.normalizedLocalLLMEndpoint,
                model: model,
                prompt: prompt,
                timeoutMs: timeoutMs,
                think: false,
                temperature: 0,
                numPredict: max(24, min(120, (normalizedInput.count / 2) + 24))
            )

            guard let polishedText = sanitizePolishOutput(rawResponse, original: normalizedInput) else {
                Logger.ai.debug("Skipping local polish (response rejected by sanitizer)")
                await circuitBreaker.recordFailure()
                return baseOutput
            }

            guard polishedText != normalizedInput else {
                await circuitBreaker.recordSuccess()
                let elapsedMs = Int(Date().timeIntervalSince(startedAt) * 1_000)
                Logger.ai.debug("Local polish completed with no edits [model=\(model), elapsedMs=\(elapsedMs)]")
                return baseOutput
            }

            await circuitBreaker.recordSuccess()
            let elapsedMs = Int(Date().timeIntervalSince(startedAt) * 1_000)
            Logger.ai.debug("Local polish applied [model=\(model), elapsedMs=\(elapsedMs)]")
            var updatedChanges = baseOutput.changes
            updatedChanges.append("Local LLM polish applied (punctuation/spelling)")
            return TextProcessorOutput(text: polishedText, changes: updatedChanges)
        } catch {
            if isTimeoutError(error) {
                await circuitBreaker.recordTimeout()
                warmModelInBackground(endpoint: settings.normalizedLocalLLMEndpoint, model: model)
                let suggestedTimeoutMs = max(timeoutMs, recommendedMinimumTimeoutMs(for: model))
                Logger.ai.debug("Local polish timed out at \(timeoutMs)ms for model \(model). Increase polish timeout to ~\(suggestedTimeoutMs)ms+ for this model.")
            } else {
                await circuitBreaker.recordFailure()
            }
            let elapsedMs = Int(Date().timeIntervalSince(startedAt) * 1_000)
            Logger.ai.debug("Local polish failed [model=\(model), elapsedMs=\(elapsedMs)]")
            Logger.ai.debug("Local polish unavailable: \(error.localizedDescription)")
            return baseOutput
        }
    }

    func isAvailable() -> Bool {
        baseProcessor.isAvailable()
    }

    private func makePolishPrompt(text: String, targetApp: String?) -> String {
        let appContext = targetApp?.trimmingCharacters(in: .whitespacesAndNewlines)
        let contextLine: String
        if let appContext, !appContext.isEmpty {
            contextLine = "Target app context: \(appContext)"
        } else {
            contextLine = "Target app context: unknown"
        }

        return """
        Return ONLY corrected transcript text.
        Keep meaning and wording.
        Fix punctuation, capitalization, spacing, obvious spelling.
        No markdown, no quotes, no explanations.

        \(contextLine)

        Transcript:
        \(text)
        """
    }

    private func isTimeoutError(_ error: Error) -> Bool {
        if let urlError = error as? URLError {
            return urlError.code == .timedOut
        }
        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorTimedOut
    }

    private func effectiveTimeoutMs(requestedTimeoutMs: Int, model: String) -> Int {
        max(requestedTimeoutMs, recommendedMinimumTimeoutMs(for: model))
    }

    private func recommendedMinimumTimeoutMs(for model: String) -> Int {
        let lower = model.lowercased()
        if lower.contains("qwen3.5:0.8b") { return 1_300 }
        if lower.contains("qwen3.5:2b") { return 1_400 }
        if lower.contains("qwen3.5:4b") { return 1_500 }
        return 600
    }

    private func warmModelInBackground(endpoint: String, model: String) {
        let warmPrompt = "Fix punctuation only: hello world"
        Task {
            _ = try? await ollamaClient.generate(
                baseURLString: endpoint,
                model: model,
                prompt: warmPrompt,
                timeoutMs: 1_400,
                think: false,
                temperature: 0,
                numPredict: 24
            )
        }
    }

    private func sanitizePolishOutput(_ candidate: String, original: String) -> String? {
        var value = candidate
            .replacingOccurrences(of: "\r\n", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if value.hasPrefix("```") {
            value = value.replacingOccurrences(of: "```", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let lower = value.lowercased()
        let knownPreambles = [
            "corrected transcript:",
            "corrected text:",
            "revised transcript:",
            "revised text:"
        ]
        for preamble in knownPreambles where lower.hasPrefix(preamble) {
            value = String(value.dropFirst(preamble.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            break
        }

        guard !value.isEmpty else { return nil }

        let originalCount = max(1, original.count)
        let minAllowed = Int(Double(originalCount) * 0.55)
        let maxAllowed = Int(Double(originalCount) * 1.8) + 24
        guard value.count >= minAllowed, value.count <= maxAllowed else {
            return nil
        }

        return value
    }
}
