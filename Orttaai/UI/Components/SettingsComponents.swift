// SettingsComponents.swift
// Orttaai

import SwiftUI

/// Shared building blocks for every settings-style page. Rows, cards, info
/// affordances and selectors come from here so they size, align and behave
/// the same on every page instead of each view hand-rolling its own boxes.
enum SettingsLayout {
    static let rowMinHeight: CGFloat = 30
    static let rowVerticalPadding: CGFloat = 5
    /// Standard width for a trailing dropdown in a row.
    static let controlWidth: CGFloat = 240
    static let sliderWidth: CGFloat = 200
}

// MARK: - Page

extension View {
    /// Standard padding for the scrolling body of a settings page, aligned
    /// with the page title's leading edge; content fills the window's width
    /// like every other page.
    func settingsPageLayout() -> some View {
        self
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, WorkspaceLayout.contentHorizontalPadding)
            .padding(.top, Spacing.lg)
            .padding(.bottom, WorkspaceLayout.contentBottomPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Title, tab bar and a scrolling body: the frame shared by the Settings and
/// Model pages so both switch sections the same way.
struct TabbedWorkspacePage<Tab: Hashable & Identifiable, Content: View>: View {
    let title: String
    let tabs: [Tab]
    @Binding var selection: Tab
    let tabTitle: (Tab) -> String
    let tabIcon: (Tab) -> String
    @ViewBuilder let content: (Tab) -> Content

    var body: some View {
        ScrollView(showsIndicators: false) {
            content(selection)
                .settingsPageLayout()
        }
        .id(selection)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.Orttaai.bgPrimary)
        .workspaceHeader(title) {
            OrttaaiTabBar(
                tabs: tabs,
                selection: $selection,
                title: tabTitle,
                icon: tabIcon
            )
        }
    }
}

struct OrttaaiTabBar<Tab: Hashable & Identifiable>: View {
    let tabs: [Tab]
    @Binding var selection: Tab
    let title: (Tab) -> String
    let icon: (Tab) -> String

    var body: some View {
        HStack(spacing: Spacing.sm) {
            ForEach(tabs) { tab in
                TabButton(
                    title: title(tab),
                    icon: icon(tab),
                    isSelected: selection == tab
                ) {
                    withAnimation(.easeOut(duration: 0.16)) {
                        selection = tab
                    }
                }
            }
        }
    }

    private struct TabButton: View {
        let title: String
        let icon: String
        let isSelected: Bool
        let action: () -> Void
        @State private var isHovered = false

        var body: some View {
            Button(action: action) {
                HStack(spacing: Spacing.xs) {
                    Image(systemName: icon)
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 14)
                        .accessibilityHidden(true)

                    Text(title)
                        .font(.Orttaai.secondary)
                        .lineLimit(1)
                }
                .foregroundStyle(isSelected || isHovered ? Color.Orttaai.textPrimary : Color.Orttaai.textSecondary)
                .padding(.horizontal, Spacing.md)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: CornerRadius.button, style: .continuous)
                        .fill(isSelected ? Color.Orttaai.accentSubtle : Color.Orttaai.bgSecondary.opacity(0.55))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: CornerRadius.button, style: .continuous)
                        .stroke(
                            isSelected ? Color.Orttaai.accent.opacity(0.55) : Color.Orttaai.border.opacity(0.6),
                            lineWidth: BorderWidth.standard
                        )
                )
                .contentShape(RoundedRectangle(cornerRadius: CornerRadius.button, style: .continuous))
            }
            .buttonStyle(.plain)
            .onHover { isHovered = $0 }
            .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        }
    }
}

// MARK: - Cards and rows

/// A titled group of rows. The optional accessory sits at the trailing edge
/// of the title line (a status chip or a small action).
struct SettingsCard<Content: View, Accessory: View>: View {
    let title: String?
    let info: String?
    let accessory: Accessory
    let content: Content

    init(
        _ title: String? = nil,
        info: String? = nil,
        @ViewBuilder accessory: () -> Accessory,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.info = info
        self.accessory = accessory()
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let title {
                HStack(alignment: .center, spacing: Spacing.sm) {
                    SettingsLabel(title: title, info: info, font: .Orttaai.subheading)
                        .accessibilityAddTraits(.isHeader)
                    Spacer(minLength: Spacing.sm)
                    accessory
                }
                .frame(minHeight: 26)
                .padding(.bottom, Spacing.xs)
            }

            content
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.sm + 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .dashboardCard()
    }
}

extension SettingsCard where Accessory == EmptyView {
    init(_ title: String? = nil, info: String? = nil, @ViewBuilder content: () -> Content) {
        self.init(title, info: info, accessory: { EmptyView() }, content: content)
    }
}

/// A row title with an optional info icon that explains the setting.
struct SettingsLabel: View {
    let title: String
    var info: String?
    var font: Font = .Orttaai.bodyMedium

    var body: some View {
        HStack(spacing: 5) {
            Text(title)
                .font(font)
                .foregroundStyle(Color.Orttaai.textPrimary)
                .lineLimit(1)

            if let info {
                InfoButton(title: title, text: info)
            }
        }
    }
}

/// Label on the leading edge, any control on the trailing edge.
struct SettingsRow<Control: View>: View {
    let title: String
    var info: String?
    @ViewBuilder let control: () -> Control

    var body: some View {
        HStack(alignment: .center, spacing: Spacing.sm) {
            SettingsLabel(title: title, info: info)
            Spacer(minLength: Spacing.md)
            control()
        }
        .frame(minHeight: SettingsLayout.rowMinHeight)
        .padding(.vertical, SettingsLayout.rowVerticalPadding)
    }
}

struct SettingsToggleRow: View {
    let title: String
    var info: String?
    @Binding var isOn: Bool

    var body: some View {
        SettingsRow(title: title, info: info) {
            OrttaaiSwitch(title: title, isOn: $isOn)
        }
    }
}

/// A slider with its current value, kept on one compact line.
struct SettingsSliderRow: View {
    let title: String
    var info: String?
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let valueText: String

    var body: some View {
        SettingsRow(title: title, info: info) {
            HStack(spacing: Spacing.sm) {
                // Stepping is applied in the binding: a stepped Slider draws a
                // tick mark per step, which is visual noise at this width.
                Slider(value: steppedValue, in: range)
                    .tint(Color.Orttaai.accent)
                    .frame(width: SettingsLayout.sliderWidth)
                    .accessibilityLabel(title)
                    .accessibilityValue(valueText)

                Text(valueText)
                    .font(.Orttaai.mono)
                    .foregroundStyle(Color.Orttaai.textPrimary)
                    .frame(minWidth: 56, alignment: .trailing)
                    .accessibilityHidden(true)
            }
        }
    }

    private var steppedValue: Binding<Double> {
        Binding(
            get: { value },
            set: { newValue in
                let steps = ((newValue - range.lowerBound) / step).rounded()
                value = min(range.upperBound, max(range.lowerBound, range.lowerBound + steps * step))
            }
        )
    }
}

struct SettingsStepperRow: View {
    let title: String
    var info: String?
    @Binding var value: Int
    let range: ClosedRange<Int>
    var step: Int = 1
    var format: (Int) -> String = { "\($0)" }

    var body: some View {
        SettingsRow(title: title, info: info) {
            OrttaaiStepper(title: title, value: $value, range: range, step: step, format: format)
        }
    }
}

struct SettingsDivider: View {
    var body: some View {
        Divider()
            .overlay(Color.Orttaai.border.opacity(0.6))
    }
}

/// Secondary explanatory text inside a card, below the row it describes.
struct SettingsFootnote: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.Orttaai.caption)
            .foregroundStyle(Color.Orttaai.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.bottom, Spacing.xs)
    }
}

// MARK: - Info

/// Small info icon beside a label. Hover shows a tooltip; clicking opens a
/// popover so the explanation is also reachable without a mouse hover.
struct InfoButton: View {
    let title: String
    let text: String
    @State private var isPresented = false
    @State private var isHovered = false

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            Image(systemName: "info.circle")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(
                    isHovered || isPresented ? Color.Orttaai.textSecondary : Color.Orttaai.textTertiary
                )
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(text)
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            Text(text)
                .font(.Orttaai.secondary)
                .foregroundStyle(Color.Orttaai.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: 260, alignment: .leading)
                .padding(Spacing.md)
                .presentationBackground(Color.Orttaai.bgSecondary)
        }
        .accessibilityLabel("About \(title)")
        .accessibilityHint(text)
    }
}

// MARK: - Controls

/// The app's on/off switch as a standalone control. `OrttaaiToggleStyle`
/// draws the same track, so every switch in the app looks identical.
struct OrttaaiSwitch: View {
    let title: String
    @Binding var isOn: Bool

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            OrttaaiSwitchTrack(isOn: isOn)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(isOn ? "On" : "Off")
        .accessibilityAddTraits(.isToggle)
    }
}

struct OrttaaiSwitchTrack: View {
    let isOn: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: 10)
            .fill(isOn ? Color.Orttaai.accent : Color.Orttaai.bgTertiary)
            .frame(width: 36, height: 20)
            .overlay(alignment: isOn ? .trailing : .leading) {
                Circle()
                    .fill(.white)
                    .frame(width: 16, height: 16)
                    .padding(2)
            }
            .animation(.easeOut(duration: 0.15), value: isOn)
            .contentShape(RoundedRectangle(cornerRadius: 10))
    }
}

/// Compact segmented selector drawn with the app's tokens, replacing the
/// native segmented picker and coarse full-width sliders.
struct OrttaaiSegmentedControl<Value: Hashable>: View {
    struct Option: Identifiable {
        let value: Value
        let label: String
        var id: Value { value }

        init(_ value: Value, _ label: String) {
            self.value = value
            self.label = label
        }
    }

    let title: String
    @Binding var selection: Value
    let options: [Option]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options) { option in
                Segment(
                    label: option.label,
                    isSelected: option.value == selection
                ) {
                    withAnimation(.easeOut(duration: 0.12)) {
                        selection = option.value
                    }
                }
            }
        }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: CornerRadius.input, style: .continuous)
                .fill(Color.Orttaai.bgPrimary.opacity(0.55))
        )
        .overlay(
            RoundedRectangle(cornerRadius: CornerRadius.input, style: .continuous)
                .stroke(Color.Orttaai.border, lineWidth: BorderWidth.standard)
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }

    private struct Segment: View {
        let label: String
        let isSelected: Bool
        let action: () -> Void
        @State private var isHovered = false

        var body: some View {
            Button(action: action) {
                Text(label)
                    .font(isSelected ? .Orttaai.secondary.weight(.semibold) : .Orttaai.secondary)
                    .foregroundStyle(isSelected ? Color.Orttaai.accent : (isHovered ? Color.Orttaai.textPrimary : Color.Orttaai.textSecondary))
                    .lineLimit(1)
                    // A choice is never truncated; surrounding content yields.
                    .fixedSize()
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: CornerRadius.input - 2, style: .continuous)
                            .fill(
                                isSelected
                                    ? Color.Orttaai.accentSubtle
                                    : (isHovered ? Color.Orttaai.bgTertiary.opacity(0.5) : .clear)
                            )
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { isHovered = $0 }
            .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        }
    }
}

/// Compact minus / value / plus control drawn with the app's tokens.
struct OrttaaiStepper: View {
    let title: String
    @Binding var value: Int
    let range: ClosedRange<Int>
    var step: Int = 1
    var format: (Int) -> String = { "\($0)" }

    var body: some View {
        HStack(spacing: 0) {
            stepButton("minus", enabled: value > range.lowerBound) { decrement() }

            Text(format(value))
                .font(.Orttaai.mono)
                .foregroundStyle(Color.Orttaai.textPrimary)
                .frame(minWidth: 64)
                .padding(.vertical, 4)

            stepButton("plus", enabled: value < range.upperBound) { increment() }
        }
        .background(
            RoundedRectangle(cornerRadius: CornerRadius.input, style: .continuous)
                .fill(Color.Orttaai.bgPrimary.opacity(0.55))
        )
        .overlay(
            RoundedRectangle(cornerRadius: CornerRadius.input, style: .continuous)
                .stroke(Color.Orttaai.border, lineWidth: BorderWidth.standard)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(format(value))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: increment()
            case .decrement: decrement()
            @unknown default: break
            }
        }
    }

    private func increment() {
        value = min(range.upperBound, value + step)
    }

    private func decrement() {
        value = max(range.lowerBound, value - step)
    }

    private func stepButton(_ systemImage: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(enabled ? Color.Orttaai.textSecondary : Color.Orttaai.textTertiary.opacity(0.5))
                .frame(width: 26, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}

/// A "Check" button that reports the result of the check it runs: green
/// "Ready" when it passes, "Retry" when it fails. The full status message is
/// its tooltip, so the row needs no status text of its own.
struct ConnectionCheckButton: View {
    let isChecking: Bool
    /// nil until the first check finishes.
    let isReady: Bool?
    let message: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Spacing.xs) {
                if isChecking {
                    ProgressView()
                        .controlSize(.mini)
                } else {
                    Image(systemName: iconName)
                        .foregroundStyle(tint)
                }
                Text(label)
                    .foregroundStyle(isChecking ? Color.Orttaai.textSecondary : tint)
                    .lineLimit(1)
            }
        }
        .buttonStyle(OrttaaiButtonStyle(.secondary, size: .small))
        .fixedSize()
        .disabled(isChecking)
        .help(message)
        .accessibilityLabel("Connection: \(label)")
        .accessibilityHint(message)
    }

    private var label: String {
        if isChecking { return "Checking…" }
        switch isReady {
        case .some(true): return "Ready"
        case .some(false): return "Retry"
        case .none: return "Check"
        }
    }

    private var iconName: String {
        switch isReady {
        case .some(true): return "checkmark.circle.fill"
        case .some(false): return "exclamationmark.circle.fill"
        case .none: return "bolt.horizontal.circle"
        }
    }

    private var tint: Color {
        switch isReady {
        case .some(true): return Color.Orttaai.success
        case .some(false): return Color.Orttaai.warning
        case .none: return Color.Orttaai.textPrimary
        }
    }
}

// MARK: - Notices

/// Inline status message shown next to the action that produced it.
struct SettingsNotice: View {
    enum Kind {
        case error
        case warning
        case success
        case info
    }

    let kind: Kind
    let message: String
    var onDismiss: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.sm) {
            Image(systemName: iconName)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tint)
                .padding(.top, 1)
                .accessibilityHidden(true)

            Text(message)
                .font(.Orttaai.secondary)
                .foregroundStyle(kind == .info ? Color.Orttaai.textSecondary : tint)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)

            Spacer(minLength: 0)

            if let onDismiss {
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Color.Orttaai.textSecondary)
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss")
            }
        }
        .padding(.horizontal, Spacing.sm + 2)
        .padding(.vertical, Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: CornerRadius.input, style: .continuous)
                .fill(tint.opacity(kind == .info ? 0.06 : 0.1))
        )
        .overlay(
            RoundedRectangle(cornerRadius: CornerRadius.input, style: .continuous)
                .stroke(tint.opacity(0.28), lineWidth: BorderWidth.standard)
        )
        .padding(.vertical, Spacing.xs)
        .accessibilityElement(children: .combine)
    }

    private var tint: Color {
        switch kind {
        case .error: return Color.Orttaai.error
        case .warning: return Color.Orttaai.warning
        case .success: return Color.Orttaai.success
        case .info: return Color.Orttaai.textTertiary
        }
    }

    private var iconName: String {
        switch kind {
        case .error: return "exclamationmark.triangle.fill"
        case .warning: return "exclamationmark.circle.fill"
        case .success: return "checkmark.circle.fill"
        case .info: return "info.circle"
        }
    }
}

/// Small colored capsule for a status on a card's title line.
struct StatusChip: View {
    let title: String
    let systemImage: String
    let tint: Color

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.Orttaai.caption)
            .foregroundStyle(tint)
            .padding(.horizontal, Spacing.sm)
            .padding(.vertical, 3)
            .background(tint.opacity(0.1))
            .clipShape(Capsule())
    }
}
