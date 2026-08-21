// ModelStorageFolderPicker.swift
// Orttaai

import AppKit

@MainActor
enum ModelStorageFolderPicker {
    static func chooseFolder(startingAt currentURL: URL?) -> URL? {
        let panel = NSOpenPanel()
        panel.title = "Choose Model Storage Location"
        panel.message = "Choose where OrttaAI stores future WhisperKit downloads. Compatible models already in this folder will be reused."
        panel.prompt = "Use This Folder"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        if let currentURL {
            panel.directoryURL = currentURL
        }
        return panel.runModal() == .OK ? panel.url : nil
    }
}
