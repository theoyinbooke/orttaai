import SwiftUI

struct OrttaaiBrandMark: View {
    var color: Color = .Orttaai.accent

    var body: some View {
        SignalCursorShape()
            .fill(color)
            .aspectRatio(SignalCursorGlyph.aspectRatio, contentMode: .fit)
            .accessibilityHidden(true)
    }
}

struct OrttaaiAppIcon: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Image(colorScheme == .dark ? "BrandIconDark" : "BrandIconLight")
            .resizable()
            .scaledToFit()
            .accessibilityHidden(true)
    }
}

private struct SignalCursorShape: Shape {
    func path(in rect: CGRect) -> Path {
        Path(SignalCursorGlyph.path(in: rect, minimumStroke: rect.width < 24 ? 1 : 0))
    }
}
