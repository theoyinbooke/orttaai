// ModelWarmUp.swift
// Orttaai

import Foundation
import os

enum ModelWarmUpOutcome: Equatable {
    case ready(modelID: String)
    /// Express is on but could not load; the Whisper model loaded instead.
    /// `statusLine` says so in the menu bar.
    case readyWithoutExpress(modelID: String, statusLine: String)
    /// `statusLine` is what the menu bar shows.
    case failed(statusLine: String)
}

/// Loads and warms the selected speech model at launch.
enum ModelWarmUp {
    /// A failed warm-up never touches `activeModelId`. The failures are mostly
    /// transient (an unmounted drive, an unanswered folder-access prompt) or
    /// leave the model on disk untouched, and clearing the id would forget the
    /// user's model until the next successful load. The failure is reported as
    /// a status line instead, and the first dictation retries the load.
    static func perform(
        settings: AppSettings,
        transcription: any Transcribing,
        warmUp: @Sendable () async -> Void
    ) async -> ModelWarmUpOutcome {
        let selectedModelID = settings.applyLanguageOptimizedSmallModelSelection()
        await settings.syncTranscriptionSettings(to: transcription)

        var expressFailed = false
        if settings.isExpressEngineActive {
            do {
                try await transcription.loadModel(named: ExpressEngine.modelID)
                await warmUp()
                return .ready(modelID: ExpressEngine.modelID)
            } catch {
                // Dictation must still work: fall back to the Whisper model.
                Logger.model.error("Express warm-up failed, using Whisper: \(error.localizedDescription)")
                expressFailed = true
            }
        }

        do {
            try await transcription.loadModel(named: selectedModelID)
            await warmUp()
            let runtimeModelID = await transcription.loadedModelID() ?? selectedModelID
            settings.recordLoadedModel(runtimeModelID)
            return expressFailed
                ? .readyWithoutExpress(modelID: runtimeModelID, statusLine: expressFallbackStatusLine)
                : .ready(modelID: runtimeModelID)
        } catch {
            Logger.model.error("Model warm-up failed: \(error.localizedDescription)")
            return .failed(statusLine: statusLine(for: error))
        }
    }

    static let expressFallbackStatusLine = "Express unavailable. Using Whisper"

    static func statusLine(for error: Error) -> String {
        if let loadError = error as? ModelLoadError {
            return loadError.menuStatusLine
        }
        if error is ModelStorageLocationError {
            return "Model folder unavailable"
        }
        return "Model not loaded"
    }
}
