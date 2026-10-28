// SectionRail.swift
// Orttaai
//
// Orttaai's sections as a slim column of icons: what the window shows when
// the sidebar is collapsed, and Coach's own rail, so the rest of the app is
// always one click away.

import SwiftUI

struct SectionRail: View {
    enum Look {
        /// The app's own colours, beside any section.
        case app
        /// Coach's deeper ground.
        case coach
    }

    @ObservedObject var navigation: HomeNavigationState
    var look: Look = .app
    /// Brings the full sidebar back; nil hides the button.
    var onExpand: (() -> Void)?

    static let width: CGFloat = 64
    static let workspace: [HomeSection] = [.overview, .chatAI, .graph, .analytics, .milestones, .coach]
    static let manage: [HomeSection] = [.memory, .model]

    var body: some View {
        VStack(spacing: 6) {
            OrttaaiBrandMark()
                .frame(width: 26, height: 22)
                .padding(.top, 18)
                .padding(.bottom, onExpand == nil ? 18 : 8)
            if let onExpand {
                Button(action: onExpand) {
                    Image(systemName: "sidebar.left")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(muted)
                        .frame(width: 44, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Show the sidebar")
                .accessibilityLabel("Show the sidebar")
                .padding(.bottom, 8)
            }
            ForEach(Self.workspace) { section in
                railButton(section)
            }
            Rectangle()
                .fill(divider)
                .frame(width: 24, height: 1)
                .padding(.vertical, 6)
                .accessibilityHidden(true)
            ForEach(Self.manage) { section in
                railButton(section)
            }
            Spacer(minLength: 0)
            railButton(.settings)
                .padding(.bottom, 18)
        }
        .frame(width: Self.width)
        .frame(maxHeight: .infinity)
        .background(ground)
        .overlay(alignment: .trailing) {
            Rectangle().fill(divider).frame(width: 1)
        }
    }

    private var ground: Color {
        // Solid, so it stays dark beside a light page.
        look == .coach ? CoachStyle.rail : Color(hex: "252527")
    }

    private var muted: Color {
        look == .coach ? CoachStyle.muted : Color.Orttaai.textSecondary
    }

    private var divider: Color {
        look == .coach ? Color.white.opacity(0.05) : Color.Orttaai.border
    }

    private func railButton(_ section: HomeSection) -> some View {
        let selected = navigation.selectedSection == section
        return Button {
            navigation.selectedSection = section
        } label: {
            Image(systemName: section.icon)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(selected ? Color.Orttaai.accent : muted)
                .frame(width: 44, height: 44)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(selected ? Color.Orttaai.accent.opacity(0.16) : .clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(section == .coach ? "Coach (beta)" : section.title)
        .accessibilityLabel(section.title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
