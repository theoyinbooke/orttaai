import CoreGraphics

/// Canonical, vector-only geometry shared by the app and the brand exporter.
/// Coordinates run downwards from the top-left, like SwiftUI's drawing space.
nonisolated enum SignalCursorGlyph {
    static let aspectRatio: CGFloat = 100.0 / 84.0

    static func path(in bounds: CGRect, minimumStroke: CGFloat = 0) -> CGPath {
        let scale = min(bounds.width / 100, bounds.height / 84)
        let origin = CGPoint(
            x: bounds.midX - 50 * scale,
            y: bounds.midY - 42 * scale
        )
        let path = CGMutablePath()

        func capsule(_ rect: CGRect, minimumWidth: CGFloat = 0, minimumHeight: CGFloat = 0) {
            let width = max(rect.width * scale, minimumWidth)
            let height = max(rect.height * scale, minimumHeight)
            let scaled = CGRect(
                x: origin.x + rect.midX * scale - width / 2,
                y: origin.y + rect.midY * scale - height / 2,
                width: width,
                height: height
            )
            let radius = min(width, height) / 2
            path.addRoundedRect(in: scaled, cornerWidth: radius, cornerHeight: radius)
        }

        capsule(CGRect(x: 0, y: 44, width: 18, height: 36))
        capsule(CGRect(x: 25, y: 28, width: 18, height: 52))
        capsule(CGRect(x: 50, y: 12, width: 18, height: 68))
        capsule(CGRect(x: 85, y: 3, width: 6, height: 78), minimumWidth: minimumStroke)
        capsule(CGRect(x: 77, y: 0, width: 22, height: 6), minimumHeight: minimumStroke)
        capsule(CGRect(x: 77, y: 78, width: 22, height: 6), minimumHeight: minimumStroke)
        return path
    }
}
