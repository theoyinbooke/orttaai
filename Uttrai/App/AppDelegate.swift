// AppDelegate.swift
// Uttrai

import Cocoa
import os

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var statusBarController: StatusBarController?
    private var statusBarMenu: StatusBarMenu?
    private var windowManager: WindowManager?
    private var appState: AppState?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Create status bar item
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        if let button = statusItem.button {
            let image = NSImage(systemSymbolName: "waveform.circle", accessibilityDescription: "Uttrai")
            image?.isTemplate = true
            button.image = image
        }

        // Initialize app state
        let state = AppState()
        appState = state

        // Set up status bar
        statusBarController = StatusBarController(statusItem: statusItem)
        statusBarMenu = StatusBarMenu()
        windowManager = WindowManager()

        statusBarMenu?.onHistoryAction = { [weak self] in
            self?.windowManager?.showHistoryWindow()
        }
        statusBarMenu?.onSettingsAction = { [weak self] in
            self?.windowManager?.showSettingsWindow()
        }
        statusBarMenu?.onQuitAction = {
            NSApplication.shared.terminate(nil)
        }

        statusItem.menu = statusBarMenu?.menu

        // Check if setup is needed
        if !state.settings.hasCompletedSetup {
            windowManager?.showSetupWindow()
        }

        Logger.ui.info("App launched, setup complete: \(state.settings.hasCompletedSetup)")
    }
}
