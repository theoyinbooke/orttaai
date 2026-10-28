// OrttaaiDropdown.swift
// Orttaai

import SwiftUI

/// A fully custom dropdown that replaces SwiftUI's `Menu`/`.pickerStyle(.menu)`
/// (which renders native macOS chrome for both the trigger and the popup). Both
/// the closed field and the open option list use the app's design tokens: a
/// bordered `bgSecondary` trigger and a themed popover list with hover and
/// accent-selected rows. Options can carry a detail line, and a long list
/// can be searched.
struct OrttaaiDropdown<Value: Hashable>: View {
    struct Option: Identifiable {
        let value: Value
        let label: String
        /// A second line under the label, such as a model's grade.
        var detail: String?
        /// Draws the detail in the warning colour.
        var warns = false
        var id: Value { value }

        init(_ value: Value, _ label: String, detail: String? = nil, warns: Bool = false) {
            self.value = value
            self.label = label
            self.detail = detail
            self.warns = warns
        }
    }

    @Binding var selection: Value
    let options: [Option]
    /// Optional fixed trigger width; when nil the trigger fills its container.
    var width: CGFloat?
    /// Shown when the current selection isn't in `options`.
    var placeholder: String
    /// Shown on the closed field in place of the option's label.
    var triggerLabel: String?
    /// When set, the open list has a search field with this prompt.
    var searchPrompt: String?

    @State private var isOpen = false
    @State private var query = ""
    @State private var isHovered = false
    /// The field's width, so the list drops down exactly as wide as it.
    @State private var triggerWidth: CGFloat = 0

    init(
        selection: Binding<Value>,
        options: [Option],
        width: CGFloat? = nil,
        placeholder: String = "Select",
        triggerLabel: String? = nil,
        searchPrompt: String? = nil
    ) {
        self._selection = selection
        self.options = options
        self.width = width
        self.placeholder = placeholder
        self.triggerLabel = triggerLabel
        self.searchPrompt = searchPrompt
    }

    private var selectedLabel: String {
        triggerLabel ?? options.first { $0.value == selection }?.label ?? placeholder
    }

    private var shownOptions: [Option] {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return options }
        return options.filter { $0.label.localizedCaseInsensitiveContains(text) }
    }

    var body: some View {
        Button {
            isOpen.toggle()
        } label: {
            trigger
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
        .onHover { isHovered = $0 }
        .popover(isPresented: $isOpen, arrowEdge: .bottom) {
            VStack(spacing: 0) {
                if let searchPrompt {
                    HStack(spacing: Spacing.xs) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 12))
                            .foregroundStyle(Color.Orttaai.textSecondary)
                        TextField(searchPrompt, text: $query)
                            .textFieldStyle(.plain)
                            .font(.Orttaai.body)
                            .foregroundStyle(Color.Orttaai.textPrimary)
                    }
                    .padding(.horizontal, Spacing.sm)
                    .padding(.vertical, Spacing.sm)
                    Divider().overlay(Color.Orttaai.border)
                }
                optionList
            }
            .frame(width: max(200, width ?? triggerWidth))
            .presentationBackground(Color.Orttaai.bgSecondary)
            .onDisappear { query = "" }
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
        .background(
            GeometryReader { geometry in
                Color.clear
                    .onAppear { triggerWidth = geometry.size.width }
                    .onChange(of: geometry.size.width) { _, newWidth in triggerWidth = newWidth }
            }
        )
    }

    private var optionList: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(shownOptions) { option in
                    OptionRow(
                        label: option.label,
                        detail: option.detail,
                        warns: option.warns,
                        isSelected: option.value == selection
                    ) {
                        selection = option.value
                        isOpen = false
                    }
                }
                if shownOptions.isEmpty {
                    Text("No matches")
                        .font(.Orttaai.body)
                        .foregroundStyle(Color.Orttaai.textSecondary)
                        .padding(Spacing.sm)
                }
            }
            .padding(Spacing.xs)
        }
        .frame(width: max(200, width ?? triggerWidth))
        .frame(maxHeight: 360)
        .background(Color.Orttaai.bgSecondary)
    }

    private struct OptionRow: View {
        let label: String
        var detail: String?
        var warns = false
        let isSelected: Bool
        let action: () -> Void
        @State private var isHovered = false

        var body: some View {
            Button(action: action) {
                HStack(spacing: Spacing.sm) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(label)
                            .font(.Orttaai.body)
                            .foregroundStyle(Color.Orttaai.textPrimary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if let detail {
                            Text(detail)
                                .font(.system(size: 11))
                                .foregroundStyle(warns ? Color.Orttaai.warning : Color.Orttaai.textSecondary)
                                .lineLimit(1)
                        }
                    }

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
            .pointingHandCursor()
            .onHover { isHovered = $0 }
        }

        private var rowBackground: Color {
            if isSelected { return Color.Orttaai.accentSubtle }
            if isHovered { return Color.Orttaai.bgTertiary.opacity(0.6) }
            return .clear
        }
    }
}
