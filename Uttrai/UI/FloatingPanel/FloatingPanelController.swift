// FloatingPanelController.swift
// Uttrai

import Cocoa
import SwiftUI
import os

final class FloatingPanelController {
    private var panel: NSPanel!
    private var hostingView: NSHostingView<AnyView>?

    init() {
        setupPanel()
    }

    private func setupPanel() {
        panel = NSPanel(
            contentRect: NSRect(
                x: 0, y: 0,
                width: WindowSize.floatingPanel.width,
                height: WindowSize.floatingPanel.height
            ),
            styleMask: [.nonactivatingPanel, .borderless, .hudWindow],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true

        // Background visual effect
        let visualEffect = NSVisualEffectView(frame: panel.contentView!.bounds)
        visualEffect.material = .hudWindow
        visualEffect.state = .active
        visualEffect.wantsLayer = true
        visualEffect.layer?.cornerRadius = CGFloat(CornerRadius.panel)
        visualEffect.layer?.masksToBounds = true
        visualEffect.autoresizingMask = [.width, .height]
        panel.contentView?.addSubview(visualEffect)
    }

    func show(near point: NSPoint? = nil) {
        let position = point ?? cursorPosition()
        let adjustedPosition = adjustForScreenBounds(position)

        panel.setFrameOrigin(adjustedPosition)
        panel.alphaValue = 0
        panel.orderFront(nil)

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 1
        }

        Logger.ui.info("Floating panel shown")
    }

    func dismiss() {
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.20
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            self?.panel.orderOut(nil)
        })
    }

    func updateContent<V: View>(_ view: V) {
        if let existing = hostingView {
            existing.removeFromSuperview()
        }

        let hosting = NSHostingView(rootView: AnyView(view))
        hosting.frame = panel.contentView!.bounds
        hosting.autoresizingMask = [.width, .height]
        panel.contentView?.addSubview(hosting)
        hostingView = hosting
    }

    // MARK: - Positioning

    private func cursorPosition() -> NSPoint {
        // Try AX cursor position first
        if let axPosition = axCursorPosition() {
            return NSPoint(x: axPosition.x, y: axPosition.y - 8 - WindowSize.floatingPanel.height)
        }

        // Fallback to mouse location
        let mouse = NSEvent.mouseLocation
        return NSPoint(x: mouse.x, y: mouse.y + 8)
    }

    private func axCursorPosition() -> NSPoint? {
        guard let frontApp = NSWorkspace.shared.frontmostApplication else { return nil }
        let appElement = AXUIElementCreateApplication(frontApp.processIdentifier)

        var focusedElement: AnyObject?
        let focusResult = AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &focusedElement)
        guard focusResult == .success, let element = focusedElement else { return nil }

        var positionValue: AnyObject?
        let posResult = AXUIElementCopyAttributeValue(element as! AXUIElement, kAXPositionAttribute as CFString, &positionValue)
        guard posResult == .success else { return nil }

        var point = CGPoint.zero
        AXValueGetValue(positionValue as! AXValue, .cgPoint, &point)

        return NSPoint(x: point.x, y: point.y)
    }

    private func adjustForScreenBounds(_ point: NSPoint) -> NSPoint {
        guard let screen = NSScreen.main else { return point }
        let frame = screen.visibleFrame
        var adjusted = point

        if adjusted.x + WindowSize.floatingPanel.width > frame.maxX {
            adjusted.x = frame.maxX - WindowSize.floatingPanel.width
        }
        if adjusted.x < frame.minX {
            adjusted.x = frame.minX
        }
        if adjusted.y < frame.minY {
            adjusted.y = frame.minY
        }
        if adjusted.y + WindowSize.floatingPanel.height > frame.maxY {
            adjusted.y = frame.maxY - WindowSize.floatingPanel.height
        }

        return adjusted
    }
}
