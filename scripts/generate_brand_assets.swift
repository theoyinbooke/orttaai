import AppKit

/// Compile with SignalCursorGlyph.swift so exports and runtime use one master.
@main
struct BrandAssetExporter {
    static let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    static let output = root.appendingPathComponent("branding/orttaai")
    static let sizes = [16, 32, 64, 128, 256, 512, 1024, 2048]
    static let amber = color("D4952A")
    static let charcoal = color("1C1C1E")
    static let paper = color("F5F3F0")
    static var files: [[String: Any]] = []

    static func color(_ hex: String) -> NSColor {
        let value = UInt32(hex, radix: 16)!
        return NSColor(srgbRed: CGFloat((value >> 16) & 255) / 255,
                       green: CGFloat((value >> 8) & 255) / 255,
                       blue: CGFloat(value & 255) / 255, alpha: 1)
    }

    static func write(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }

    static func bitmap(width: Int, height: Int, draw: (CGContext, CGRect) -> Void) -> NSBitmapImageRep {
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                     isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        bitmap.size = CGSize(width: width, height: height)
        let context = NSGraphicsContext(bitmapImageRep: bitmap)!.cgContext
        context.clear(CGRect(x: 0, y: 0, width: width, height: height))
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        context.setShouldAntialias(true)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        draw(context, CGRect(x: 0, y: 0, width: width, height: height))
        NSGraphicsContext.restoreGraphicsState()
        return bitmap
    }

    static func png(_ name: String, width: Int, height: Int? = nil, transparent: Bool,
                    draw: (CGContext, CGRect) -> Void) throws {
        let image = bitmap(width: width, height: height ?? width, draw: draw)
        try write(image.representation(using: .png, properties: [:])!, to: output.appendingPathComponent(name))
        files.append(["file": name, "width": width, "height": height ?? width, "transparent": transparent])
    }

    static func fillMark(_ context: CGContext, in bounds: CGRect, color: NSColor, minimumStroke: CGFloat = 0) {
        context.addPath(SignalCursorGlyph.path(in: bounds, minimumStroke: minimumStroke))
        context.setFillColor(color.cgColor)
        context.fillPath()
    }

    static func appIcon(_ context: CGContext, in bounds: CGRect, background: NSColor, foreground: NSColor) {
        let tile = bounds.insetBy(dx: bounds.width * 0.055, dy: bounds.height * 0.055)
        let corner = tile.width * 0.22
        context.addPath(CGPath(roundedRect: tile, cornerWidth: corner, cornerHeight: corner, transform: nil))
        context.setFillColor(background.cgColor)
        context.fillPath()
        fillMark(context, in: bounds.insetBy(dx: bounds.width * 0.205, dy: bounds.height * 0.205),
                 color: foreground, minimumStroke: bounds.width <= 32 ? 1 : 0)
    }

    static func text(_ value: String, at point: CGPoint, size: CGFloat, color: NSColor, weight: NSFont.Weight = .regular) {
        value.draw(at: point, withAttributes: [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color])
    }

    static func pdf(_ name: String, width: CGFloat, height: CGFloat,
                    draw: (CGContext, CGRect) -> Void) throws {
        let data = NSMutableData()
        var bounds = CGRect(x: 0, y: 0, width: width, height: height)
        let context = CGContext(consumer: CGDataConsumer(data: data)!, mediaBox: &bounds, nil)!
        context.beginPDFPage(nil)
        context.translateBy(x: 0, y: height)
        context.scaleBy(x: 1, y: -1)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        draw(context, bounds)
        NSGraphicsContext.restoreGraphicsState()
        context.endPDFPage()
        context.closePDF()
        try write(data as Data, to: output.appendingPathComponent(name))
    }

    static func svgPath(_ bounds: CGRect) -> String {
        var commands: [String] = []
        func point(_ p: CGPoint) -> String { String(format: "%.4f %.4f", Double(p.x), Double(p.y)) }
        SignalCursorGlyph.path(in: bounds).applyWithBlock { element in
            let e = element.pointee
            switch e.type {
            case .moveToPoint: commands.append("M" + point(e.points[0]))
            case .addLineToPoint: commands.append("L" + point(e.points[0]))
            case .addQuadCurveToPoint: commands.append("Q" + point(e.points[0]) + " " + point(e.points[1]))
            case .addCurveToPoint: commands.append("C" + point(e.points[0]) + " " + point(e.points[1]) + " " + point(e.points[2]))
            case .closeSubpath: commands.append("Z")
            @unknown default: break
            }
        }
        return commands.joined(separator: " ")
    }

    static func main() throws {
        for (name, ink, hex) in [("amber", amber, "D4952A"), ("white", NSColor.white, "FFFFFF"), ("charcoal", charcoal, "1C1C1E")] {
            for size in sizes {
                try png("marks/\(name)/mark-\(size).png", width: size, transparent: true) { ctx, rect in
                    fillMark(ctx, in: rect.insetBy(dx: rect.width * 0.08, dy: rect.height * 0.08), color: ink,
                             minimumStroke: size <= 32 ? 1 : 0)
                }
            }
            try pdf("vectors/mark-\(name).pdf", width: 100, height: 84) { ctx, rect in
                fillMark(ctx, in: rect, color: ink)
            }
            let path = svgPath(CGRect(x: 0, y: 0, width: 100, height: 84))
            let svg = "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 100 84\" fill=\"#\(hex)\" role=\"img\" aria-label=\"Orttaai Signal Cursor\"><path d=\"\(path)\"/></svg>\n"
            try write(Data(svg.utf8), to: output.appendingPathComponent("vectors/mark-\(name).svg"))
            for width in [320, 640, 1280, 2560] {
                try png("wordmarks/\(name)/wordmark-\(width).png", width: width, height: width / 4, transparent: true) { ctx, rect in
                    let scale = rect.width / 640
                    fillMark(ctx, in: CGRect(x: 20 * scale, y: 32 * scale, width: 112 * scale, height: 96 * scale), color: ink)
                    text("Orttaai", at: CGPoint(x: 158 * scale, y: 24 * scale), size: 86 * scale, color: ink, weight: .medium)
                }
            }
            let wordmark = "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 640 160\" fill=\"#\(hex)\"><g transform=\"translate(20 33) scale(1.12)\"><path d=\"\(path)\"/></g><text x=\"158\" y=\"112\" font-family=\"-apple-system,BlinkMacSystemFont,Helvetica,Arial,sans-serif\" font-size=\"86\" font-weight=\"500\">Orttaai</text></svg>\n"
            try write(Data(wordmark.utf8), to: output.appendingPathComponent("vectors/wordmark-\(name).svg"))
        }

        for (name, background, foreground) in [("dark", charcoal, amber), ("light", paper, amber), ("white-on-dark", charcoal, NSColor.white)] {
            for size in sizes {
                try png("icons/\(name)/icon-\(size).png", width: size, transparent: true) { ctx, rect in
                    appIcon(ctx, in: rect, background: background, foreground: foreground)
                }
            }
            let path = svgPath(CGRect(x: 205, y: 205, width: 590, height: 590))
            let bg = name == "light" ? "F5F3F0" : "1C1C1E"
            let fg = name == "white-on-dark" ? "FFFFFF" : "D4952A"
            let svg = "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 1000 1000\"><rect x=\"55\" y=\"55\" width=\"890\" height=\"890\" rx=\"195.8\" fill=\"#\(bg)\"/><path d=\"\(path)\" fill=\"#\(fg)\"/></svg>\n"
            try write(Data(svg.utf8), to: output.appendingPathComponent("vectors/icon-\(name).svg"))
        }

        for (name, background, ink) in [("on-light", paper, charcoal), ("on-dark", charcoal, NSColor.white)] {
            try png("presentations/\(name).png", width: 1600, height: 900, transparent: false) { ctx, rect in
                ctx.setFillColor(background.cgColor); ctx.fill(rect)
                fillMark(ctx, in: CGRect(x: 150, y: 250, width: 440, height: 400), color: amber)
                text("Orttaai", at: CGPoint(x: 690, y: 333), size: 150, color: ink, weight: .medium)
            }
        }

        for size in [16, 18, 20, 22, 24, 32, 36, 40, 44, 48, 64] {
            try png("menu-bar/white-\(size).png", width: size, transparent: true) { ctx, rect in
                fillMark(ctx, in: rect.insetBy(dx: rect.width / 18, dy: rect.height / 18), color: .white,
                         minimumStroke: CGFloat(size) / 18)
            }
        }
        try pdf("menu-bar/white-template.pdf", width: 18, height: 18) { ctx, rect in
            fillMark(ctx, in: rect.insetBy(dx: 1, dy: 1), color: .white, minimumStroke: 1)
        }

        let fm = FileManager.default
        let catalog = root.appendingPathComponent("Orttaai/Assets.xcassets")
        for size in [16, 32, 64, 128, 256, 512, 1024] {
            let destination = catalog.appendingPathComponent("AppIcon.appiconset/icon_\(size).png")
            try write(Data(contentsOf: output.appendingPathComponent("icons/dark/icon-\(size).png")), to: destination)
        }
        for (assetName, variant) in [("BrandIconDark", "dark"), ("BrandIconLight", "light")] {
            let asset = catalog.appendingPathComponent("\(assetName).imageset")
            try write(Data(contentsOf: output.appendingPathComponent("icons/\(variant)/icon-1024.png")), to: asset.appendingPathComponent("icon.png"))
            let contents: [String: Any] = ["images": [["filename": "icon.png", "idiom": "universal"]], "info": ["author": "xcode", "version": 1]]
            try write(JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys]), to: asset.appendingPathComponent("Contents.json"))
        }
        let menuAsset = catalog.appendingPathComponent("MenuBarBrand.imageset")
        try write(Data(contentsOf: output.appendingPathComponent("menu-bar/white-template.pdf")), to: menuAsset.appendingPathComponent("mark.pdf"))
        let menuContents: [String: Any] = ["images": [["filename": "mark.pdf", "idiom": "universal"]], "info": ["author": "xcode", "version": 1], "properties": ["preserves-vector-representation": true, "template-rendering-intent": "template"]]
        try write(JSONSerialization.data(withJSONObject: menuContents, options: [.prettyPrinted, .sortedKeys]), to: menuAsset.appendingPathComponent("Contents.json"))
        try write(Data(contentsOf: output.appendingPathComponent("icons/dark/icon-1024.png")), to: root.appendingPathComponent("orttaai.png"))
        try write(Data(contentsOf: output.appendingPathComponent("vectors/mark-amber.pdf")), to: root.appendingPathComponent("Orttaai/Resources/SignalCursorAmber.pdf"))

        let iconset = output.appendingPathComponent("Orttaai.iconset")
        try fm.createDirectory(at: iconset, withIntermediateDirectories: true)
        for size in [16, 32, 128, 256, 512] {
            for (scale, suffix) in [(1, ""), (2, "@2x")] {
                try write(Data(contentsOf: output.appendingPathComponent("icons/dark/icon-\(size * scale).png")),
                          to: iconset.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
            }
        }

        try preview()
        let manifest: [String: Any] = ["name": "Orttaai Signal Cursor", "source": "Orttaai/Design/SignalCursorGlyph.swift", "palette": ["amber": "#D4952A", "charcoal": "#1C1C1E", "paper": "#F5F3F0", "white": "#FFFFFF"], "png": files]
        try write(JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys]), to: output.appendingPathComponent("manifest.json"))
        print("Generated \(files.count) PNG exports, SVG/PDF masters, macOS asset catalogs and iconset.")
    }

    static func preview() throws {
        try png("preview.png", width: 1800, height: 1320, transparent: false) { ctx, rect in
            ctx.setFillColor(NSColor.white.cgColor); ctx.fill(rect)
            ctx.setFillColor(color("111113").cgColor); ctx.fill(CGRect(x: 900, y: 0, width: 900, height: rect.height))
            for (x, ink, bg, title) in [(CGFloat(0), charcoal, paper, "LIGHT"), (CGFloat(900), NSColor.white, charcoal, "DARK")] {
                text("Orttaai / Signal Cursor", at: CGPoint(x: x + 64, y: 45), size: 35, color: ink, weight: .medium)
                text(title, at: CGPoint(x: x + 66, y: 103), size: 17, color: ink.withAlphaComponent(0.55))
                appIcon(ctx, in: CGRect(x: x + 70, y: 180, width: 370, height: 370), background: bg, foreground: amber)
                fillMark(ctx, in: CGRect(x: x + 540, y: 280, width: 215, height: 180), color: amber)
                text("APP ICON", at: CGPoint(x: x + 98, y: 555), size: 17, color: ink)
                text("STANDALONE MARK", at: CGPoint(x: x + 495, y: 555), size: 17, color: ink)
                text("SIZES / 16, 32, 64, 128", at: CGPoint(x: x + 66, y: 645), size: 17, color: ink.withAlphaComponent(0.6))
                var offset: CGFloat = 80
                for side in [CGFloat(16), 32, 64, 128] {
                    appIcon(ctx, in: CGRect(x: x + offset, y: 703 + (128 - side) / 2, width: side, height: side), background: bg, foreground: amber)
                    offset += side + 45
                }
                text("TRANSPARENT / AMBER, MONOCHROME", at: CGPoint(x: x + 66, y: 900), size: 17, color: ink.withAlphaComponent(0.6))
                for (index, foreground) in [amber, ink].enumerated() {
                    let box = CGRect(x: x + 80 + CGFloat(index) * 260, y: 958, width: 220, height: 175)
                    for row in 0..<7 {
                        for col in 0..<9 {
                            ctx.setFillColor(ink.withAlphaComponent((row + col) % 2 == 0 ? 0.035 : 0.065).cgColor)
                            ctx.fill(CGRect(x: box.minX + CGFloat(col) * 25, y: box.minY + CGFloat(row) * 25, width: 25, height: 25))
                        }
                    }
                    fillMark(ctx, in: box.insetBy(dx: 36, dy: 24), color: foreground)
                }
                text("MENU BAR / NATIVE TEMPLATE", at: CGPoint(x: x + 66, y: 1190), size: 17, color: ink.withAlphaComponent(0.6))
                ctx.setFillColor(ink.withAlphaComponent(0.07).cgColor)
                ctx.fill(CGRect(x: x + 65, y: 1230, width: 760, height: 50))
                fillMark(ctx, in: CGRect(x: x + 100, y: 1245, width: 18, height: 18), color: ink, minimumStroke: 1)
                text("Orttaai", at: CGPoint(x: x + 140, y: 1243), size: 18, color: ink)
            }
        }
    }
}
