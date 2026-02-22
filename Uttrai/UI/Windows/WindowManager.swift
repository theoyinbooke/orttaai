// WindowManager.swift
// Uttrai

import Cocoa
import SwiftUI

final class WindowManager {
    private var setupWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var historyWindow: NSWindow?

    func showSetupWindow() {
        if let existing = setupWindow, existing.isVisible {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let setupView = SetupView(onComplete: { [weak self] in
            AppSettings().hasCompletedSetup = true
            self?.closeSetupWindow()
        })

        let window = createWindow(
            title: "Uttrai Setup",
            size: WindowSize.setup,
            resizable: false,
            content: setupView
        )
        setupWindow = window
        centerAndShow(window)
    }

    func showSettingsWindow() {
        if let existing = settingsWindow, existing.isVisible {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let window = createWindow(
            title: "Uttrai Settings",
            size: WindowSize.settings,
            resizable: false,
            content: SettingsView()
        )
        settingsWindow = window
        centerAndShow(window)
    }

    func showHistoryWindow() {
        if let existing = historyWindow, existing.isVisible {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let window = createWindow(
            title: "Uttrai History",
            size: WindowSize.history,
            resizable: true,
            content: HistoryView()
        )
        window.minSize = WindowSize.historyMin
        historyWindow = window
        centerAndShow(window)
    }

    func closeSetupWindow() {
        setupWindow?.close()
        setupWindow = nil
    }

    // MARK: - Private

    private func createWindow<Content: View>(
        title: String,
        size: CGSize,
        resizable: Bool,
        content: Content
    ) -> NSWindow {
        var styleMask: NSWindow.StyleMask = [.titled, .closable, .miniaturizable]
        if resizable {
            styleMask.insert(.resizable)
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: size.width, height: size.height),
            styleMask: styleMask,
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.backgroundColor = NSColor.Uttrai.bgPrimary
        window.isMovableByWindowBackground = true
        window.contentView = NSHostingView(rootView: content)
        window.isReleasedWhenClosed = false

        return window
    }

    private func centerAndShow(_ window: NSWindow) {
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
