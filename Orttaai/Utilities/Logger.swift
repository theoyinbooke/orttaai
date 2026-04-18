// Logger.swift
// Orttaai

import os

extension Logger {
    nonisolated private static let subsystem = "com.orttaai.app"

    nonisolated static let audio = Logger(subsystem: subsystem, category: "audio")
    nonisolated static let transcription = Logger(subsystem: subsystem, category: "transcription")
    nonisolated static let injection = Logger(subsystem: subsystem, category: "injection")
    nonisolated static let hotkey = Logger(subsystem: subsystem, category: "hotkey")
    nonisolated static let ui = Logger(subsystem: subsystem, category: "ui")
    nonisolated static let database = Logger(subsystem: subsystem, category: "database")
    nonisolated static let model = Logger(subsystem: subsystem, category: "model")
    nonisolated static let dictation = Logger(subsystem: subsystem, category: "dictation")
    nonisolated static let memory = Logger(subsystem: subsystem, category: "memory")
    nonisolated static let ai = Logger(subsystem: subsystem, category: "ai")
}
