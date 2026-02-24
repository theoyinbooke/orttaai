// Logger.swift
// Orttaai

import os

extension Logger {
    private static let subsystem = "com.orttaai.app"

    static let audio = Logger(subsystem: subsystem, category: "audio")
    static let transcription = Logger(subsystem: subsystem, category: "transcription")
    static let injection = Logger(subsystem: subsystem, category: "injection")
    static let hotkey = Logger(subsystem: subsystem, category: "hotkey")
    static let ui = Logger(subsystem: subsystem, category: "ui")
    static let database = Logger(subsystem: subsystem, category: "database")
    static let model = Logger(subsystem: subsystem, category: "model")
    static let dictation = Logger(subsystem: subsystem, category: "dictation")
}
