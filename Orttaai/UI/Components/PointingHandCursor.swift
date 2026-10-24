// PointingHandCursor.swift
// Orttaai

import AppKit
import SwiftUI

extension View {
    /// The hand pointer over a control that can be clicked, and the arrow
    /// over one that can't. Saying so explicitly matters next to a text
    /// view, whose I-beam otherwise lingers over buttons.
    @ViewBuilder
    func pointingHandCursor(when enabled: Bool = true) -> some View {
        if #available(macOS 15, *) {
            pointerStyle(enabled ? .link : .default)
        } else {
            modifier(LegacyPointingHand(enabled: enabled))
        }
    }

    /// The hand pointer even while Orttaai is not the active app, for
    /// controls in a panel shown over another app (the milestone toast),
    /// where the usual cursor handling only runs for the active app.
    func pointingHandCursorWhileInactive() -> some View {
        background(AlwaysPointingHandArea())
    }
}

/// macOS 14 has no `pointerStyle`; push the cursor while hovered.
private struct LegacyPointingHand: ViewModifier {
    let enabled: Bool
    @State private var pushed = false

    func body(content: Content) -> some View {
        content.onHover { inside in
            if inside, !pushed {
                (enabled ? NSCursor.pointingHand : NSCursor.arrow).push()
                pushed = true
            } else if !inside, pushed {
                NSCursor.pop()
                pushed = false
            }
        }
    }
}

private struct AlwaysPointingHandArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { HandTrackingView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class HandTrackingView: NSView {
        private var area: NSTrackingArea?

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let area { removeTrackingArea(area) }
            let area = NSTrackingArea(
                rect: bounds,
                options: [.activeAlways, .cursorUpdate, .mouseEnteredAndExited, .inVisibleRect],
                owner: self
            )
            addTrackingArea(area)
            self.area = area
        }

        override func cursorUpdate(with event: NSEvent) { NSCursor.pointingHand.set() }
        override func mouseEntered(with event: NSEvent) { NSCursor.pointingHand.set() }
        override func mouseExited(with event: NSEvent) { NSCursor.arrow.set() }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
