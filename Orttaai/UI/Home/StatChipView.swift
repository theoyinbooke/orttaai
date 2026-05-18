// StatChipView.swift
// Orttaai

import SwiftUI

struct StatChipView: View {
    let label: String
    let value: String
    var showsLabel = true
    @State private var isHovering = false
    @State private var isPinned = false

    var body: some View {
        HStack(spacing: Spacing.xs) {
            Text(value)
                .font(.Orttaai.bodyMedium)
                .foregroundStyle(Color.Orttaai.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
            if showsLabel {
                Text(label)
                    .font(.Orttaai.secondary)
                    .foregroundStyle(Color.Orttaai.textSecondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.sm)
        .background(Color.Orttaai.bgSecondary)
        .clipShape(Capsule())
        .overlay(
            Capsule()
                .stroke(Color.Orttaai.border, lineWidth: BorderWidth.standard)
        )
        .fixedSize(horizontal: true, vertical: false)
        .contentShape(Capsule())
        .onHover { hovering in
            isHovering = hovering
        }
        .onTapGesture {
            isPinned.toggle()
        }
        .popover(
            isPresented: Binding(
                get: { isHovering || isPinned },
                set: { presented in
                    if !presented {
                        isHovering = false
                        isPinned = false
                    }
                }
            ),
            arrowEdge: .top
        ) {
            statDetailCard
        }
        .help("\(value) \(label)")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label) \(value)")
    }

    private var statDetailCard: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Text(displayLabel)
                .font(.Orttaai.caption)
                .foregroundStyle(Color.Orttaai.textSecondary)
                .lineLimit(1)

            Text(value)
                .font(.Orttaai.heading)
                .foregroundStyle(Color.Orttaai.textPrimary)
                .lineLimit(1)
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.sm)
        .frame(minWidth: 132, alignment: .leading)
        .background(Color.Orttaai.bgSecondary)
    }

    private var displayLabel: String {
        switch label {
        case "avg WPM":
            return "Average WPM"
        default:
            return label
                .split(separator: " ")
                .map { word in
                    word.prefix(1).uppercased() + word.dropFirst()
                }
                .joined(separator: " ")
        }
    }
}
