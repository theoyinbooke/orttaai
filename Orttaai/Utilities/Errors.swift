// Errors.swift
// Orttaai

import Foundation

enum OrttaaiError: LocalizedError {
    case modelNotLoaded
    case modelCorrupted
    case microphoneAccessDenied
    case accessibilityAccessDenied
    case inputMonitoringDenied
    case transcriptionFailed(underlying: Error)
    case insufficientDiskSpace
    case downloadFailed
    case intelMacDetected
    case outOfMemory
    case pasteFailed
    case secureTextField
    case recordingTooShort
    case noAudioInput
    case tapCreationFailed

    var errorDescription: String? {
        switch self {
        case .modelNotLoaded:
            return "No model installed"
        case .modelCorrupted:
            return "Model file is corrupted"
        case .microphoneAccessDenied:
            return "Microphone access needed"
        case .accessibilityAccessDenied:
            return "Accessibility access needed"
        case .inputMonitoringDenied:
            return "Input Monitoring access needed"
        case .transcriptionFailed(let underlying):
            return "Transcription failed: \(underlying.localizedDescription)"
        case .insufficientDiskSpace:
            return "Not enough disk space"
        case .downloadFailed:
            return "Model download failed"
        case .intelMacDetected:
            return "Orttaai requires Apple Silicon"
        case .outOfMemory:
            return "Not enough memory for transcription"
        case .pasteFailed:
            return "Could not paste text"
        case .secureTextField:
            return "Can't dictate into password fields"
        case .recordingTooShort:
            return "Recording too short"
        case .noAudioInput:
            return "No microphone detected"
        case .tapCreationFailed:
            return "Could not create event tap"
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .modelNotLoaded:
            return "Download a model in Settings > Model."
        case .modelCorrupted:
            return "Re-download the model in Settings > Model."
        case .microphoneAccessDenied:
            return "Grant Microphone access in System Settings > Privacy & Security > Microphone."
        case .accessibilityAccessDenied:
            return "Grant Accessibility access in System Settings > Privacy & Security > Accessibility."
        case .inputMonitoringDenied:
            return "Grant Input Monitoring access in System Settings > Privacy & Security > Input Monitoring."
        case .transcriptionFailed:
            return "Try again. If the problem persists, try a different model."
        case .insufficientDiskSpace:
            return "Free up disk space and try again."
        case .downloadFailed:
            return "Check your internet connection and try again."
        case .intelMacDetected:
            return "Orttaai requires a Mac with Apple Silicon (M1 or later)."
        case .outOfMemory:
            return "Close other apps or switch to a smaller model in Settings > Model."
        case .pasteFailed:
            return "Use Cmd+Shift+V to paste the last transcription."
        case .secureTextField:
            return "Move focus to a non-password field and try again."
        case .recordingTooShort:
            return "Hold the hotkey longer while speaking."
        case .noAudioInput:
            return "Connect a microphone and try again."
        case .tapCreationFailed:
            return "Restart Orttaai to activate the hotkey."
        }
    }
}
