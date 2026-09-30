// MenuBarIconRenderer.swift
// Orttaai

import Cocoa

final class MenuBarIconRenderer {
    enum IconState {
        case idle
        case recording
        case processing
        case downloading(progress: Double)
        case error
    }

    static func renderIcon(for state: IconState, size: NSSize = NSSize(width: 18, height: 18)) -> NSImage {
        let image = NSImage(size: size, flipped: true) { rect in
            let scale = min(rect.width, rect.height) / 18
            let inset: CGFloat
            switch state {
            case .downloading: inset = 4 * scale
            case .idle, .recording, .processing, .error: inset = scale
            }

            NSColor.white.setFill()
            NSBezierPath(cgPath: SignalCursorGlyph.path(
                in: rect.insetBy(dx: inset, dy: inset), minimumStroke: scale
            )).fill()

            switch state {
            case .downloading(let rawProgress):
                let progress = rawProgress.isFinite ? min(1, max(0, rawProgress)) : 0
                if progress > 0 {
                    let path = CGMutablePath()
                    path.addArc(center: CGPoint(x: rect.midX, y: rect.midY),
                                radius: min(rect.width, rect.height) / 2 - scale,
                                startAngle: -.pi / 2,
                                endAngle: -.pi / 2 + CGFloat(progress) * 2 * .pi,
                                clockwise: false)
                    let ring = NSBezierPath(cgPath: path)
                    ring.lineWidth = scale
                    ring.lineCapStyle = .round
                    NSColor.white.setStroke()
                    ring.stroke()
                }
            case .error:
                // Keep the brand intact; a separate badge and accessible
                // status label communicate the failure.
                let dot = CGRect(x: rect.minX, y: rect.minY + scale, width: 3 * scale, height: 3 * scale)
                NSBezierPath(ovalIn: dot).fill()
            case .idle, .recording, .processing:
                break
            }
            return true
        }
        image.accessibilityDescription = "Orttaai"
        // White source artwork; macOS supplies white on dark menu bars and
        // a contrasting dark rendition on light menu bars, including selection.
        image.isTemplate = true
        return image
    }
}
