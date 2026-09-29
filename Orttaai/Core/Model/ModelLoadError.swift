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

    var errorDescription: String? {
        switch self {
        case .modelFilesNotFound(let modelID):
            return "The speech model \(ModelManager.formatDisplayName(modelID)) is not on this Mac."
        case .storageUnavailable:
            return "Orttaai couldn't reach the folder that holds your speech models."
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .modelFilesNotFound:
            return "Open Settings > Models to download it or choose another model."
        case .storageUnavailable:
            return "Reconnect the drive, or allow Orttaai to access the folder if macOS asks, then try again."
        }
    }

    /// Menu-bar status line shown when warm-up fails.
    var menuStatusLine: String {
        switch self {
        case .modelFilesNotFound:
            return "Model not found. Open Settings > Models"
        case .storageUnavailable:
            return "Model folder unavailable"
        }
    }

    /// Short pill message shown when a finished recording cannot be transcribed.
    /// The pill is 200pt wide: keep these under ~26 characters.
    var pillMessage: String {
        switch self {
        case .modelFilesNotFound:
            return "Model not found"
        case .storageUnavailable:
            return "Model folder unavailable"
        }
    }
}
