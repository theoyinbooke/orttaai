// DictationNotifications.swift
// Orttaai

import Foundation

extension Notification.Name {
    static let dictationStateDidChange = Notification.Name("Orttaai.dictationStateDidChange")
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
