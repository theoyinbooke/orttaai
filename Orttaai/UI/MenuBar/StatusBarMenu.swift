// StatusBarMenu.swift
// Orttaai

import Cocoa

final class StatusBarMenu {
    let menu: NSMenu
    private var statusItem: NSMenuItem!
    private var polishModeItem: NSMenuItem!
    private var homeItem: NSMenuItem!

    var onHomeAction: (() -> Void)?
    var onHistoryAction: (() -> Void)?
    var onSetupAction: (() -> Void)?
    var onSettingsAction: (() -> Void)?
    var onCheckForUpdatesAction: (() -> Void)?
    var onQuitAction: (() -> Void)?
    var onPolishModeToggle: (() -> Void)?

    init() {
        menu = NSMenu()
        buildMenu()
    }

    func updateStatusLine(_ text: String) {
        statusItem.title = text
    }

    func setHomePreviewMode(_ isPreview: Bool) {
        homeItem.title = isPreview ? "Home (Preview)" : "Home"
    }

    /// Reflects the polish setting in the menu; the checkmark is the single
    /// visible truth for whether dictation output gets the local LLM polish.
    func updatePolishMode(isOn: Bool) {
        polishModeItem.state = isOn ? .on : .off
    }

    // MARK: - Private

    private func buildMenu() {
        // Status line
        statusItem = NSMenuItem(title: "Ready", action: nil, keyEquivalent: "")
        statusItem.isEnabled = false
        menu.addItem(statusItem)

        menu.addItem(NSMenuItem.separator())

        // Polish Mode — toggles the local LLM polish pass on dictation output.
        polishModeItem = NSMenuItem(title: "Polish Mode", action: #selector(polishModeAction), keyEquivalent: "")
        polishModeItem.target = self
        polishModeItem.toolTip = "Clean up punctuation, capitalization, and filler words with the on-device model."
        menu.addItem(polishModeItem)

        // Home
        homeItem = NSMenuItem(title: "Home", action: #selector(homeAction), keyEquivalent: "")
        homeItem.target = self
        menu.addItem(homeItem)

        // Analytics
        let historyItem = NSMenuItem(title: "Analytics", action: #selector(historyAction), keyEquivalent: "")
        historyItem.target = self
        menu.addItem(historyItem)

        menu.addItem(NSMenuItem.separator())

        // Setup
        let setupItem = NSMenuItem(title: "Run Setup...", action: #selector(setupAction), keyEquivalent: "")
        setupItem.target = self
        menu.addItem(setupItem)

        // Settings
        let settingsItem = NSMenuItem(title: "Settings...", action: #selector(settingsAction), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        // Check for Updates / Homebrew managed
        if Bundle.main.isHomebrewInstall {
            let updateItem = NSMenuItem(title: "Updates managed by Homebrew", action: nil, keyEquivalent: "")
            updateItem.isEnabled = false
            menu.addItem(updateItem)
        } else {
            let updateItem = NSMenuItem(title: "Check for Updates...", action: #selector(checkForUpdatesAction), keyEquivalent: "")
            updateItem.target = self
            menu.addItem(updateItem)
        }

        menu.addItem(NSMenuItem.separator())

        // Quit
        let quitItem = NSMenuItem(title: "Quit Orttaai", action: #selector(quitAction), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
    }

    @objc private func polishModeAction() {
        onPolishModeToggle?()
    }

    @objc private func historyAction() {
        onHistoryAction?()
    }

    @objc private func homeAction() {
        onHomeAction?()
    }

    @objc private func setupAction() {
        onSetupAction?()
    }

    @objc private func settingsAction() {
        onSettingsAction?()
    }

    @objc private func checkForUpdatesAction() {
        onCheckForUpdatesAction?()
    }

    @objc private func quitAction() {
        onQuitAction?()
    }
}
