// DictationNotifications.swift
// Orttaai

import Foundation

extension Notification.Name {
    static let dictationStateDidChange = Notification.Name("Orttaai.dictationStateDidChange")
    static let fastFirstUpgradeAvailabilityDidChange = Notification.Name("Orttaai.fastFirstUpgradeAvailabilityDidChange")
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
}
