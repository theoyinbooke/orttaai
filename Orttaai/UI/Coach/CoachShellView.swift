// CoachShellView.swift
// Orttaai
//
// Coach as a space of its own: the main sidebar steps aside for a slim rail,
// and a floating glass tab bar moves between Coach's pages.

import CoachCore
import SwiftUI

enum CoachTab: String, CaseIterable, Identifiable {
    case today
    case proof

    var id: String { rawValue }

    var title: String {
        switch self {
        case .today: return "Today"
        case .proof: return "Proof"
        }
    }

    var icon: String {
        switch self {
        case .today: return "sun.max"
        case .proof: return "chart.line.uptrend.xyaxis"
        }
    }
}

struct CoachShellView: View {
    @ObservedObject var navigation: HomeNavigationState
    @ObservedObject private var center = CoachCenter.shared
    @AppStorage(CoachPreferences.firstRunDoneKey) private var firstRunDone = false
    @State private var tab: CoachTab = .today
    @State private var sharingWeek = false

    var body: some View {
        HStack(spacing: 0) {
            CoachRail(navigation: navigation)
            ZStack(alignment: .bottom) {
                page
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if center.isEnabled, firstRunDone {
                    CoachTabBar(selection: $tab)
                        .padding(.bottom, 22)
                }
            }
        }
        .background(CoachStyle.ground)
        .preferredColorScheme(.dark)
        .sheet(isPresented: $sharingWeek) {
            if let snapshot = center.snapshot {
                CoachWeekShareSheet(snapshot: snapshot)
            }
        }
        .task { await center.refresh() }
    }

    @ViewBuilder
    private var page: some View {
        if !center.isEnabled {
            CoachOffView()
        } else if !firstRunDone {
            CoachWelcomeView { firstRunDone = true }
        } else if let snapshot = center.snapshot {
            switch tab {
            case .today:
                CoachTodayView(snapshot: snapshot, onShowProof: { tab = .proof }, onShareWeek: { sharingWeek = true })
            case .proof:
                CoachProofView(snapshot: snapshot)
            }
        } else {
            CoachLoadingView()
        }
    }
}

/// Orttaai's sections as icons, so the rest of the app is one click away.
struct CoachRail: View {
    @ObservedObject var navigation: HomeNavigationState

    private let sections: [HomeSection] = [.overview, .chatAI, .graph, .memory, .analytics, .milestones, .coach]

    var body: some View {
        VStack(spacing: 6) {
            OrttaaiBrandMark()
                .frame(width: 26, height: 22)
                .padding(.top, 18)
                .padding(.bottom, 18)
            ForEach(sections) { section in
                railButton(section)
            }
            Spacer(minLength: 0)
            railButton(.settings)
                .padding(.bottom, 18)
        }
        .frame(width: 64)
        .frame(maxHeight: .infinity)
        .background(CoachStyle.rail)
        .overlay(alignment: .trailing) {
            Rectangle().fill(Color.white.opacity(0.05)).frame(width: 1)
        }
    }

    private func railButton(_ section: HomeSection) -> some View {
        let selected = navigation.selectedSection == section
        return Button {
            navigation.selectedSection = section
        } label: {
            Image(systemName: section.icon)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(selected ? Color.Orttaai.accent : CoachStyle.muted)
                .frame(width: 44, height: 44)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(selected ? Color.Orttaai.accent.opacity(0.16) : .clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(section.title)
        .accessibilityLabel(section.title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Coach's pages on a floating Liquid Glass bar.
struct CoachTabBar: View {
    @Binding var selection: CoachTab

    var body: some View {
        HStack(spacing: 6) {
            ForEach(CoachTab.allCases) { tab in
                let selected = tab == selection
                Button {
                    selection = tab
                } label: {
                    Label(tab.title, systemImage: tab.icon)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(selected ? Color(hex: "1B1917") : CoachStyle.ink2)
                        .padding(.horizontal, 18)
                        .frame(height: 44)
                        .background(Capsule().fill(selected ? Color.Orttaai.accent : .clear))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(6)
        .modifier(CoachGlass())
        .shadow(color: .black.opacity(0.4), radius: 20, y: 12)
    }
}

/// Liquid Glass on macOS 26, a thin material before it.
private struct CoachGlass: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular, in: Capsule())
        } else {
            content
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().stroke(Color.white.opacity(0.12), lineWidth: 1))
        }
    }
}

struct CoachLoadingView: View {
    var body: some View {
        VStack(spacing: 12) {
            ProgressView().controlSize(.small)
            Text("Counting your dictations…")
                .font(CoachStyle.label)
                .foregroundStyle(CoachStyle.ink3)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct CoachOffView: View {
    var body: some View {
        VStack(spacing: 16) {
            CoachEyebrow(text: "Coach")
            Text("Coach is off.")
                .font(CoachStyle.display(34))
                .foregroundStyle(CoachStyle.ink)
            Button("Turn on Coach") { CoachPreferences.setEnabled(true) }
                .buttonStyle(CoachPrimaryButtonStyle())
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension EnvironmentValues {
    /// Off only where a page is drawn to an image, which can't hold a
    /// scroll view.
    @Entry var coachPageScrolls = true
}

/// A Coach page: big title, eyebrow, room at the bottom for the tab bar.
struct CoachPage<Accessory: View, Content: View>: View {
    let eyebrow: String
    let title: String
    @ViewBuilder var accessory: () -> Accessory
    @ViewBuilder var content: () -> Content
    @Environment(\.coachPageScrolls) private var scrolls

    var body: some View {
        if scrolls {
            ScrollView(showsIndicators: false) { page }
        } else {
            page.frame(maxHeight: .infinity, alignment: .top)
        }
    }

    private var page: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(alignment: .bottom, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    CoachEyebrow(text: eyebrow)
                    Text(title)
                        .font(CoachStyle.display(36))
                        .foregroundStyle(CoachStyle.ink)
                }
                Spacer(minLength: 0)
                accessory()
            }
            content()
        }
        .padding(.horizontal, 40)
        .padding(.top, 30)
        .padding(.bottom, 120)
        .frame(maxWidth: 1_240, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .center)
    }
}

/// The round ⓘ beside a Coach heading.
struct CoachInfoButton: View {
    let title: String
    let text: String

    var body: some View {
        InfoButton(title: title, text: text)
    }
}
