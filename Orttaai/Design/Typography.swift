// Typography.swift
// Orttaai

import SwiftUI

extension Font {
    enum Orttaai {
        static let title = Font.system(size: 18, weight: .semibold)
        static let heading = Font.system(size: 16, weight: .semibold)
        static let subheading = Font.system(size: 14, weight: .semibold)
        static let body = Font.system(size: 13)
        static let bodyMedium = Font.system(size: 13, weight: .medium)
        static let secondary = Font.system(size: 12)
        static let caption = Font.system(size: 11)
        static let mono = Font.system(size: 12, design: .monospaced)
        static let monoSmall = Font.system(size: 11, design: .monospaced)
    }
}
