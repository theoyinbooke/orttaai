// MilestoneCelebrationView.swift
// Orttaai

import SwiftUI

/// Shows each badge earned since the window was last open, one at a time,
/// over the home window. "Not now" puts them all away; they stay on the
/// Milestones page either way.
struct MilestoneCelebrationHost: View {
    @ObservedObject var navigation: HomeNavigationState
    @ObservedObject private var center = MilestoneCenter.shared
    /// Celebrations wait for What's New to close.
    @ObservedObject private var whatsNew = WhatsNewCenter.shared
    @AppStorage("celebrateMilestones") private var celebrate = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// How many were waiting when this run of celebrations began, for "2 of 6".
    @State private var runTotal = 0

    var body: some View {
        let queue = center.badgesAwaitingCelebration
        ZStack {
            if celebrate, center.hasLoaded, whatsNew.release == nil, navigation.milestoneShareSubject == nil, let badge = queue.first {
                Color.black.opacity(0.62)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture {}
                    .transition(.opacity)

                MilestoneCelebrationCard(
                    badge: badge,
                    line: MilestoneCopy.celebrationLine(for: badge, stats: center.stats),
                    position: max(1, runTotal - queue.count + 1),
                    total: max(runTotal, queue.count),
                    onLater: { center.markCelebrated(queue) },
                    onShare: {
                        center.markCelebrated([badge])
                        navigation.shareMilestone(.badge(badge))
                    },
                    onNext: { center.markCelebrated([badge]) },
                    onSeeAll: {
                        center.markCelebrated(queue)
                        navigation.selectedSection = .milestones
                    }
                )
                .id(badge.id)
                .transition(reduceMotion ? .opacity : .scale(scale: 0.94).combined(with: .opacity))
            }
        }
        .animation(reduceMotion ? nil : .spring(response: 0.42, dampingFraction: 0.86), value: queue.first?.id)
        .onChange(of: queue.count, initial: true) { _, count in
            if count == 0 {
                runTotal = 0
            } else if count > runTotal {
                runTotal = count
            }
        }
    }
}

struct MilestoneCelebrationCard: View {
    let badge: MilestoneBadge
    let line: String
    let position: Int
    let total: Int
    let onLater: () -> Void
    let onShare: () -> Void
    let onNext: () -> Void
    let onSeeAll: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            MilestoneBurst(badge: badge)
                .frame(width: 300, height: 300)

            Text("MILESTONE UNLOCKED")
                .font(.system(size: 12, weight: .bold))
                .tracking(1)
                .foregroundStyle(Color(hex: "E8B45A"))
                .padding(.top, 2)
            Text(badge.name)
                .font(.system(size: 30, weight: .heavy))
                .foregroundStyle(Color.Orttaai.textPrimary)
                .padding(.top, 8)
                .accessibilityAddTraits(.isHeader)
            Text(line)
                .font(.system(size: 15))
                .foregroundStyle(Color(hex: "C7C7CC"))
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 10)

            HStack(spacing: 10) {
                Button("Not now", action: onLater)
                    .buttonStyle(CelebrationButtonStyle(primary: false))
                    .keyboardShortcut(.cancelAction)
                Button(action: onShare) {
                    Label("Share card", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(CelebrationButtonStyle(primary: true))
                .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 24)

            HStack {
                Button("See all milestones", action: onSeeAll)
                    .buttonStyle(.plain)
                    .pointingHandCursor()
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color(hex: "E8B45A"))
                Spacer()
                if total > 1 {
                    Text("\(position) of \(total) new")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.Orttaai.textSecondary)
                    HStack(spacing: 4) {
                        ForEach(0..<min(total, 8), id: \.self) { index in
                            Capsule()
                                .fill(index == position - 1 ? Color.Orttaai.accent : Color(hex: "48484A"))
                                .frame(width: index == position - 1 ? 16 : 6, height: 6)
                        }
                    }
                    .accessibilityHidden(true)
                    Button(action: onNext) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12, weight: .bold))
                            .frame(width: 32, height: 32)
                            .overlay(Circle().strokeBorder(Color.Orttaai.bgTertiary, lineWidth: 1))
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .pointingHandCursor()
                    .foregroundStyle(Color.Orttaai.textPrimary)
                    .accessibilityLabel("Next milestone")
                }
            }
            .padding(.top, 18)
        }
        .padding(.horizontal, 32)
        .padding(.top, 8)
        .padding(.bottom, 28)
        .frame(width: 440)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(Color(hex: "232325"))
                .overlay(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .strokeBorder(Color.Orttaai.bgTertiary, lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.5), radius: 30, y: 24)
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Milestone unlocked: \(badge.name)")
    }
}

private struct CelebrationButtonStyle: ButtonStyle {
    let primary: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: primary ? .bold : .semibold))
            .foregroundStyle(primary ? Color.Orttaai.bgPrimary : Color.Orttaai.textPrimary)
            .frame(maxWidth: .infinity)
            .frame(height: 44)
            .background(
                Capsule().fill(primary ? Color.Orttaai.accent : Color.clear)
            )
            .overlay(
                Capsule().strokeBorder(primary ? Color.clear : Color.Orttaai.bgTertiary, lineWidth: 1)
            )
            .opacity(configuration.isPressed ? 0.8 : 1)
            .contentShape(Capsule())
            .pointingHandCursor()
    }
}

/// The badge popping in, with turning rays, a pulse ring, the brand's
/// rising bars and pieces thrown outward. Still under Reduce Motion.
struct MilestoneBurst: View {
    let badge: MilestoneBadge
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false
    @State private var turning = false
    @State private var pulsing = false
    @State private var flying = false

    private static let pieces: [(dx: CGFloat, dy: CGFloat, w: CGFloat, h: CGFloat, color: String, delay: Double)] = [
        (-110, -70, 8, 18, "D4952A", 0.25), (115, -60, 6, 12, "F5F3F0", 0.35),
        (-95, 90, 8, 14, "E2B04A", 0.45), (100, 95, 6, 16, "D4952A", 0.3),
        (10, -125, 6, 10, "F5F3F0", 0.55), (-130, 10, 8, 12, "E2B04A", 0.65),
        (130, 15, 6, 14, "D4952A", 0.5),
    ]

    var body: some View {
        ZStack {
            rays
                .rotationEffect(.degrees(turning ? 360 : 0))
            if !reduceMotion {
                Circle()
                    .stroke(Color.Orttaai.accent, lineWidth: 2)
                    .frame(width: 160, height: 160)
                    .scaleEffect(pulsing ? 1.5 : 0.7)
                    .opacity(pulsing ? 0 : 0.9)
                ForEach(Array(Self.pieces.enumerated()), id: \.offset) { _, piece in
                    Capsule()
                        .fill(Color(hex: piece.color))
                        .frame(width: piece.w, height: piece.h)
                        .rotationEffect(.degrees(flying ? Double(piece.dx) : 0))
                        .offset(x: flying ? piece.dx : 0, y: flying ? piece.dy : 0)
                        .opacity(flying ? 0 : 1)
                        .animation(.easeOut(duration: 1.8).repeatForever(autoreverses: false).delay(piece.delay), value: flying)
                }
            }
            MilestoneBadgeView(badge: badge, state: .unlocked(Date()), size: 156)
                .scaleEffect(appeared ? 1 : 0.55)
                .opacity(appeared ? 1 : 0)
            bars
                .offset(y: 116)
        }
        .onAppear {
            guard !reduceMotion else {
                appeared = true
                return
            }
            withAnimation(.spring(response: 0.55, dampingFraction: 0.62)) { appeared = true }
            withAnimation(.linear(duration: 24).repeatForever(autoreverses: false)) { turning = true }
            withAnimation(.easeOut(duration: 1.6).repeatForever(autoreverses: false).delay(0.2)) { pulsing = true }
            flying = true
        }
    }

    private var rays: some View {
        ZStack {
            ForEach(0..<16, id: \.self) { index in
                let long = index % 2 == 0
                Capsule()
                    .fill(Color.Orttaai.accent.opacity(0.35))
                    .frame(width: long ? 3 : 1.5, height: long ? 28 : 14)
                    .offset(y: -118)
                    .rotationEffect(.degrees(Double(index) * 22.5))
            }
        }
        .frame(width: 300, height: 300)
        .accessibilityHidden(true)
    }

    private var bars: some View {
        HStack(alignment: .bottom, spacing: 6) {
            bar(height: 20, delay: 0.35)
            bar(height: 30, delay: 0.45)
            bar(height: 40, delay: 0.55)
            bar(height: 42, width: 4, delay: 0.65)
        }
        .frame(height: 42, alignment: .bottom)
        .accessibilityHidden(true)
    }

    private func bar(height: CGFloat, width: CGFloat = 10, delay: Double) -> some View {
        Capsule()
            .fill(Color.Orttaai.accent)
            .frame(width: width, height: height)
            .scaleEffect(x: 1, y: appeared ? 1 : 0, anchor: .bottom)
            .animation(reduceMotion ? nil : .spring(response: 0.5, dampingFraction: 0.6).delay(delay), value: appeared)
    }
}
