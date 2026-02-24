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
    static let setup = CGSize(width: 600, height: 500)
    static let home = CGSize(width: 900, height: 680)
    static let settings = CGSize(width: 500, height: 400)
    static let history = CGSize(width: 480, height: 600)
    static let historyMin = CGSize(width: 480, height: 300)
    static let floatingPanelHandle = CGSize(width: 260, height: 32)
    static let floatingPanelRecording = CGSize(width: 120, height: 32)
    static let floatingPanelProcessing = CGSize(width: 140, height: 28)
    static let floatingPanelError = CGSize(width: 200, height: 28)
}
