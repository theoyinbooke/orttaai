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

    // MARK: - Private

    private func buildMenu() {
        // Status line
        statusItem = NSMenuItem(title: "Ready", action: nil, keyEquivalent: "")
        statusItem.isEnabled = false
        menu.addItem(statusItem)

        menu.addItem(NSMenuItem.separator())

        // Polish Mode (disabled for v1.0)
        polishModeItem = NSMenuItem(title: "Polish Mode", action: nil, keyEquivalent: "")
        polishModeItem.isEnabled = false
        let subtitleAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.tertiaryLabelColor
        ]
        // Add subtitle via attributed title
        let fullTitle = NSMutableAttributedString(string: "Polish Mode")
        fullTitle.append(NSAttributedString(string: "\n"))
        fullTitle.append(NSAttributedString(string: "Coming soon", attributes: subtitleAttributes))
        polishModeItem.attributedTitle = fullTitle
        menu.addItem(polishModeItem)

        // Home
        homeItem = NSMenuItem(title: "Home", action: #selector(homeAction), keyEquivalent: "")
        homeItem.target = self
        menu.addItem(homeItem)

        // History
        let historyItem = NSMenuItem(title: "History", action: #selector(historyAction), keyEquivalent: "")
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
