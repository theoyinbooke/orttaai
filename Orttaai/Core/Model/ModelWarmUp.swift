// ModelWarmUp.swift
// Orttaai

import Foundation
import os

enum ModelWarmUpOutcome: Equatable {
    case ready(modelID: String)
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
        do {
            let selectedModelID = settings.applyLanguageOptimizedSmallModelSelection()
            await settings.syncTranscriptionSettings(to: transcription)
            try await transcription.loadModel(named: selectedModelID)
            await warmUp()
            let runtimeModelID = await transcription.loadedModelID() ?? selectedModelID
            settings.activeModelId = runtimeModelID
            return .ready(modelID: runtimeModelID)
        } catch {
            Logger.model.error("Model warm-up failed: \(error.localizedDescription)")
            return .failed(statusLine: statusLine(for: error))
        }
    }

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
