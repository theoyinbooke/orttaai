// WindowManager.swift
// Orttaai

import Cocoa
import SwiftUI
import os

@MainActor
final class WindowManager {
    private var homeWindow: NSWindow?
    private var setupWindow: NSWindow?
    private let homeNavigation = HomeNavigationState()
    var onSetupCompleted: (() -> Void)?
    var onSetupReadyForTesting: (() -> Void)?
    var onHomeRunSetup: (() -> Void)?

    func showSetupWindow() {
        if let existing = setupWindow {
            Logger.ui.info("Showing existing setup window")
            centerAndShow(existing, recenter: false)
            return
        }

        let setupView = SetupView(
            onComplete: { [weak self] in
                AppSettings().hasCompletedSetup = true
                self?.closeSetupWindow()
                self?.onSetupCompleted?()
            },
            onReadyForTesting: { [weak self] in
                self?.onSetupReadyForTesting?()
            }
        )

        let window = createWindow(
            title: "Orttaai Setup",
            size: WindowSize.setup,
            resizable: false,
            content: setupView
        )
        setupWindow = window
        Logger.ui.info("Showing new setup window")
        centerAndShow(window, recenter: true)
    }

    func showHomeWindow(section: HomeSection = .overview) {
        homeNavigation.selectedSection = section

        if let existing = homeWindow {
            Logger.ui.info("Showing existing home window")
            centerAndShow(existing, recenter: false)
            return
        }

        let window = createWindow(
            title: "Orttaai Home",
            size: WindowSize.home,
            resizable: true,
            content: HomeShellView(
                navigation: homeNavigation,
                onRunSetup: { [weak self] in
                    self?.onHomeRunSetup?()
                }
            )
        )
        window.minSize = CGSize(width: 700, height: 520)
        homeWindow = window
        Logger.ui.info("Showing new home window")
        centerAndShow(window, recenter: true)
    }

    func closeSetupWindow() {
        setupWindow?.close()
        setupWindow = nil
    }

    func closeHomeWindow() {
        homeWindow?.close()
        homeWindow = nil
    }

    func isSetupWindowVisible() -> Bool {
        setupWindow?.isVisible == true
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
        window.backgroundColor = NSColor.Orttaai.bgPrimary
        window.isMovableByWindowBackground = true
        window.contentView = NSHostingView(rootView: content)
        window.isReleasedWhenClosed = false
        window.collectionBehavior.insert(.moveToActiveSpace)

        return window
    }

    private func centerAndShow(_ window: NSWindow, recenter: Bool) {
        if recenter {
            window.center()
        }
        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
        NSApp.unhide(nil)
        NSRunningApplication.current.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
        window.orderFrontRegardless()
        window.makeKeyAndOrderFront(nil)
        window.makeMain()
        NSApp.activate(ignoringOtherApps: true)

        // Some launch/reopen cycles can leave windows behind other apps; retry on next runloop.
        DispatchQueue.main.async { [weak window] in
            guard let window else { return }
            guard !window.isVisible || !window.isKeyWindow else { return }
            NSApp.unhide(nil)
            NSRunningApplication.current.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
            window.orderFrontRegardless()
            window.makeKeyAndOrderFront(nil)
        }
    }
}
