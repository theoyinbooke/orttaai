// Spacing.swift
// Orttaai

import SwiftUI

enum Spacing {
    static let xs: CGFloat = 4
    static let sm: CGFloat = 8
    static let md: CGFloat = 12
    static let lg: CGFloat = 16
    static let xl: CGFloat = 20
    static let xxl: CGFloat = 24
    static let xxxl: CGFloat = 32
}

enum WorkspaceLayout {
    /// Page titles live in the window's toolbar strip, so content starts
    /// just below it with this gap.
    static let contentTopPadding: CGFloat = Spacing.lg
    static let contentHorizontalPadding: CGFloat = Spacing.xxl
    static let contentBottomPadding: CGFloat = Spacing.xxl
    static let sidebarHeaderTopPadding: CGFloat = 0

    static let contentInsets = EdgeInsets(
        top: contentTopPadding,
        leading: contentHorizontalPadding,
        bottom: contentBottomPadding,
        trailing: contentHorizontalPadding
    )
}

enum CornerRadius {
    static let card: CGFloat = 8
    static let input: CGFloat = 6
    static let panel: CGFloat = 8
    static let button: CGFloat = 8
}

enum BorderWidth {
    static let standard: CGFloat = 1
    static let focusRing: CGFloat = 2
}

enum WindowSize {
    static let setup = CGSize(width: 600, height: 750)
    /// Wide enough for every page's header and filters without resizing.
    static let home = CGSize(width: 1200, height: 760)
    static let settings = CGSize(width: 920, height: 720)
    static let history = CGSize(width: 480, height: 600)
    static let historyMin = CGSize(width: 480, height: 300)
    /// Wide enough for the hover hint's "Hold or tap …" copy when hands-free
    /// mode is enabled.
    static let floatingPanelHandle = CGSize(width: 372, height: 32)
    /// The one and only recording-pill size: the pill never displays
    /// transcript text and never resizes while recording.
    static let floatingPanelRecording = CGSize(width: 286, height: 42)
    static let floatingPanelProcessing = CGSize(width: 140, height: 28)
    static let floatingPanelError = CGSize(width: 200, height: 28)
}
