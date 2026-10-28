// WhatsNewCard.swift
// Orttaai

import SwiftUI

/// What's New over the home window, after an update: up to three
/// highlights, one at a time. Next moves on, Skip or the close button puts
/// them all away.
struct WhatsNewHost: View {
    @ObservedObject private var center = WhatsNewCenter.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if let release = center.release {
                Color.black.opacity(0.55)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture {}
                    .transition(.opacity)

                WhatsNewCard(release: release, onClose: center.dismiss)
                    .transition(reduceMotion ? .opacity : .scale(scale: 0.95).combined(with: .opacity))
            }
        }
        .animation(reduceMotion ? nil : .spring(response: 0.4, dampingFraction: 0.88), value: center.release)
    }
}

struct WhatsNewCard: View {
    let release: WhatsNewRelease
    let onClose: () -> Void
    @State private var index = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var items: [WhatsNewItem] { Array(release.items.prefix(WhatsNewCatalog.maxItems)) }
    private var item: WhatsNewItem { items[min(index, items.count - 1)] }
    private var isLast: Bool { index >= items.count - 1 }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            WhatsNewArtView(art: item.art, sceneID: item.id, transition: slide)
                .frame(height: 196)
                .frame(maxWidth: .infinity)
                .overlay(alignment: .topTrailing) { closeButton }

            VStack(alignment: .leading, spacing: 0) {
                Text("WHAT'S NEW IN \(release.version)")
                    .font(.system(size: 11, weight: .bold))
                    .tracking(0.9)
                    .foregroundStyle(Color(hex: "E8B45A"))
                Group {
                    Text(item.title)
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(Color.Orttaai.textPrimary)
                        .padding(.top, 8)
                        .accessibilityAddTraits(.isHeader)
                    Text(item.detail)
                        .font(.system(size: 14))
                        .foregroundStyle(Color(hex: "C7C7CC"))
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 8)
                }
                .id("text-\(item.id)")
                .transition(.opacity)

                Spacer(minLength: 20)
                footer
            }
            .padding(.horizontal, 26)
            .padding(.top, 20)
            .padding(.bottom, 22)
            .frame(height: 210, alignment: .top)
        }
        .frame(width: 420)
        .background(Color(hex: "232325"))
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(Color.Orttaai.bgTertiary, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.5), radius: 30, y: 22)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.28), value: index)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("What's new in Orttaai \(release.version)")
    }

    private var slide: AnyTransition {
        reduceMotion ? .opacity : .asymmetric(
            insertion: .move(edge: .trailing).combined(with: .opacity),
            removal: .move(edge: .leading).combined(with: .opacity)
        )
    }

    private var closeButton: some View {
        Button(action: onClose) {
            Image(systemName: "xmark")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Color.Orttaai.textPrimary)
                .frame(width: 28, height: 28)
                .background(Circle().fill(Color.black.opacity(0.35)))
                .overlay(Circle().strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
        .keyboardShortcut(.cancelAction)
        .padding(12)
        .help("Close")
        .accessibilityLabel("Close What's New")
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if items.count > 1 {
                HStack(spacing: 5) {
                    ForEach(items.indices, id: \.self) { dot in
                        Capsule()
                            .fill(dot == index ? Color.Orttaai.accent : Color(hex: "48484A"))
                            .frame(width: dot == index ? 16 : 6, height: 6)
                    }
                }
                .accessibilityElement()
                .accessibilityLabel("\(index + 1) of \(items.count)")
            }
            Spacer()
            if !isLast {
                Button("Skip", action: onClose)
                    .buttonStyle(.plain)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.Orttaai.textSecondary)
                    .pointingHandCursor()
                    .help("Close What's New")
            }
            Button(isLast ? "Got it" : "Next") {
                if isLast {
                    onClose()
                } else {
                    index += 1
                }
            }
            .buttonStyle(WhatsNewPrimaryButtonStyle())
            .keyboardShortcut(.defaultAction)
        }
    }
}

struct WhatsNewPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .bold))
            .foregroundStyle(Color.Orttaai.bgPrimary)
            .padding(.horizontal, 20)
            .frame(height: 34)
            .background(Capsule().fill(Color.Orttaai.accent))
            .opacity(configuration.isPressed ? 0.8 : 1)
            .contentShape(Capsule())
            .pointingHandCursor()
    }
}

// MARK: - Art

/// The vector picture for a highlight, on a dark panel with an amber glow.
/// The panel stays put; only the picture slides between highlights.
struct WhatsNewArtView: View {
    let art: WhatsNewArt
    var sceneID = ""
    var transition: AnyTransition = .opacity

    var body: some View {
        WhatsNewArtPanel(sceneID: sceneID, transition: transition) { scene }
    }

    @ViewBuilder
    private var scene: some View {
        switch art {
        case .milestones: MilestonesScene()
        case .learning: LearningScene()
        case .updates: UpdatesScene()
        case .symbol(let name): SymbolScene(symbol: name)
        }
    }
}

/// The dark panel with an amber glow and a dot grid that pictures sit on,
/// for What's New and for other cards in its style.
struct WhatsNewArtPanel<Scene: View>: View {
    var sceneID = ""
    var transition: AnyTransition = .opacity
    @ViewBuilder let scene: () -> Scene

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(hex: "2B2A2E"), Color(hex: "1C1C1E")], startPoint: .top, endPoint: .bottom)
            RadialGradient(
                colors: [Color.Orttaai.accent.opacity(0.28), .clear],
                center: .center, startRadius: 4, endRadius: 190
            )
            DotGrid()
                .opacity(0.5)
            scene()
                .id(sceneID)
                .transition(transition)
        }
        .clipped()
        .accessibilityHidden(true)
    }
}

private struct DotGrid: View {
    var body: some View {
        Canvas { context, size in
            let spacing: CGFloat = 16
            var y: CGFloat = spacing / 2
            while y < size.height {
                var x: CGFloat = spacing / 2
                while x < size.width {
                    // Fades toward the edges.
                    let dx = (x - size.width / 2) / (size.width / 2)
                    let dy = (y - size.height / 2) / (size.height / 2)
                    let fade = max(0, 1 - (dx * dx + dy * dy) * 0.8)
                    context.fill(
                        Path(ellipseIn: CGRect(x: x - 0.8, y: y - 0.8, width: 1.6, height: 1.6)),
                        with: .color(.white.opacity(0.10 * fade))
                    )
                    x += spacing
                }
                y += spacing
            }
        }
    }
}

private struct MilestonesScene: View {
    var body: some View {
        ZStack {
            ForEach(0..<16, id: \.self) { index in
                let long = index % 2 == 0
                Capsule()
                    .fill(Color.Orttaai.accent.opacity(0.4))
                    .frame(width: long ? 3 : 1.5, height: long ? 18 : 10)
                    .offset(y: -76)
                    .rotationEffect(.degrees(Double(index) * 22.5))
            }
            Confetti()
            if let badge = MilestoneCatalog.badges.first(where: { $0.id == "words-5k" }) ?? MilestoneCatalog.badges.first {
                MilestoneBadgeView(badge: badge, state: .unlocked(Date()), size: 108)
            }
        }
    }
}

private struct Confetti: View {
    private static let pieces: [(x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat, angle: Double, color: String)] = [
        (-120, -50, 6, 14, 30, "D4952A"), (118, -58, 5, 11, -25, "F5F3F0"),
        (-104, 52, 6, 12, -40, "E2B04A"), (112, 48, 5, 13, 55, "D4952A"),
        (-150, 2, 4, 9, 70, "F5F3F0"), (150, -6, 6, 12, -60, "E2B04A"),
    ]

    var body: some View {
        ForEach(Array(Self.pieces.enumerated()), id: \.offset) { _, piece in
            Capsule()
                .fill(Color(hex: piece.color))
                .frame(width: piece.w, height: piece.h)
                .rotationEffect(.degrees(piece.angle))
                .offset(x: piece.x, y: piece.y)
        }
    }
}

/// "Orta" struck out, then "Orttaai" with the learned-word chip.
private struct LearningScene: View {
    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 10) {
                wordChip("Orta", struck: true)
                Image(systemName: "arrow.right")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Color.Orttaai.textSecondary)
                wordChip("Orttaai", struck: false)
            }
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Color.Orttaai.accent)
                Text("Learned a word")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.Orttaai.textPrimary)
                Text("Review")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color(hex: "E8B45A"))
            }
            .padding(.horizontal, 14)
            .frame(height: 34)
            .background(Capsule().fill(Color(hex: "2C2C2F")))
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
            .shadow(color: .black.opacity(0.35), radius: 10, y: 6)
        }
    }

    private func wordChip(_ word: String, struck: Bool) -> some View {
        Text(word)
            .font(.system(size: 20, weight: .semibold, design: .rounded))
            .strikethrough(struck, color: Color(hex: "FF8A65"))
            .foregroundStyle(struck ? Color.Orttaai.textSecondary : Color.Orttaai.textPrimary)
            .padding(.horizontal, 14)
            .frame(height: 44)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(struck ? Color(hex: "242426") : Color.Orttaai.accent.opacity(0.16))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(struck ? Color.white.opacity(0.08) : Color.Orttaai.accent.opacity(0.6), lineWidth: 1)
            )
    }
}

/// The sidebar's download ring at 72%, and the restart that follows.
private struct UpdatesScene: View {
    var body: some View {
        HStack(spacing: 22) {
            ZStack {
                Circle().stroke(Color(hex: "3A3A3C"), lineWidth: 7)
                Circle()
                    .trim(from: 0, to: 0.72)
                    .stroke(Color.Orttaai.accent, style: StrokeStyle(lineWidth: 7, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Image(systemName: "arrow.down")
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(Color.Orttaai.accent)
            }
            .frame(width: 92, height: 92)

            VStack(alignment: .leading, spacing: 10) {
                row(symbol: "arrow.down", title: "Downloading 72%", filled: false)
                row(symbol: "arrow.clockwise", title: "Restart to update", filled: true)
            }
        }
    }

    private func row(symbol: String, title: String, filled: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(filled ? Color.Orttaai.bgPrimary : Color.Orttaai.accent)
                .frame(width: 20, height: 20)
                .background(Circle().fill(filled ? Color.Orttaai.accent : Color.Orttaai.accent.opacity(0.16)))
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.Orttaai.textPrimary)
                .monospacedDigit()
        }
        .padding(.leading, 6)
        .padding(.trailing, 12)
        .frame(height: 32)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.Orttaai.accent.opacity(filled ? 0.14 : 0.07))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.Orttaai.accent.opacity(filled ? 0.45 : 0.18), lineWidth: 1)
        )
    }
}

private struct SymbolScene: View {
    let symbol: String

    var body: some View {
        ZStack {
            ForEach([150, 116, 84], id: \.self) { size in
                Circle()
                    .strokeBorder(Color.Orttaai.accent.opacity(size == 84 ? 0.5 : 0.18), lineWidth: 1)
                    .frame(width: CGFloat(size), height: CGFloat(size))
            }
            Circle()
                .fill(Color.Orttaai.accent)
                .frame(width: 64, height: 64)
            Image(systemName: symbol)
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(Color.Orttaai.bgPrimary)
        }
    }
}
