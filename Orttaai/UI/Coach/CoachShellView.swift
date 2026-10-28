// CoachShellView.swift
// Orttaai
//
// Coach as a space of its own: the main sidebar steps aside for a slim rail,
// and a floating glass tab bar moves between Coach's pages.

import CoachCore
import SwiftUI

enum CoachTab: String, CaseIterable, Identifiable {
    case today
    case path
    case studio
    case proof
    case cast

    var id: String { rawValue }

    var title: String {
        switch self {
        case .today: return "Today"
        case .path: return "Path"
        case .studio: return "Studio"
        case .proof: return "Proof"
        case .cast: return "Cast"
        }
    }

    var icon: String {
        switch self {
        case .today: return "sun.max"
        case .path: return "point.topleft.down.to.point.bottomright.curvepath"
        case .studio: return "mic"
        case .proof: return "chart.line.uptrend.xyaxis"
        case .cast: return "person.2"
        }
    }
}

struct CoachShellView: View {
    @ObservedObject var navigation: HomeNavigationState
    @ObservedObject private var center = CoachCenter.shared
    @AppStorage(CoachPreferences.firstRunDoneKey) private var firstRunDone = false
    @State private var tab: CoachTab = .today
    @State private var sharingWeek = false
    @State private var showingMonth = false
    @AppStorage(CoachPreferences.modelSetupSeenKey) private var modelSetupSeen = false

    var body: some View {
        Group {
            if let scene = center.activeScene {
                CoachSceneView(session: scene)
            } else if let session = center.activeSession {
                // A rep is a focus mode: no rail, no tabs.
                CoachSessionView(session: session)
            } else {
                HStack(spacing: 0) {
                    SectionRail(navigation: navigation, look: .coach)
                        .environment(\.colorScheme, .dark)
                    ZStack(alignment: .bottom) {
                        page
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        if center.isEnabled, firstRunDone {
                            CoachTabBar(selection: $tab)
                                .padding(.bottom, 22)
                        }
                    }
                }
            }
        }
        .background(CoachStyle.ground)
        .sheet(isPresented: $sharingWeek) {
            if let snapshot = center.snapshot {
                CoachWeekShareSheet(snapshot: snapshot)
            }
        }
        .overlay { CoachSetupHost() }
        .task {
            await center.refresh()
            await offerModelSetup()
        }
        .onChange(of: firstRunDone) { _, _ in Task { await offerModelSetup() } }
        .onChange(of: tab) { _, _ in showingMonth = false }
    }

    /// The first time Coach opens without its models, it offers to set them up.
    private func offerModelSetup() async {
        guard center.isEnabled, firstRunDone, !modelSetupSeen else { return }
        let setup = CoachModelSetupCenter.shared
        await setup.refresh()
        if !setup.isSetUp { setup.present() }
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
            case .path:
                CoachPathView(snapshot: snapshot)
            case .studio:
                CoachStudioView(snapshot: snapshot)
            case .proof:
                if showingMonth {
                    CoachMonthView { showingMonth = false }
                } else {
                    CoachProofView(snapshot: snapshot) { showingMonth = true }
                }
            case .cast:
                CoachCastView(snapshot: snapshot)
            }
        } else {
            CoachLoadingView()
        }
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
                        .foregroundStyle(selected ? Color.orttaai(light: "FFFFFF", dark: "1B1917") : CoachStyle.ink2)
                        .padding(.horizontal, 16)
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
                .overlay(Capsule().stroke(CoachStyle.wash(0.12), lineWidth: 1))
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
