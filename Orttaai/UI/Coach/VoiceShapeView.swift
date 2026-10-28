// VoiceShapeView.swift
// Orttaai
//
// The voice shape: six axes, now filled in amber over a dashed outline of
// four weeks ago. Axes without enough dictations yet show as grey points on
// the rim, and only the sides between known axes are drawn. Judged axes
// are labelled with a small mark.

import CoachCore
import SwiftUI

struct VoiceShapeView: View {
    var axes: [CoachAxis]
    var now: [CoachAxis: Double]
    var then: [CoachAxis: Double]
    var showsLabels = true
    var labelFont: Font = .system(size: 13, weight: .semibold)

    init(shape: CoachShape, showsThen: Bool = true, showsLabels: Bool = true, labelFont: Font = .system(size: 13, weight: .semibold)) {
        axes = shape.axes
        now = shape.nowAxes
        then = showsThen ? shape.thenAxes : [:]
        self.showsLabels = showsLabels
        self.labelFont = labelFont
    }

    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            let center = CGPoint(x: proxy.size.width / 2, y: proxy.size.height / 2)
            let radius = side / 2 * (showsLabels ? 0.68 : 0.92)
            ZStack {
                Canvas { context, _ in
                    for ring in [1.0, 2.0 / 3.0, 1.0 / 3.0] {
                        context.stroke(polygon(Array(repeating: ring, count: axes.count), center, radius), with: .color(.white.opacity(ring == 1 ? 0.09 : 0.05)), lineWidth: 1)
                    }
                    // The outline from before, or the sides of it that are known.
                    let ghost = StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round, dash: [4, 5])
                    if axes.allSatisfy({ then[$0] != nil }) {
                        context.stroke(polygon(axes.map { then[$0] ?? 0 }, center, radius), with: .color(CoachStyle.muted), style: ghost)
                    } else {
                        context.stroke(sides(then, center, radius), with: .color(CoachStyle.muted), style: ghost)
                        for i in axes.indices {
                            guard let value = then[axes[i]] else { continue }
                            let p = point(i, value, center, radius)
                            context.stroke(Path(ellipseIn: CGRect(x: p.x - 4, y: p.y - 4, width: 8, height: 8)), with: .color(CoachStyle.muted), lineWidth: 1.5)
                        }
                    }
                    if now.count == axes.count {
                        let shape = polygon(axes.map { now[$0] ?? 0 }, center, radius)
                        context.fill(shape, with: .color(Color.Orttaai.accent.opacity(0.2)))
                        context.stroke(shape, with: .color(Color.Orttaai.accent), style: StrokeStyle(lineWidth: 2.5, lineJoin: .round))
                    } else {
                        context.stroke(sides(now, center, radius), with: .color(Color.Orttaai.accent), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    }
                    for i in axes.indices {
                        let known = now[axes[i]]
                        let p = point(i, known ?? 1, center, radius)
                        let dot = Path(ellipseIn: CGRect(x: p.x - 5, y: p.y - 5, width: 10, height: 10))
                        if known != nil {
                            context.fill(Path(ellipseIn: CGRect(x: p.x - 9, y: p.y - 9, width: 18, height: 18)), with: .color(Color.Orttaai.accent.opacity(0.2)))
                            context.fill(dot, with: .color(Color.Orttaai.accent))
                        } else {
                            context.fill(dot, with: .color(.white.opacity(0.18)))
                        }
                    }
                }
                if showsLabels {
                    ForEach(Array(axes.enumerated()), id: \.element) { index, axis in
                        label(axis)
                            .font(labelFont)
                            .foregroundStyle(now[axis] == nil ? CoachStyle.muted : CoachStyle.ink2)
                            .fixedSize()
                            .position(point(index, 1, center, radius + 34 * side / 440))
                    }
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private func label(_ axis: CoachAxis) -> Text {
        guard axis.isJudged else { return Text(axis.title) }
        return Text(axis.title) + Text(" ") + Text(Image(systemName: "checkmark.bubble")).foregroundColor(CoachStyle.warmInk)
    }

    private var accessibilityText: String {
        let parts = axes.map { axis -> String in
            let name = axis.isJudged ? "\(axis.title), judged" : axis.title
            guard let value = now[axis] else { return "\(name), not known yet" }
            return "\(name) \(Int((value * 100).rounded()))%"
        }
        return "Voice shape: " + parts.joined(separator: ", ")
    }

    private func point(_ index: Int, _ value: Double, _ center: CGPoint, _ radius: CGFloat) -> CGPoint {
        let angle = (-90 + 360 / Double(max(axes.count, 1)) * Double(index)) * .pi / 180
        return CGPoint(x: center.x + radius * value * cos(angle), y: center.y + radius * value * sin(angle))
    }

    /// The sides between neighbouring axes that both have a value.
    private func sides(_ values: [CoachAxis: Double], _ center: CGPoint, _ radius: CGFloat) -> Path {
        var path = Path()
        for i in axes.indices {
            let j = (i + 1) % axes.count
            guard let a = values[axes[i]], let b = values[axes[j]] else { continue }
            path.move(to: point(i, a, center, radius))
            path.addLine(to: point(j, b, center, radius))
        }
        return path
    }

    private func polygon(_ values: [Double], _ center: CGPoint, _ radius: CGFloat) -> Path {
        var path = Path()
        for (index, value) in values.enumerated() {
            let p = point(index, value, center, radius)
            if index == 0 { path.move(to: p) } else { path.addLine(to: p) }
        }
        path.closeSubpath()
        return path
    }
}
