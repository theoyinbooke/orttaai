// MilestoneToastController.swift
// Orttaai

import AppKit
import SwiftUI

/// A small card in the top-right corner when a dictation has just earned a
/// badge, or an edit has just taught Orttaai a word. It never takes focus
/// from the app being dictated into, never appears in the recording pill,
/// and goes away on its own after six seconds (longer while the pointer is
/// over it).
@MainActor
final class MilestoneToastController {
    static let visibleSeconds: Double = 6
    private static let size = CGSize(width: 420, height: 108)

    var onShare: ((MilestoneBadge) -> Void)?
    /// Opens Memory › Suggestions.
    var onReviewSuggestions: (() -> Void)?

    private var panel: NSPanel?
    private var dismissTask: Task<Void, Never>?
    private var isHovered = false

    func show(_ badge: MilestoneBadge, alsoEarned: Int, line: String) {
        present(MilestoneToastView(
            badge: badge,
            line: line,
            alsoEarned: alsoEarned,
            onShare: { [weak self] in
                self?.hide()
                self?.onShare?(badge)
            },
            onDismiss: { [weak self] in self?.hide() },
            onHover: { [weak self] hovering in self?.hoverChanged(hovering) }
        ))
    }

    /// "Learned a word": a name or term fixed right after dictating is now a
    /// suggestion waiting in Memory › Suggestions.
    func showLearnedWord(heard: String, corrected: String, appName: String?, alsoLearned: Int) {
        present(LearnedWordToastView(
            heard: heard,
            corrected: corrected,
            appName: appName,
            alsoLearned: alsoLearned,
            onReview: { [weak self] in
                self?.hide()
                self?.onReviewSuggestions?()
            },
            onDismiss: { [weak self] in self?.hide() },
            onHover: { [weak self] hovering in self?.hoverChanged(hovering) }
        ))
    }

    private func hoverChanged(_ hovering: Bool) {
        isHovered = hovering
        if !hovering { scheduleDismiss() }
    }

    private func present<Content: View>(_ view: Content) {
        let panel = panel ?? makePanel()
        self.panel = panel
        panel.contentView = NSHostingView(rootView: view)
        position(panel)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.25
            panel.animator().alphaValue = 1
        }
        scheduleDismiss()
    }

    func hide() {
        dismissTask?.cancel()
        guard let panel, panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.2
            panel.animator().alphaValue = 0
        }, completionHandler: {
            Task { @MainActor in panel.orderOut(nil) }
        })
    }

    private func scheduleDismiss() {
        dismissTask?.cancel()
        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.visibleSeconds))
            guard !Task.isCancelled, let self, !self.isHovered else { return }
            self.hide()
        }
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: Self.size),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        return panel
    }

    private func position(_ panel: NSPanel) {
        let screen = NSScreen.main ?? NSScreen.screens.first
        guard let frame = screen?.visibleFrame else { return }
        let origin = CGPoint(
            x: frame.maxX - Self.size.width - 12,
            y: frame.maxY - Self.size.height - 8
        )
        panel.setFrame(NSRect(origin: origin, size: Self.size), display: true)
    }
}

struct MilestoneToastView: View {
    let badge: MilestoneBadge
    let line: String
    let alsoEarned: Int
    let onShare: () -> Void
    let onDismiss: () -> Void
    let onHover: (Bool) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var remaining: CGFloat = 1
    @State private var appeared = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                MilestoneBadgeView(badge: badge, state: .unlocked(Date()), size: 48)
                    .scaleEffect(appeared ? 1 : 0.6)
                VStack(alignment: .leading, spacing: 2) {
                    Text(alsoEarned > 0 ? "\(alsoEarned + 1) MILESTONES UNLOCKED" : "MILESTONE UNLOCKED")
                        .font(.system(size: 10.5, weight: .bold))
                        .lineLimit(1)
                        .tracking(0.6)
                        .foregroundStyle(Color(hex: "E8B45A"))
                    Text(badge.name)
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(Color.Orttaai.textPrimary)
                    Text(line)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Color.Orttaai.textSecondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
                Button("Share", action: onShare)
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Color.Orttaai.bgPrimary)
                    .padding(.horizontal, 12)
                    .frame(height: 30)
                    .background(Capsule().fill(Color.Orttaai.accent))
                    .contentShape(Capsule())
                    .pointingHandCursorWhileInactive()
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .frame(width: 26, height: 26)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .pointingHandCursorWhileInactive()
                .foregroundStyle(Color(hex: "8E8E93"))
                .accessibilityLabel("Dismiss")
            }
            .padding(.leading, 14)
            .padding(.trailing, 10)
            .frame(maxHeight: .infinity)

            GeometryReader { geometry in
                Rectangle()
                    .fill(Color.Orttaai.accent)
                    .frame(width: geometry.size.width * remaining)
            }
            .frame(height: 2)
            .background(Color.Orttaai.bgSecondary)
            .accessibilityHidden(true)
        }
        .background(Color(hex: "242428").opacity(0.97))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.Orttaai.bgTertiary, lineWidth: 1)
        )
        .padding(4)
        .onHover(perform: onHover)
        .onAppear {
            withAnimation(reduceMotion ? nil : .spring(response: 0.5, dampingFraction: 0.6)) { appeared = true }
            withAnimation(.linear(duration: MilestoneToastController.visibleSeconds)) { remaining = 0 }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Milestone unlocked: \(badge.name). \(line)")
    }
}

struct LearnedWordToastView: View {
    let heard: String
    let corrected: String
    let appName: String?
    let alsoLearned: Int
    let onReview: () -> Void
    let onDismiss: () -> Void
    let onHover: (Bool) -> Void

    @State private var remaining: CGFloat = 1

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                ZStack {
                    Circle().fill(Color.Orttaai.accentSubtle)
                    Image(systemName: "character.book.closed")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(Color.Orttaai.accent)
                }
                .frame(width: 44, height: 44)
                VStack(alignment: .leading, spacing: 3) {
                    Text(alsoLearned > 0 ? "LEARNED \(alsoLearned + 1) WORDS" : "LEARNED A WORD")
                        .font(.system(size: 10.5, weight: .bold))
                        .tracking(0.6)
                        .foregroundStyle(Color(hex: "E8B45A"))
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        Text(heard)
                            .foregroundStyle(Color.Orttaai.textSecondary)
                            .strikethrough(color: Color.Orttaai.textTertiary)
                            .layoutPriority(1)
                        Image(systemName: "arrow.right")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(Color.Orttaai.textTertiary)
                        Text(corrected)
                            .fontWeight(.bold)
                            .foregroundStyle(Color.Orttaai.textPrimary)
                            .layoutPriority(2)
                    }
                    .font(.system(size: 14))
                    .lineLimit(1)
                    Text(appName.map { "From your fix in \($0)" } ?? "From your fix")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Color.Orttaai.textSecondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
                Button("Review", action: onReview)
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Color.Orttaai.bgPrimary)
                    .padding(.horizontal, 12)
                    .frame(height: 30)
                    .background(Capsule().fill(Color.Orttaai.accent))
                    .contentShape(Capsule())
                    .pointingHandCursorWhileInactive()
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .frame(width: 26, height: 26)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .pointingHandCursorWhileInactive()
                .foregroundStyle(Color(hex: "8E8E93"))
                .accessibilityLabel("Dismiss")
            }
            .padding(.leading, 14)
            .padding(.trailing, 10)
            .frame(maxHeight: .infinity)

            GeometryReader { geometry in
                Rectangle()
                    .fill(Color.Orttaai.accent)
                    .frame(width: geometry.size.width * remaining)
            }
            .frame(height: 2)
            .background(Color.Orttaai.bgSecondary)
            .accessibilityHidden(true)
        }
        .background(Color(hex: "242428").opacity(0.97))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.Orttaai.bgTertiary, lineWidth: 1)
        )
        .padding(4)
        .onHover(perform: onHover)
        .onAppear {
            withAnimation(.linear(duration: MilestoneToastController.visibleSeconds)) { remaining = 0 }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Learned a word: \(heard) to \(corrected). Review in Memory, Suggestions.")
    }
}
