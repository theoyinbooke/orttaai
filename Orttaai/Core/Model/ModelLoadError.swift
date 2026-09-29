// ModelLoadError.swift
// Orttaai

import Foundation

/// Why a speech model could not be made ready without downloading anything.
/// Warm-up and dictation never start a multi-gigabyte download on their own,
/// so each of these is presented to the user instead of being worked around.
nonisolated enum ModelLoadError: LocalizedError, Equatable {
    /// Nothing on any readable model folder matches the requested build.
    case modelFilesNotFound(modelID: String)
    /// A model folder could not be read in time (unmounted or asleep drive, a
    /// folder-access prompt that has not been answered). The model may well
    /// exist there, so this is never treated as "the model is gone".
    case storageUnavailable
    /// The model is present but its tokenizer is not stored beside it, and
    /// loading would have to fetch it from the network.
    case tokenizerNotFound(modelID: String)

    var errorDescription: String? {
        switch self {
        case .modelFilesNotFound(let modelID):
            return "The speech model \(ModelManager.formatDisplayName(modelID)) is not on this Mac."
        case .storageUnavailable:
            return "Orttaai couldn't reach the folder that holds your speech models."
        case .tokenizerNotFound(let modelID):
            return "The tokenizer for \(ModelManager.formatDisplayName(modelID)) is missing next to the model."
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .modelFilesNotFound:
            return "Open Settings > Models to download it or choose another model."
        case .storageUnavailable:
            return "Reconnect the drive, or allow Orttaai to access the folder if macOS asks, then try again."
        case .tokenizerNotFound:
            return "Open Settings > Models and download the model again."
        }
    }

    /// Menu-bar status line shown when warm-up fails.
    var menuStatusLine: String {
        switch self {
        case .modelFilesNotFound:
            return "Model not found. Open Settings > Models"
        case .storageUnavailable:
            return "Model folder unavailable"
        case .tokenizerNotFound:
            return "Model incomplete. Open Settings > Models"
        }
    }

    /// Short pill message shown when a finished recording cannot be transcribed.
    var pillMessage: String {
        switch self {
        case .modelFilesNotFound:
            return "Model not found. Open Settings > Models."
        case .storageUnavailable:
            return "Model folder unavailable. Try again."
        case .tokenizerNotFound:
            return "Model incomplete. Open Settings > Models."
        }
    }
}
