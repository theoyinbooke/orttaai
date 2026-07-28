// DictationNotifications.swift
// Orttaai

import Foundation

extension Notification.Name {
    static let dictationStateDidChange = Notification.Name("Orttaai.dictationStateDidChange")
    static let fastFirstUpgradeAvailabilityDidChange = Notification.Name("Orttaai.fastFirstUpgradeAvailabilityDidChange")
    static let audioPipelineResetRequested = Notification.Name("Orttaai.audioPipelineResetRequested")
    static let audioPipelineResetDidComplete = Notification.Name("Orttaai.audioPipelineResetDidComplete")
    static let cloudSyncDidComplete = Notification.Name("Orttaai.cloudSyncDidComplete")
    /// Posted after a transcription history write exhausted its bounded
    /// retries. The transcript itself was already delivered (or left on the
    /// clipboard) — this is the user-visible breadcrumb for the lost entry.
    static let transcriptionHistorySaveDidFail = Notification.Name("Orttaai.transcriptionHistorySaveDidFail")
}

enum DictationStateSignal: String {
    case idle
    case recording
    case processing
    case injecting
    case error
}

enum DictationNotificationKey {
    static let state = "state"
    static let message = "message"
    static let targetAppName = "targetAppName"
    static let countdownSeconds = "countdownSeconds"
    static let elapsedRecordingSeconds = "elapsedRecordingSeconds"
    static let audioLevel = "audioLevel"
}

enum AudioPipelineResetNotificationKey {
    static let success = "success"
    static let message = "message"
}
