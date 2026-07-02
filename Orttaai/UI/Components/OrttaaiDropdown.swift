// OrttaaiDropdown.swift
// Orttaai

import SwiftUI

/// A fully custom dropdown that replaces SwiftUI's `Menu`/`.pickerStyle(.menu)`
/// (which renders native macOS chrome for both the trigger and the popup). Both
/// the closed field and the open option list use the app's design tokens: a
/// bordered `bgSecondary` trigger and a themed popover list with hover and
/// accent-selected rows.
struct OrttaaiDropdown<Value: Hashable>: View {
    struct Option: Identifiable {
        let value: Value
        let label: String
        var id: Value { value }

        init(_ value: Value, _ label: String) {
            self.value = value
            self.label = label
        }
    }

    @Binding var selection: Value
    let options: [Option]
    /// Optional fixed trigger width; when nil the trigger fills its container.
    var width: CGFloat?
    /// Shown when the current selection isn't in `options`.
    var placeholder: String

    @State private var isOpen = false
    @State private var isHovered = false

    init(
        selection: Binding<Value>,
        options: [Option],
        width: CGFloat? = nil,
        placeholder: String = "Select"
    ) {
        self._selection = selection
        self.options = options
        self.width = width
        self.placeholder = placeholder
    }

    private var selectedLabel: String {
        options.first { $0.value == selection }?.label ?? placeholder
    }

    var body: some View {
        Button {
            isOpen.toggle()
        } label: {
            trigger
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .popover(isPresented: $isOpen, arrowEdge: .bottom) {
            optionList
                .presentationBackground(Color.Orttaai.bgSecondary)
        }
    }

    private var trigger: some View {
        HStack(spacing: Spacing.sm) {
            Text(selectedLabel)
                .font(.Orttaai.body)
                .foregroundStyle(Color.Orttaai.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: Spacing.xs)

            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color.Orttaai.textSecondary)
        }
        .padding(.horizontal, Spacing.sm)
        .padding(.vertical, Spacing.sm - 1)
        .frame(width: width, alignment: .leading)
        .frame(maxWidth: width == nil ? .infinity : nil, alignment: .leading)
        .background(Color.Orttaai.bgSecondary)
        .clipShape(RoundedRectangle(cornerRadius: CornerRadius.input))
        .overlay(
            RoundedRectangle(cornerRadius: CornerRadius.input)
                .stroke(
                    (isHovered || isOpen) ? Color.Orttaai.accent.opacity(0.7) : Color.Orttaai.border,
                    lineWidth: BorderWidth.standard
                )
        )
        .contentShape(RoundedRectangle(cornerRadius: CornerRadius.input))
    }

    private var optionList: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(options) { option in
                    OptionRow(
                        label: option.label,
                        isSelected: option.value == selection
                    ) {
                        selection = option.value
                        isOpen = false
                    }
                }
            }
            .padding(Spacing.xs)
        }
        .frame(minWidth: max(200, width ?? 0), maxHeight: 320)
        .background(Color.Orttaai.bgSecondary)
    }

    private struct OptionRow: View {
        let label: String
        let isSelected: Bool
        let action: () -> Void
        @State private var isHovered = false

        var body: some View {
            Button(action: action) {
                HStack(spacing: Spacing.sm) {
                    Text(label)
                        .font(.Orttaai.body)
                        .foregroundStyle(Color.Orttaai.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Spacer(minLength: Spacing.sm)

                    if isSelected {
                        Image(systemName: "checkmark")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Color.Orttaai.accent)
                    }
                }
                .padding(.horizontal, Spacing.sm)
                .padding(.vertical, Spacing.sm - 2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(rowBackground)
                .clipShape(RoundedRectangle(cornerRadius: CornerRadius.input, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: CornerRadius.input, style: .continuous))
            }
            .buttonStyle(.plain)
            .onHover { isHovered = $0 }
        }

        private var rowBackground: Color {
            if isSelected { return Color.Orttaai.accentSubtle }
            if isHovered { return Color.Orttaai.bgTertiary.opacity(0.6) }
            return .clear
        }
    }
}
