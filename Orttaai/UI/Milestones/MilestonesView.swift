// MilestonesView.swift
// Orttaai

import SwiftUI

/// What a share card is about: a badge, or the person's numbers so far.
enum MilestoneShareSubject: Identifiable, Hashable {
    case progress
    case badge(MilestoneBadge)

    var id: String {
        switch self {
        case .progress: return "progress"
        case .badge(let badge): return badge.id
        }
    }
}

private enum MilestoneFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case unlocked = "Unlocked"
    case inProgress = "In progress"
    case locked = "Locked"

    var id: String { rawValue }
}

struct MilestonesView: View {
    @ObservedObject private var center = MilestoneCenter.shared
    @Binding var shareSubject: MilestoneShareSubject?
    @State private var filter: MilestoneFilter = .all

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: Spacing.xl) {
                hero
                filterBar
                badgeGrid
            }
            .padding(WorkspaceLayout.contentInsets)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.Orttaai.bgPrimary)
        .workspaceHeader("Milestones", leading: { EmptyView() }) {
            Button {
                shareSubject = .progress
            } label: {
                Label("Share progress", systemImage: "square.and.arrow.up")
            }
            .buttonStyle(OrttaaiButtonStyle(.secondary, size: .small))
            .pointingHandCursor(when: center.stats.dictations > 0)
            .disabled(center.stats.dictations == 0)
            .help("Make a card from your numbers so far")
        }
        .task { await center.refresh() }
    }

    // MARK: - Hero

    private var hero: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: Spacing.lg) {
                nextUpCard.frame(maxWidth: .infinity)
                summaryTiles.frame(width: 420)
            }
            VStack(spacing: Spacing.lg) {
                nextUpCard
                summaryTiles
            }
        }
    }

    @ViewBuilder
    private var nextUpCard: some View {
        HStack(spacing: Spacing.xl) {
            if let goal = center.nextGoal {
                MilestoneBadgeView(badge: goal, state: center.state(for: goal), size: 88)
                VStack(alignment: .leading, spacing: 8) {
                    Text("NEXT UP")
                        .font(.system(size: 11, weight: .bold))
                        .tracking(0.8)
                        .foregroundStyle(Color.Orttaai.accent)
                    Text(goal.name)
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(Color.Orttaai.textPrimary)
                    ProgressView(value: center.fraction(of: goal))
                        .progressViewStyle(MilestoneBarStyle())
                        .accessibilityLabel("Progress to \(goal.name)")
                    Text(nextUpDetail(for: goal))
                        .font(.Orttaai.secondary)
                        .foregroundStyle(Color.Orttaai.textSecondary)
                        .lineLimit(2)
                }
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Every badge earned")
                        .font(.system(size: 22, weight: .bold))
                    Text("All 22 milestones are yours. Share the set.")
                        .font(.Orttaai.secondary)
                        .foregroundStyle(Color.Orttaai.textSecondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(Spacing.xl)
        .frame(minHeight: 128)
        .background(cardBackground)
    }

    private func nextUpDetail(for goal: MilestoneBadge) -> String {
        let current = center.stats.value(for: goal.metric)
        var text = goal.progressText(current: current)
        if goal.metric == .words, center.stats.dictations > 0 {
            let perDictation = max(1, center.stats.totalWords / center.stats.dictations)
            let remaining = max(0, goal.threshold - current)
            let dictations = Int((Double(remaining) / Double(perDictation)).rounded(.up))
            if dictations > 0 {
                text += " · about \(dictations.formatted()) more dictation\(dictations == 1 ? "" : "s") at your pace"
            }
        } else if current == 0 {
            text = goal.rule
        }
        return text
    }

    private var summaryTiles: some View {
        HStack(spacing: Spacing.md) {
            tile("\(center.unlockedBadges.count) / \(MilestoneCatalog.badges.count)", "Badges unlocked")
            tile(center.stats.bestWPM > 0 ? "\(center.stats.bestWPM)" : "–", "Best words per minute")
            tile(MilestoneComparisons.durationText(minutes: center.stats.minutesSaved), "Typing time saved")
        }
    }

    private func tile(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value)
                .font(.system(size: 24, weight: .bold))
                .monospacedDigit()
                .foregroundStyle(Color.Orttaai.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(label)
                .font(.Orttaai.caption)
                .foregroundStyle(Color.Orttaai.textSecondary)
                .lineLimit(2)
        }
        .padding(Spacing.lg)
        .frame(maxWidth: .infinity, minHeight: 128, alignment: .leading)
        .background(cardBackground)
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(Color.orttaai(light: "FFFFFF", dark: "232325"))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.Orttaai.border, lineWidth: BorderWidth.standard)
            )
    }

    // MARK: - Filters and grid

    private var filterBar: some View {
        HStack(spacing: 6) {
            ForEach(MilestoneFilter.allCases) { option in
                let selected = filter == option
                Button {
                    filter = option
                } label: {
                    Text("\(option.rawValue) \(count(for: option))")
                        .font(.system(size: 12, weight: selected ? .semibold : .medium))
                        .foregroundStyle(selected ? Color.orttaai(light: "8A5A0F", dark: "E8B45A") : Color.orttaai(light: "5E5A55", dark: "C7C7CC"))
                        .padding(.horizontal, 14)
                        .frame(height: 30)
                        .background(
                            Capsule().fill(selected ? Color.Orttaai.accent.opacity(0.14) : .clear)
                        )
                        .overlay(
                            Capsule().strokeBorder(selected ? Color.Orttaai.accent : Color.Orttaai.border, lineWidth: 1)
                        )
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .pointingHandCursor()
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
    }

    private func count(for option: MilestoneFilter) -> Int {
        MilestoneCatalog.badges.filter { matches($0, option) }.count
    }

    private func matches(_ badge: MilestoneBadge, _ option: MilestoneFilter) -> Bool {
        switch (option, center.state(for: badge)) {
        case (.all, _): return true
        case (.unlocked, .unlocked): return true
        case (.inProgress, .inProgress): return true
        case (.locked, .locked): return true
        default: return false
        }
    }

    private var badgeGrid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: Spacing.md)], spacing: Spacing.md) {
            ForEach(MilestoneCatalog.badges.filter { matches($0, filter) }) { badge in
                MilestoneBadgeCell(badge: badge, state: center.state(for: badge)) {
                    shareSubject = .badge(badge)
                }
            }
        }
    }
}

private struct MilestoneBadgeCell: View {
    let badge: MilestoneBadge
    let state: MilestoneBadgeState
    let onShare: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: onShare) {
            VStack(spacing: 8) {
                MilestoneBadgeView(badge: badge, state: state)
                Text(badge.name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.Orttaai.textPrimary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                Text(status)
                    .font(.system(size: 11))
                    .foregroundStyle(statusColor)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
            }
            .padding(.vertical, 14)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: 168)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(isHovered && state.isUnlocked ? Color.orttaai(light: "FBF7F0", dark: "29292C") : Color.orttaai(light: "FFFFFF", dark: "212123"))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(isHovered && state.isUnlocked ? Color.Orttaai.accent.opacity(0.5) : Color.orttaai(light: "E2DCD2", dark: "2E2E30"), lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .pointingHandCursor(when: state.isUnlocked)
        .disabled(!state.isUnlocked)
        .onHover { isHovered = $0 }
        .help(state.isUnlocked ? "Share a card for \(badge.name)" : badge.rule)
        .accessibilityLabel("\(badge.name), \(status)")
        .accessibilityHint(state.isUnlocked ? "Opens a share card" : "")
    }

    private var status: String {
        switch state {
        case .unlocked(let date):
            return "Unlocked \(date.formatted(.dateTime.month(.abbreviated).day()))"
        case .inProgress(let current, _):
            return badge.progressText(current: current)
        case .locked:
            return badge.rule
        }
    }

    private var statusColor: Color {
        switch state {
        case .unlocked: return Color.Orttaai.textSecondary
        case .inProgress: return Color.orttaai(light: "8A5A0F", dark: "E8B45A")
        case .locked: return Color.orttaai(light: "6B665F", dark: "8E8E93")
        }
    }
}

/// An 8-point amber bar on a dark track.
struct MilestoneBarStyle: ProgressViewStyle {
    func makeBody(configuration: Configuration) -> some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.Orttaai.bgTertiary)
                Capsule()
                    .fill(Color.Orttaai.accent)
                    .frame(width: geometry.size.width * (configuration.fractionCompleted ?? 0))
            }
        }
        .frame(height: 8)
    }
}
