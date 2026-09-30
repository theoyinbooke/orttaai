// ShortcutRecorderView.swift
// Orttaai

import SwiftUI
import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    static let pushToTalk = Self("pushToTalk")
    static let editCommand = Self("editCommand")
}

/// The keyboard shortcut recorder at its natural size. It draws its own
/// field, so it gets no extra frame; the row around it supplies the label.
struct ShortcutRecorderField: View {
    let name: KeyboardShortcuts.Name

    var body: some View {
        KeyboardShortcuts.Recorder(for: name)
            .fixedSize()
    }
}
