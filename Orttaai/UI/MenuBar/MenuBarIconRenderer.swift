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
        switch state {
        case .idle:
            return idleIcon(size: size)
        case .recording:
            return tintedIcon(symbolName: "waveform.circle.fill", color: NSColor.Orttaai.accent, size: size)
        case .processing:
            return tintedIcon(symbolName: "waveform.circle.fill", color: NSColor.Orttaai.accent, size: size)
        case .downloading(let progress):
            return downloadingIcon(progress: progress, size: size)
        case .error:
            return errorIcon(size: size)
        }
    }

    // MARK: - Icon States

    private static func idleIcon(size: NSSize) -> NSImage {
        let image = NSImage(systemSymbolName: "waveform.circle", accessibilityDescription: "Orttaai")!
        image.isTemplate = true
        return image
    }

    private static func tintedIcon(symbolName: String, color: NSColor, size: NSSize) -> NSImage {
        let symbol = NSImage(systemSymbolName: symbolName, accessibilityDescription: "Orttaai")!

        let tinted = NSImage(size: symbol.size, flipped: false) { rect in
            symbol.draw(in: rect)
            color.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        tinted.isTemplate = false
        return tinted
    }

    private static func downloadingIcon(progress: Double, size: NSSize) -> NSImage {
        let image = NSImage(size: size, flipped: false) { rect in
            // Base icon
            let baseIcon = NSImage(systemSymbolName: "waveform.circle", accessibilityDescription: "Orttaai")!
            baseIcon.isTemplate = true
            baseIcon.draw(in: rect)

            // Progress ring
            let center = NSPoint(x: rect.midX, y: rect.midY)
            let radius = min(rect.width, rect.height) / 2 - 1
            let startAngle: CGFloat = 90
            let endAngle = startAngle - CGFloat(360 * progress)

            let path = NSBezierPath()
            path.appendArc(
                withCenter: center,
                radius: radius,
                startAngle: startAngle,
                endAngle: endAngle,
                clockwise: true
            )
            path.lineWidth = 1.5
            NSColor.Orttaai.accent.setStroke()
            path.stroke()

            return true
        }
        image.isTemplate = false
        return image
    }

    private static func errorIcon(size: NSSize) -> NSImage {
        let image = NSImage(size: size, flipped: false) { rect in
            // Base icon
            let baseIcon = NSImage(systemSymbolName: "waveform.circle", accessibilityDescription: "Orttaai")!
            baseIcon.isTemplate = true
            baseIcon.draw(in: rect)

            // Error dot
            let dotSize: CGFloat = 5
            let dotRect = NSRect(
                x: rect.maxX - dotSize - 1,
                y: rect.minY + 1,
                width: dotSize,
                height: dotSize
            )
            NSColor.Orttaai.accent.setFill()
            NSBezierPath(ovalIn: dotRect).fill()

            return true
        }
        image.isTemplate = false
        return image
    }
}
