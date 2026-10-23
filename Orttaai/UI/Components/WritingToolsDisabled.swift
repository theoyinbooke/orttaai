// WritingToolsDisabled.swift
// Orttaai

import AppKit
import SwiftUI

/// Orttaai's text fields don't show Apple's Writing Tools button. On recent
/// macOS it floats beside the cursor in any field that doesn't opt out,
/// which in a dictation app gets in the way of the text you just spoke.
/// Applied once at each window's root; nothing changes on macOS 14.
struct WritingToolsDisabled: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.writingToolsBehavior(.disabled)
        } else {
            content
        }
    }
}

extension View {
    func writingToolsDisabled() -> some View {
        modifier(WritingToolsDisabled())
    }
}

extension NSTextView {
    /// The same for an AppKit text view, which SwiftUI's setting doesn't
    /// reach: no Writing Tools button and no inline predictions.
    func disableWritingAssistance() {
        if #available(macOS 15.0, *) {
            writingToolsBehavior = .none
        }
        inlinePredictionType = .no
    }
}
