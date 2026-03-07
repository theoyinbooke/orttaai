#!/usr/bin/env swift

import AppKit
import Foundation

enum ThemeOption: String {
    case auto
    case light
    case dark
}

struct Options {
    let outputPath: String
    let appPath: String
    let appName: String
    let theme: ThemeOption
}

enum ArgumentError: Error, CustomStringConvertible {
    case missingValue(String)
    case missingRequired(String)
    case unknownArgument(String)

    var description: String {
        switch self {
        case .missingValue(let flag):
            return "Missing value for \(flag)"
        case .missingRequired(let flag):
            return "Missing required argument \(flag)"
        case .unknownArgument(let arg):
            return "Unknown argument \(arg)"
        }
    }
}

func parseOptions() throws -> Options {
    var outputPath: String?
    var appPath: String?
    var appName = "Orttaai"
    var theme: ThemeOption = .auto

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
            guard let parsedTheme = ThemeOption(rawValue: value.lowercased()) else {
                throw ArgumentError.unknownArgument("\(arg) \(value)")
            }
            theme = parsedTheme
        default:
            throw ArgumentError.unknownArgument(arg)
        }
    }

    guard let outputPath else { throw ArgumentError.missingRequired("--output") }
    guard let appPath else { throw ArgumentError.missingRequired("--app-path") }
    return Options(outputPath: outputPath, appPath: appPath, appName: appName, theme: theme)
}

struct ThemePalette {
    let baseBackground: NSColor
    let gradientTop: NSColor
    let gradientMid: NSColor
    let gradientBottom: NSColor
    let focusColor: NSColor
    let panelFill: NSColor
    let panelStroke: NSColor
    let titleColor: NSColor
    let subtitleColor: NSColor
    let accent: NSColor
}

func detectSystemTheme() -> ThemeOption {
    let appearance = UserDefaults.standard.string(forKey: "AppleInterfaceStyle")?.lowercased()
    return appearance == "dark" ? .dark : .light
}

func palette(for theme: ThemeOption) -> ThemePalette {
    switch theme {
    case .dark:
        return ThemePalette(
            baseBackground: NSColor(calibratedRed: 0.05, green: 0.08, blue: 0.11, alpha: 1.0),
            gradientTop: NSColor(calibratedRed: 0.08, green: 0.12, blue: 0.16, alpha: 1.0),
            gradientMid: NSColor(calibratedRed: 0.04, green: 0.06, blue: 0.08, alpha: 1.0),
            gradientBottom: NSColor(calibratedRed: 0.03, green: 0.05, blue: 0.07, alpha: 1.0),
            focusColor: NSColor(calibratedRed: 0.13, green: 0.87, blue: 0.79, alpha: 0.10),
            panelFill: NSColor(calibratedWhite: 1.0, alpha: 0.045),
            panelStroke: NSColor(calibratedRed: 0.13, green: 0.87, blue: 0.79, alpha: 0.18),
            titleColor: NSColor(calibratedWhite: 0.98, alpha: 0.95),
            subtitleColor: NSColor(calibratedWhite: 0.82, alpha: 0.75),
            accent: NSColor(calibratedRed: 0.13, green: 0.87, blue: 0.79, alpha: 0.95)
        )
    case .light:
        return ThemePalette(
            baseBackground: NSColor(calibratedRed: 0.95, green: 0.97, blue: 0.99, alpha: 1.0),
            gradientTop: NSColor(calibratedRed: 0.99, green: 1.00, blue: 1.00, alpha: 1.0),
            gradientMid: NSColor(calibratedRed: 0.94, green: 0.97, blue: 0.99, alpha: 1.0),
            gradientBottom: NSColor(calibratedRed: 0.90, green: 0.94, blue: 0.97, alpha: 1.0),
            focusColor: NSColor(calibratedRed: 0.08, green: 0.61, blue: 0.55, alpha: 0.09),
            panelFill: NSColor(calibratedWhite: 1.0, alpha: 0.62),
            panelStroke: NSColor(calibratedRed: 0.08, green: 0.61, blue: 0.55, alpha: 0.30),
            titleColor: NSColor(calibratedRed: 0.12, green: 0.16, blue: 0.21, alpha: 0.96),
            subtitleColor: NSColor(calibratedRed: 0.28, green: 0.34, blue: 0.40, alpha: 0.90),
            accent: NSColor(calibratedRed: 0.10, green: 0.64, blue: 0.58, alpha: 0.95)
        )
    case .auto:
        return palette(for: detectSystemTheme())
    }
}

func drawCenteredText(_ text: String, y: CGFloat, attributes: [NSAttributedString.Key: Any], width: CGFloat) {
    let size = text.size(withAttributes: attributes)
    let point = NSPoint(x: (width - size.width) / 2.0, y: y)
    text.draw(at: point, withAttributes: attributes)
}

func drawArrow(from start: CGPoint, to end: CGPoint, color: NSColor) {
    let glowColor = color.withAlphaComponent(0.22)
    let shaft = NSBezierPath()
    shaft.move(to: start)
    shaft.line(to: end)
    shaft.lineWidth = 12
    shaft.lineCapStyle = .round

    glowColor.setStroke()
    shaft.stroke()

    shaft.lineWidth = 6
    color.setStroke()
    shaft.stroke()

    let angle = atan2(end.y - start.y, end.x - start.x)
    let headLength: CGFloat = 18
    let headAngle: CGFloat = .pi / 6

    let left = CGPoint(
        x: end.x - cos(angle - headAngle) * headLength,
        y: end.y - sin(angle - headAngle) * headLength
    )
    let right = CGPoint(
        x: end.x - cos(angle + headAngle) * headLength,
        y: end.y - sin(angle + headAngle) * headLength
    )

    let head = NSBezierPath()
    head.move(to: left)
    head.line(to: end)
    head.line(to: right)
    head.lineWidth = 12
    head.lineCapStyle = .round
    head.lineJoinStyle = .round

    glowColor.setStroke()
    head.stroke()

    head.lineWidth = 6
    color.setStroke()
    head.stroke()
}

func makeBitmap(size: NSSize) -> NSBitmapImageRep? {
    let pixelsWide = Int(size.width)
    let pixelsHigh = Int(size.height)
    return NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixelsWide,
        pixelsHigh: pixelsHigh,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    )
}

do {
    let options = try parseOptions()
    let canvasSize = NSSize(width: 720, height: 400)
    let resolvedTheme = options.theme == .auto ? detectSystemTheme() : options.theme
    let colors = palette(for: resolvedTheme)

    guard let bitmap = makeBitmap(size: canvasSize),
          let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
        fputs("Failed to create bitmap context.\n", stderr)
        exit(1)
    }

    bitmap.size = canvasSize

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context

    let rect = NSRect(origin: .zero, size: canvasSize)
    colors.baseBackground.setFill()
    rect.fill()

    NSGradient(colorsAndLocations:
        (colors.gradientTop, 0.0),
        (colors.gradientMid, 0.55),
        (colors.gradientBottom, 1.0)
    )?.draw(in: rect, angle: 90)

    for panelRect in [
        NSRect(x: 102, y: 118, width: 156, height: 140),
        NSRect(x: 462, y: 118, width: 156, height: 140)
    ] {
        if let glow = NSGradient(starting: colors.focusColor, ending: .clear) {
            glow.draw(in: NSBezierPath(ovalIn: panelRect.insetBy(dx: -18, dy: -12)), relativeCenterPosition: .zero)
        }

        let panel = NSBezierPath(roundedRect: panelRect, xRadius: 28, yRadius: 28)
        colors.panelFill.setFill()
        panel.fill()
        colors.panelStroke.setStroke()
        panel.lineWidth = 1.5
        panel.stroke()
    }

    let titleAttributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 24, weight: .semibold),
        .foregroundColor: colors.titleColor
    ]
    let subtitleAttributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 13, weight: .medium),
        .foregroundColor: colors.subtitleColor
    ]

    drawCenteredText("Drag \(options.appName) to Applications", y: 332, attributes: titleAttributes, width: canvasSize.width)
    drawCenteredText("Install by dropping the app onto the Applications folder.", y: 304, attributes: subtitleAttributes, width: canvasSize.width)

    drawArrow(
        from: CGPoint(x: 258, y: 188),
        to: CGPoint(x: 462, y: 188),
        color: colors.accent
    )

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
