// HeaderSegmentedPicker.swift
// Orttaai

import SwiftUI

/// A compact segmented control sized to sit in a page header beside the
/// section tabs, in the same type and height (Analytics and Memory Graph
/// pick their time range with it).
struct HeaderSegmentedPicker<Option: Hashable & Identifiable>: View {
    let options: [Option]
    @Binding var selection: Option
    let title: (Option) -> String
    var accessibilityTitle = "Time range"
    @Namespace private var highlight

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options) { option in
                Segment(
                    title: title(option),
                    isSelected: selection == option,
                    highlight: highlight
                ) {
                    withAnimation(.easeOut(duration: 0.16)) {
                        selection = option
                    }
                }
            }
        }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: CornerRadius.button, style: .continuous)
                .fill(Color.Orttaai.bgSecondary.opacity(0.55))
        )
        .overlay(
            RoundedRectangle(cornerRadius: CornerRadius.button, style: .continuous)
                .stroke(Color.Orttaai.border.opacity(0.6), lineWidth: BorderWidth.standard)
        )
        .fixedSize()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityTitle)
    }

    private struct Segment: View {
        let title: String
        let isSelected: Bool
        let highlight: Namespace.ID
        let action: () -> Void
        @State private var isHovered = false

        var body: some View {
            Button(action: action) {
                Text(title)
                    .font(.Orttaai.secondary)
                    .lineLimit(1)
                    .foregroundStyle(isSelected || isHovered ? Color.Orttaai.textPrimary : Color.Orttaai.textSecondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background {
                        if isSelected {
                            RoundedRectangle(cornerRadius: CornerRadius.button - 2, style: .continuous)
                                .fill(Color.Orttaai.accentSubtle)
                                .overlay(
                                    RoundedRectangle(cornerRadius: CornerRadius.button - 2, style: .continuous)
                                        .stroke(Color.Orttaai.accent.opacity(0.55), lineWidth: BorderWidth.standard)
                                )
                                .matchedGeometryEffect(id: "selection", in: highlight)
                        }
                    }
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { isHovered = $0 }
            .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        }
    }
}
