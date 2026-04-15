#!/usr/bin/env swift

import AppKit
import Foundation

struct Options {
    let outputPath: String
    let appPath: String
    let appName: String
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
            guard iterator.next() != nil else { throw ArgumentError.missingValue(arg) }
        default:
            throw ArgumentError.unknownArgument(arg)
        }
    }

    guard let outputPath else { throw ArgumentError.missingRequired("--output") }
    guard let appPath else { throw ArgumentError.missingRequired("--app-path") }
    return Options(outputPath: outputPath, appPath: appPath, appName: appName)
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
    let canvasSize = NSSize(width: 760, height: 440)

    guard let bitmap = makeBitmap(size: canvasSize),
          let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
        fputs("Failed to create bitmap context.\n", stderr)
        exit(1)
    }

    bitmap.size = canvasSize

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context

    let rect = NSRect(origin: .zero, size: canvasSize)
    NSColor.white.setFill()
    rect.fill()

    let titleAttributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 24, weight: .semibold),
        .foregroundColor: NSColor(calibratedWhite: 0.12, alpha: 1.0)
    ]
    let subtitleAttributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 13, weight: .medium),
        .foregroundColor: NSColor(calibratedWhite: 0.36, alpha: 1.0)
    ]

    drawCenteredText("Drag \(options.appName) to Applications", y: 388, attributes: titleAttributes, width: canvasSize.width)
    drawCenteredText("Install by dropping the app onto the Applications folder.", y: 362, attributes: subtitleAttributes, width: canvasSize.width)

    // Arrow y must match Finder icon y in Cocoa coords: canvasHeight - finderY = 440 - 220 = 220
    drawArrow(
        from: CGPoint(x: 296, y: 220),
        to: CGPoint(x: 464, y: 220),
        color: NSColor(calibratedWhite: 0.60, alpha: 1.0)
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
