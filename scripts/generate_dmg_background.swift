#!/usr/bin/env swift

import AppKit
import Foundation

struct Options {
    let outputPath: String
    let appPath: String
    let appName: String
    let theme: String
}

enum ArgumentError: Error, CustomStringConvertible {
    case missingValue(String)
    case missingRequired(String)
    case unknownArgument(String)
    case invalidTheme(String)

    var description: String {
        switch self {
        case .missingValue(let flag):
            return "Missing value for \(flag)"
        case .missingRequired(let flag):
            return "Missing required argument \(flag)"
        case .unknownArgument(let arg):
            return "Unknown argument \(arg)"
        case .invalidTheme(let value):
            return "Invalid --theme value: \(value) (expected auto, light, or dark)"
        }
    }
}

func parseOptions() throws -> Options {
    var outputPath: String?
    var appPath: String?
    var appName = "Orttaai"
    var theme = "auto"

    var iterator = CommandLine.arguments.dropFirst().makeIterator()
    while let arg = iterator.next() {
        switch arg {
        case "--output":
            guard let value = iterator.next() else { throw ArgumentError.missingValue(arg) }
            outputPath = value
        case "--app-path":
            guard let value = iterator.next() else { throw ArgumentError.missingValue(arg) }
            appPath = value
        case "--app-name":
            guard let value = iterator.next() else { throw ArgumentError.missingValue(arg) }
            appName = value
        case "--theme":
            guard let value = iterator.next() else { throw ArgumentError.missingValue(arg) }
            guard ["auto", "light", "dark"].contains(value) else { throw ArgumentError.invalidTheme(value) }
            theme = value
        default:
            throw ArgumentError.unknownArgument(arg)
        }
    }

    guard let outputPath else { throw ArgumentError.missingRequired("--output") }
    guard let appPath else { throw ArgumentError.missingRequired("--app-path") }
    return Options(outputPath: outputPath, appPath: appPath, appName: appName, theme: theme)
}

func color(hex: String, alpha: CGFloat = 1.0) -> NSColor {
    var value: UInt64 = 0
    Scanner(string: hex).scanHexInt64(&value)
    return NSColor(
        srgbRed: CGFloat((value >> 16) & 0xFF) / 255.0,
        green: CGFloat((value >> 8) & 0xFF) / 255.0,
        blue: CGFloat(value & 0xFF) / 255.0,
        alpha: alpha
    )
}

/// Brand palette (matches Orttaai/Design/Colors.swift).
struct Palette {
    let backgroundTop: NSColor
    let backgroundBottom: NSColor
    let wordmark: NSColor
    let arrow: NSColor
    let waveform: NSColor

    static func forTheme(_ theme: String) -> Palette {
        // A DMG background can't adapt to Finder's appearance, so "auto"
        // resolves to the light treatment, which reads well in both modes.
        if theme == "dark" {
            return Palette(
                backgroundTop: color(hex: "26241F"),
                backgroundBottom: color(hex: "1C1C1E"),
                wordmark: color(hex: "F5F3F0"),
                arrow: color(hex: "D4952A"),
                waveform: color(hex: "D4952A")
            )
        }
        return Palette(
            backgroundTop: color(hex: "FBF7F0"),
            backgroundBottom: color(hex: "F3E4C9"),
            wordmark: color(hex: "3A342A"),
            arrow: color(hex: "C88920"),
            waveform: color(hex: "D4952A")
        )
    }
}

/// Dotted curved arrow that dips between the two Finder icons, LM Studio style.
func drawDottedArrow(from start: CGPoint, to end: CGPoint, dip: CGFloat, color: NSColor) {
    let controlPoint1 = CGPoint(x: start.x + (end.x - start.x) * 0.30, y: start.y - dip)
    let controlPoint2 = CGPoint(x: start.x + (end.x - start.x) * 0.75, y: end.y - dip * 0.55)

    let path = NSBezierPath()
    path.move(to: start)
    path.curve(to: end, controlPoint1: controlPoint1, controlPoint2: controlPoint2)
    path.lineWidth = 5
    path.lineCapStyle = .round
    path.setLineDash([0.5, 14], count: 2, phase: 0)
    color.setStroke()
    path.stroke()

    // Open chevron head along the curve's exit tangent (end minus the last
    // control point for a cubic bezier).
    let angle = atan2(end.y - controlPoint2.y, end.x - controlPoint2.x)
    let headLength: CGFloat = 15
    let headAngle: CGFloat = .pi / 4.2

    let head = NSBezierPath()
    head.move(to: CGPoint(
        x: end.x - cos(angle - headAngle) * headLength,
        y: end.y - sin(angle - headAngle) * headLength
    ))
    head.line(to: end)
    head.line(to: CGPoint(
        x: end.x - cos(angle + headAngle) * headLength,
        y: end.y - sin(angle + headAngle) * headLength
    ))
    head.lineWidth = 5
    head.lineCapStyle = .round
    head.lineJoinStyle = .round
    color.setStroke()
    head.stroke()
}

/// Decorative audio waveform: rounded bars fading toward the edges.
/// On-brand ornament for a voice keyboard, standing in for a mascot.
func drawWaveform(centeredAt center: CGPoint, color: NSColor) {
    let heights: [CGFloat] = [10, 22, 38, 58, 44, 70, 52, 30, 46, 24, 12]
    let barWidth: CGFloat = 7
    let spacing: CGFloat = 13
    let totalWidth = CGFloat(heights.count - 1) * spacing
    let peak = heights.max() ?? 1

    for (index, height) in heights.enumerated() {
        let x = center.x - totalWidth / 2 + CGFloat(index) * spacing
        // Taller bars are more opaque, so the shape fades at its edges.
        let alpha = 0.16 + 0.30 * (height / peak)
        let bar = NSBezierPath(
            roundedRect: NSRect(x: x - barWidth / 2, y: center.y - height / 2, width: barWidth, height: height),
            xRadius: barWidth / 2,
            yRadius: barWidth / 2
        )
        color.withAlphaComponent(alpha).setFill()
        bar.fill()
    }
}

func makeBitmap(pointSize: NSSize, scale: CGFloat) -> NSBitmapImageRep? {
    let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: Int(pointSize.width * scale),
        pixelsHigh: Int(pointSize.height * scale),
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    )
    // Point size differs from pixel size, so the PNG carries retina DPI and
    // Finder renders it at window size instead of cropping the 2x pixels.
    bitmap?.size = pointSize
    return bitmap
}

do {
    let options = try parseOptions()
    let palette = Palette.forTheme(options.theme)

    // Must match the Finder window content size set in release_dmg.sh
    // (bounds {100, 100, 860, 540}).
    let canvasSize = NSSize(width: 760, height: 440)

    guard let bitmap = makeBitmap(pointSize: canvasSize, scale: 2),
          let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
        fputs("Failed to create bitmap context.\n", stderr)
        exit(1)
    }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context

    let rect = NSRect(origin: .zero, size: canvasSize)
    NSGradient(starting: palette.backgroundTop, ending: palette.backgroundBottom)?
        .draw(in: rect, angle: -90)

    // Wordmark: app icon + name, top-left.
    let iconInset: CGFloat = 28
    let iconSide: CGFloat = 30
    let iconY = canvasSize.height - iconInset - iconSide
    var wordmarkX = iconInset
    if let appIcon = NSImage(contentsOfFile: "\(options.appPath)/Contents/Resources/AppIcon.icns") {
        appIcon.draw(
            in: NSRect(x: iconInset, y: iconY, width: iconSide, height: iconSide),
            from: .zero,
            operation: .sourceOver,
            fraction: 1.0
        )
        wordmarkX += iconSide + 10
    }
    let wordmarkAttributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 20, weight: .semibold),
        .foregroundColor: palette.wordmark
    ]
    let wordmarkSize = options.appName.size(withAttributes: wordmarkAttributes)
    options.appName.draw(
        at: NSPoint(x: wordmarkX, y: iconY + (iconSide - wordmarkSize.height) / 2),
        withAttributes: wordmarkAttributes
    )

    // Icons sit at Finder coords (190, 220) and (570, 220) with 152pt icons;
    // in Cocoa coords their centers are at y = 440 - 220 = 220.
    drawDottedArrow(
        from: CGPoint(x: 292, y: 200),
        to: CGPoint(x: 462, y: 208),
        dip: 58,
        color: palette.arrow
    )

    // Kept clear of the "Applications" label Finder draws under the icon.
    drawWaveform(centeredAt: CGPoint(x: 655, y: 60), color: palette.waveform)

    let outputURL = URL(fileURLWithPath: options.outputPath)
    try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)

    guard let pngData = bitmap.representation(using: .png, properties: [:]) else {
        fputs("Failed to encode DMG background as PNG.\n", stderr)
        exit(1)
    }

    try pngData.write(to: outputURL)
    NSGraphicsContext.restoreGraphicsState()
} catch {
    fputs("\(error)\n", stderr)
    exit(1)
}
