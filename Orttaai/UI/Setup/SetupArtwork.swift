// SetupArtwork.swift
// Orttaai

import SwiftUI

/// The animated scene at the top of each Setup step, drawn with vector
/// paths on a glowing stage: your voice turning into text, a shield for
/// permissions, a chip fed by a small network for the engine, and a key
/// press for Ready. Holds still under Reduce Motion.
struct SetupStepArt: View {
    let step: Int
    /// The step's work is done: permissions granted, engine ready.
    var isComplete = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // The stage stays put between steps; only the scene cross-fades,
        // so a step change never rebuilds the grid and glow.
        SetupStage {
            ZStack {
                scene
                    .id(step)
                    .transition(.opacity)
            }
        }
        .accessibilityHidden(true)
    }

    /// One frame of the step's scene, rendered as a single Metal layer so
    /// it stays cheap to animate, fade and slide.
    private var scene: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion)) { context in
            let t = reduceMotion ? 1.3 : context.date.timeIntervalSinceReferenceDate
            switch step {
            case 0: VoiceToTextScene(t: t)
            case 1: ShieldScene(t: t, isComplete: isComplete)
            case 2: EngineScene(t: t, isComplete: isComplete)
            default: KeyPressScene(t: t)
            }
        }
        .drawingGroup()
    }
}

/// A soft round glow: a radial gradient, far cheaper than a blurred
/// shadow that has to be recomputed every frame.
private struct Glow: View {
    let color: Color
    let opacity: Double
    let size: CGFloat

    var body: some View {
        Circle()
            .fill(RadialGradient(colors: [color.opacity(opacity), color.opacity(0)], center: .center, startRadius: 0, endRadius: size / 2))
            .frame(width: size, height: size)
    }
}

// MARK: - Stage

/// A dark card with a dot grid and a slow amber glow behind the scene.
private struct SetupStage<Content: View>: View {
    @ViewBuilder let content: Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color.Orttaai.bgSecondary, Color.Orttaai.bgPrimary],
                startPoint: .top,
                endPoint: .bottom
            )

            Canvas { context, size in
                let spacing: CGFloat = 16
                var y = spacing / 2
                while y < size.height {
                    var x = spacing / 2
                    while x < size.width {
                        context.fill(
                            Path(ellipseIn: CGRect(x: x - 0.75, y: y - 0.75, width: 1.5, height: 1.5)),
                            with: .color(Color.Orttaai.textPrimary.opacity(0.07))
                        )
                        x += spacing
                    }
                    y += spacing
                }
            }

            TimelineView(.animation(minimumInterval: 1.0 / 20, paused: reduceMotion)) { context in
                let t = context.date.timeIntervalSinceReferenceDate
                GeometryReader { geometry in
                    let drift = reduceMotion ? 0 : CGFloat(sin(t * 0.35)) * 40
                    RadialGradient(
                        colors: [Color.Orttaai.accent.opacity(0.26), Color.Orttaai.accent.opacity(0)],
                        center: UnitPoint(x: 0.5 + drift / max(geometry.size.width, 1), y: 0.55),
                        startRadius: 4,
                        endRadius: geometry.size.width * 0.42
                    )
                }
            }

            content
        }
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(
                    LinearGradient(
                        colors: [Color.Orttaai.accent.opacity(0.35), Color.Orttaai.border.opacity(0.4)],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 1
                )
        )
    }
}

// MARK: - Welcome: voice into text

private struct VoiceToTextScene: View {
    let t: Double

    var body: some View {
        Canvas { context, size in
            let midY = size.height / 2
            let accent = Color.Orttaai.accent

            // Voice: bars that rise and fall, tallest in the middle.
            let barCount = 9
            let barWidth: CGFloat = 5
            let barGap: CGFloat = 6
            let waveCenter = size.width * 0.2
            let waveStart = waveCenter - CGFloat(barCount) * (barWidth + barGap) / 2
            for index in 0..<barCount {
                let envelope = 1 - abs(Double(index) - 4) / 5.5
                let level = abs(sin(t * 2.3 + Double(index) * 0.72)) * envelope
                let height = 10 + CGFloat(level) * 58
                let rect = CGRect(
                    x: waveStart + CGFloat(index) * (barWidth + barGap),
                    y: midY - height / 2,
                    width: barWidth,
                    height: height
                )
                context.fill(
                    Path(roundedRect: rect, cornerRadius: barWidth / 2),
                    with: .linearGradient(
                        Gradient(colors: [accent, accent.opacity(0.45)]),
                        startPoint: CGPoint(x: rect.midX, y: rect.minY),
                        endPoint: CGPoint(x: rect.midX, y: rect.maxY)
                    )
                )
            }

            // The words travel along an arc to the text.
            let from = CGPoint(x: size.width * 0.33, y: midY)
            let to = CGPoint(x: size.width * 0.56, y: midY)
            let control = CGPoint(x: size.width * 0.445, y: midY - 46)
            var arc = Path()
            arc.move(to: from)
            arc.addQuadCurve(to: to, control: control)
            context.stroke(arc, with: .color(accent.opacity(0.16)), style: StrokeStyle(lineWidth: 1, dash: [3, 4]))
            for particle in 0..<7 {
                let phase = (t * 0.5 + Double(particle) / 7).truncatingRemainder(dividingBy: 1)
                let point = quadPoint(from: from, control: control, to: to, at: phase)
                let radius = 2.2 + 1.3 * CGFloat(sin(phase * .pi))
                context.fill(
                    Path(ellipseIn: CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)),
                    with: .color(accent.opacity(sin(phase * .pi)))
                )
            }

            // Text: a card whose lines type themselves, with a caret.
            let card = CGRect(x: size.width * 0.58, y: midY - 42, width: size.width * 0.3, height: 84)
            context.fill(Path(roundedRect: card, cornerRadius: 12), with: .color(Color.Orttaai.textPrimary.opacity(0.05)))
            context.stroke(Path(roundedRect: card, cornerRadius: 12), with: .color(Color.Orttaai.textPrimary.opacity(0.12)), lineWidth: 1)
            let lineWidths: [CGFloat] = [0.86, 0.72, 0.5]
            let typing = min(1.15, (t * 0.32).truncatingRemainder(dividingBy: 1.4)) * 3
            var caret: CGPoint?
            for (index, share) in lineWidths.enumerated() {
                let y = card.minY + 22 + CGFloat(index) * 20
                let full = (card.width - 28) * share
                let typed = full * CGFloat(max(0, min(1, typing - Double(index))))
                let base = CGRect(x: card.minX + 14, y: y - 2.5, width: full, height: 5)
                context.fill(Path(roundedRect: base, cornerRadius: 2.5), with: .color(Color.Orttaai.textPrimary.opacity(0.08)))
                if typed > 0 {
                    context.fill(
                        Path(roundedRect: CGRect(x: base.minX, y: base.minY, width: typed, height: 5), cornerRadius: 2.5),
                        with: .color(Color.Orttaai.textPrimary.opacity(0.75))
                    )
                    caret = CGPoint(x: base.minX + typed + 3, y: y)
                }
            }
            if let caret, sin(t * 7) > -0.2 {
                context.fill(
                    Path(roundedRect: CGRect(x: caret.x, y: caret.y - 7, width: 2, height: 14), cornerRadius: 1),
                    with: .color(accent)
                )
            }
        }
    }

    private func quadPoint(from: CGPoint, control: CGPoint, to: CGPoint, at t: Double) -> CGPoint {
        let u = 1 - t
        return CGPoint(
            x: u * u * from.x + 2 * u * t * control.x + t * t * to.x,
            y: u * u * from.y + 2 * u * t * control.y + t * t * to.y
        )
    }
}

// MARK: - Permissions: a shield with what it guards in orbit

private struct ShieldShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + rect.height * 0.17))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + rect.height * 0.48))
        path.addCurve(
            to: CGPoint(x: rect.midX, y: rect.maxY),
            control1: CGPoint(x: rect.maxX, y: rect.minY + rect.height * 0.78),
            control2: CGPoint(x: rect.midX + rect.width * 0.22, y: rect.maxY - rect.height * 0.06)
        )
        path.addCurve(
            to: CGPoint(x: rect.minX, y: rect.minY + rect.height * 0.48),
            control1: CGPoint(x: rect.midX - rect.width * 0.22, y: rect.maxY - rect.height * 0.06),
            control2: CGPoint(x: rect.minX, y: rect.minY + rect.height * 0.78)
        )
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + rect.height * 0.17))
        path.closeSubpath()
        return path
    }
}

private struct CheckShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.midY + rect.height * 0.05))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.38, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        return path
    }
}

private struct ShieldScene: View {
    let t: Double
    let isComplete: Bool
    @State private var drawn: CGFloat = 0
    @State private var checked: CGFloat = 0

    var body: some View {
        GeometryReader { geometry in
            let center = CGPoint(x: geometry.size.width / 2, y: geometry.size.height / 2)
            let tint = isComplete ? Color.Orttaai.success : Color.Orttaai.accent
            ZStack {
                // Orbits, drifting.
                ForEach(0..<2, id: \.self) { ring in
                    Ellipse()
                        .stroke(
                            Color.Orttaai.textPrimary.opacity(0.13),
                            style: StrokeStyle(lineWidth: 1, dash: [2, 6], dashPhase: CGFloat(t * 10) * (ring == 0 ? 1 : -1))
                        )
                        .frame(width: ring == 0 ? 250 : 170, height: ring == 0 ? 74 : 118)
                        .position(center)
                }

                Glow(color: tint, opacity: isComplete ? 0.4 : 0.28, size: 150)
                    .position(center)

                // The shield draws itself in, then fills when everything is granted.
                ShieldShape()
                    .fill(tint.opacity(isComplete ? 0.22 : 0.1))
                    .frame(width: 70, height: 84)
                    .position(center)
                ShieldShape()
                    .trim(from: 0, to: drawn)
                    .stroke(tint, style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                    .frame(width: 70, height: 84)
                    .position(center)

                if isComplete {
                    CheckShape()
                        .trim(from: 0, to: checked)
                        .stroke(Color.Orttaai.success, style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
                        .frame(width: 28, height: 20)
                        .position(x: center.x, y: center.y + 2)
                } else {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(tint)
                        .scaleEffect(1 + 0.06 * sin(t * 2.4))
                        .position(x: center.x, y: center.y + 2)
                }

                // What the permissions are for, circling the shield.
                orbiter("mic.fill", angle: t * 0.7, radiusX: 125, radiusY: 37, center: center)
                orbiter("cursorarrow.rays", angle: t * 0.7 + .pi, radiusX: 125, radiusY: 37, center: center)
                orbiter("keyboard", angle: -t * 0.5 + .pi / 2, radiusX: 85, radiusY: 59, center: center, small: true)
            }
        }
        .onAppear {
            withAnimation(.easeOut(duration: 1.3)) { drawn = 1 }
            if isComplete { withAnimation(.easeOut(duration: 0.5).delay(0.2)) { checked = 1 } }
        }
        .onChange(of: isComplete) { _, complete in
            checked = 0
            if complete { withAnimation(.easeOut(duration: 0.5)) { checked = 1 } }
        }
    }

    private func orbiter(_ symbol: String, angle: Double, radiusX: CGFloat, radiusY: CGFloat, center: CGPoint, small: Bool = false) -> some View {
        let depth = (sin(angle) + 1) / 2
        let size: CGFloat = small ? 24 : 30
        return Image(systemName: symbol)
            .font(.system(size: small ? 10 : 12, weight: .semibold))
            .foregroundStyle(Color.Orttaai.textPrimary.opacity(0.9))
            .frame(width: size, height: size)
            .background(
                Circle()
                    .fill(Color.Orttaai.bgTertiary)
                    .overlay(Circle().stroke(Color.Orttaai.accent.opacity(0.45), lineWidth: 1))
            )
            .scaleEffect(0.82 + 0.22 * depth)
            .opacity(0.55 + 0.45 * depth)
            .position(x: center.x + radiusX * CGFloat(cos(angle)), y: center.y + radiusY * CGFloat(sin(angle)))
    }
}

// MARK: - Engine: a chip fed by a small network

private struct EngineScene: View {
    let t: Double
    let isComplete: Bool

    var body: some View {
        GeometryReader { geometry in
            let center = CGPoint(x: geometry.size.width / 2, y: geometry.size.height / 2)
            let tint = isComplete ? Color.Orttaai.success : Color.Orttaai.accent
            ZStack {
                Canvas { context, size in
                    let accent = Color.Orttaai.accent
                    for index in 0..<10 {
                        let angle = Double(index) / 10 * 2 * .pi + 0.2
                        let bob = CGFloat(sin(t * 1.3 + Double(index))) * 3
                        let node = CGPoint(
                            x: center.x + 205 * CGFloat(cos(angle)),
                            y: center.y + 54 * CGFloat(sin(angle)) + bob
                        )
                        var line = Path()
                        line.move(to: node)
                        line.addLine(to: center)
                        context.stroke(line, with: .color(Color.Orttaai.textPrimary.opacity(0.09)), lineWidth: 1)

                        // A pulse runs in toward the chip.
                        let phase = (t * 0.55 + Double(index) * 0.17).truncatingRemainder(dividingBy: 1)
                        let point = CGPoint(
                            x: node.x + (center.x - node.x) * CGFloat(phase),
                            y: node.y + (center.y - node.y) * CGFloat(phase)
                        )
                        let alpha = sin(phase * .pi)
                        context.fill(
                            Path(ellipseIn: CGRect(x: point.x - 2.5, y: point.y - 2.5, width: 5, height: 5)),
                            with: .color((isComplete ? Color.Orttaai.success : accent).opacity(alpha))
                        )

                        let nodeRect = CGRect(x: node.x - 4, y: node.y - 4, width: 8, height: 8)
                        context.fill(Path(ellipseIn: nodeRect), with: .color(Color.Orttaai.bgTertiary))
                        context.stroke(Path(ellipseIn: nodeRect), with: .color(accent.opacity(0.6)), lineWidth: 1.2)
                    }
                }

                Glow(color: tint, opacity: 0.3 + 0.15 * sin(t * 2), size: 170)
                    .position(center)

                // The chip, with pins, breathing.
                ZStack {
                    ForEach(0..<4, id: \.self) { side in
                        HStack(spacing: 7) {
                            ForEach(0..<4, id: \.self) { _ in
                                Capsule().fill(tint.opacity(0.7)).frame(width: 2.5, height: 9)
                            }
                        }
                        .offset(y: -40)
                        .rotationEffect(.degrees(Double(side) * 90))
                    }
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.Orttaai.bgTertiary)
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .stroke(tint, lineWidth: 1.5)
                        )
                        .frame(width: 66, height: 66)
                    Image(systemName: isComplete ? "checkmark" : "waveform")
                        .font(.system(size: 24, weight: .bold))
                        .foregroundStyle(tint)
                }
                .position(center)
            }
        }
    }
}

// MARK: - Ready: hold the key, speak

private struct KeyPressScene: View {
    let t: Double

    var body: some View {
        GeometryReader { geometry in
            let center = CGPoint(x: geometry.size.width / 2, y: geometry.size.height / 2 + 14)
            let period = 1.8
            let cycle = t.truncatingRemainder(dividingBy: period) / period
            let press = cycle < 0.12 ? sin(cycle / 0.12 * .pi) : 0
            let accent = Color.Orttaai.accent

            ZStack {
                // Light rays, turning slowly.
                Canvas { context, _ in
                    for index in 0..<16 {
                        let angle = Double(index) / 16 * 2 * .pi + t * 0.15
                        var ray = Path()
                        ray.move(to: CGPoint(x: center.x + 70 * CGFloat(cos(angle)), y: center.y - 8 + 70 * CGFloat(sin(angle))))
                        ray.addLine(to: CGPoint(x: center.x + 84 * CGFloat(cos(angle)), y: center.y - 8 + 84 * CGFloat(sin(angle))))
                        context.stroke(ray, with: .color(accent.opacity(0.22)), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                    }

                    // Rings from each press.
                    for ring in 0..<2 {
                        let phase = (cycle + Double(ring) * 0.5).truncatingRemainder(dividingBy: 1)
                        let radius = 46 + CGFloat(phase) * 110
                        let rect = CGRect(x: center.x - radius, y: center.y - 8 - radius * 0.62, width: radius * 2, height: radius * 1.24)
                        context.stroke(Path(ellipseIn: rect), with: .color(accent.opacity(0.4 * (1 - phase))), lineWidth: 1.5)
                    }

                    // The voice, rising off the key and fading.
                    var wave = Path()
                    let waveY = center.y - 62
                    let amplitude = 12 * (1 - cycle)
                    for step in 0...60 {
                        let x = center.x - 90 + CGFloat(step) * 3
                        let envelope = sin(Double(step) / 60 * .pi)
                        let y = waveY + CGFloat(sin(Double(step) * 0.45 - t * 6) * amplitude * envelope)
                        if step == 0 { wave.move(to: CGPoint(x: x, y: y)) } else { wave.addLine(to: CGPoint(x: x, y: y)) }
                    }
                    context.stroke(wave, with: .color(accent.opacity(0.8)), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                }

                Glow(color: accent, opacity: 0.18 + 0.32 * press, size: 190)
                    .position(center)

                // The key.
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.Orttaai.bgPrimary)
                        .frame(width: 104, height: 64)
                        .offset(y: 6)
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [Color.Orttaai.bgTertiary, Color.Orttaai.bgSecondary],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .stroke(accent.opacity(0.35 + 0.5 * press), lineWidth: 1.2)
                        )
                        .frame(width: 104, height: 64)
                        .offset(y: CGFloat(press) * 5)
                    HStack(spacing: 6) {
                        Image(systemName: "mic.fill")
                            .font(.system(size: 13, weight: .semibold))
                        Text("hold")
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                    }
                    .foregroundStyle(press > 0 ? accent : Color.Orttaai.textPrimary.opacity(0.85))
                    .offset(y: CGFloat(press) * 5)
                }
                .position(center)
            }
        }
    }
}
