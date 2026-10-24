// AppUpdateSidebarButton.swift
// Orttaai

import SwiftUI

/// The update at the bottom of the sidebar: "Update available", then the
/// download's percentage on a ring, then the restart. Hidden while there is
/// nothing to say.
struct AppUpdateSidebarButton: View {
    @ObservedObject var updates: AppUpdateService

    var body: some View {
        if updates.phase != .idle {
            AppUpdateSidebarRow(phase: updates.phase, action: updates.performPrimaryAction)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
        }
    }
}

struct AppUpdateSidebarRow: View {
    let phase: AppUpdatePhase
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                AppUpdateIcon(phase: phase)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(Color.Orttaai.textPrimary)
                        .monospacedDigit()
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.Orttaai.textSecondary)
                }
                .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.Orttaai.accent.opacity(isClickable && isHovering ? 0.16 : 0.09))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.Orttaai.accent.opacity(emphasized ? 0.45 : 0.18), lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .pointingHandCursor(when: isClickable)
        .onHover { isHovering = $0 }
        .help(help)
        .accessibilityLabel("\(title). \(subtitle)")
        .accessibilityIdentifier("AppUpdateButton")
    }

    private var isClickable: Bool {
        switch phase {
        case .available, .ready, .failed: return true
        default: return false
        }
    }

    private var emphasized: Bool {
        switch phase {
        case .available, .ready: return true
        default: return false
        }
    }

    private var title: String {
        switch phase {
        case .idle, .checking: return "Checking for updates…"
        case .upToDate: return "You're up to date"
        case .available: return "Update available"
        case .downloading(_, let fraction):
            guard let fraction else { return "Downloading…" }
            return "Downloading \(Int((fraction * 100).rounded(.down)))%"
        case .preparing: return "Preparing update…"
        case .ready: return "Restart to update"
        case .installing: return "Restarting…"
        case .failed: return "Update didn't finish"
        }
    }

    private var subtitle: String {
        switch phase {
        case .idle, .checking: return "Orttaai \(Bundle.main.shortVersion)"
        case .upToDate: return "Orttaai \(Bundle.main.shortVersion) is the latest"
        case .available(let version): return "Version \(version)"
        case .downloading(let version, _), .preparing(let version): return "Version \(version)"
        case .ready(let version): return "Version \(version) is ready"
        case .installing(let version): return "Installing \(version)"
        case .failed: return "Click to try again"
        }
    }

    private var help: String {
        switch phase {
        case .available(let version): return "Download Orttaai \(version), install it and restart"
        case .ready(let version): return "Restart into Orttaai \(version). It also installs when you quit."
        case .failed: return "Check for the update again"
        default: return title
        }
    }
}

/// A ring that fills with the download around the phase's symbol.
private struct AppUpdateIcon: View {
    let phase: AppUpdatePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var spinning = false

    var body: some View {
        ZStack {
            switch phase {
            case .available, .ready:
                Circle().fill(Color.Orttaai.accent)
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Color.Orttaai.bgPrimary)
            case .failed:
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(Color(hex: "FF8A65"))
            case .upToDate:
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(Color.Orttaai.accent)
            case .downloading(_, let fraction?):
                Circle().stroke(Color.Orttaai.bgTertiary, lineWidth: 2.5)
                Circle()
                    .trim(from: 0, to: max(0.02, fraction))
                    .stroke(Color.Orttaai.accent, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeOut(duration: 0.2), value: fraction)
                Image(systemName: "arrow.down")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Color.Orttaai.accent)
            default:
                Circle().stroke(Color.Orttaai.bgTertiary, lineWidth: 2.5)
                Circle()
                    .trim(from: 0, to: 0.28)
                    .stroke(Color.Orttaai.accent, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .rotationEffect(.degrees(spinning ? 270 : -90))
                    .onAppear {
                        guard !reduceMotion else { return }
                        withAnimation(.linear(duration: 0.9).repeatForever(autoreverses: false)) { spinning = true }
                    }
                Image(systemName: symbol)
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Color.Orttaai.accent)
            }
        }
        .frame(width: 24, height: 24)
        .accessibilityHidden(true)
    }

    private var symbol: String {
        switch phase {
        case .ready, .installing: return "arrow.clockwise"
        case .checking, .idle: return "magnifyingglass"
        default: return "arrow.down"
        }
    }
}
