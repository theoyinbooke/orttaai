// CopyButton.swift
// Orttaai

import SwiftUI

/// A Copy button that confirms the copy: it turns into a green "Copied"
/// checkmark with a small bounce, then settles back after a moment.
struct CopyButton: View {
    var title: String = "Copy"
    var variant: OrttaaiButtonVariant = .primary
    var size: OrttaaiButtonSize = .regular
    let action: () -> Void

    @State private var isCopied = false
    @State private var resetTask: Task<Void, Never>?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button {
            action()
            confirm()
        } label: {
            Label {
                Text(isCopied ? "Copied" : title)
                    .contentTransition(.opacity)
            } icon: {
                Image(systemName: isCopied ? "checkmark.circle.fill" : "doc.on.doc")
                    .contentTransition(.symbolEffect(.replace))
                    .symbolEffect(.bounce, value: isCopied)
            }
            // Inside the label so it wins over the button style's own color.
            .foregroundStyle(isCopied ? AnyShapeStyle(Color.Orttaai.success) : AnyShapeStyle(.primary))
        }
        .buttonStyle(OrttaaiButtonStyle(isCopied ? .secondary : variant, size: size))
        .animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.7), value: isCopied)
        .accessibilityLabel(isCopied ? "Copied" : title)
        .onDisappear { resetTask?.cancel() }
    }

    private func confirm() {
        isCopied = true
        resetTask?.cancel()
        resetTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            guard !Task.isCancelled else { return }
            isCopied = false
        }
    }
}
