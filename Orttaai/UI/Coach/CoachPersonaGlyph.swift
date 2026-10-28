// CoachPersonaGlyph.swift
// Orttaai
//
// Each coach's mark: a shape on an amber disc, so coaches read apart without
// faces or extra colours.

import CoachCore
import SwiftUI

struct CoachPersonaGlyph: View {
    let persona: CoachPersona
    var size: CGFloat = 44

    var body: some View {
        let accent = Color.Orttaai.accent
        let line = max(1.4, size / 26)
        ZStack {
            Circle().fill(accent.opacity(0.16))
            switch persona {
            case .mentor:
                Circle().stroke(accent, lineWidth: line).frame(width: size * 0.54, height: size * 0.54)
                Circle().fill(accent).frame(width: size * 0.2, height: size * 0.2)
            case .editor:
                RoundedRectangle(cornerRadius: size * 0.08, style: .continuous)
                    .stroke(accent, lineWidth: line)
                    .frame(width: size * 0.42, height: size * 0.42)
                Capsule().fill(accent).frame(width: size * 0.2, height: line)
            case .socratic:
                Image(systemName: "questionmark")
                    .font(.system(size: size * 0.4, weight: .medium))
                    .foregroundStyle(accent)
            case .sergeant:
                Triangle()
                    .stroke(accent, style: StrokeStyle(lineWidth: line, lineJoin: .round))
                    .frame(width: size * 0.46, height: size * 0.4)
                    .offset(y: -size * 0.02)
            case .peer:
                HStack(spacing: -size * 0.1) {
                    Circle().stroke(accent, lineWidth: line).frame(width: size * 0.3, height: size * 0.3)
                    Circle().stroke(accent, lineWidth: line).frame(width: size * 0.3, height: size * 0.3)
                }
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

private struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}
