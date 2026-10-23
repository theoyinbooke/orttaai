// SetupView.swift
// Orttaai

import SwiftUI

/// First-run setup in four steps. Each step shows a connected step track,
/// an animated scene for what it does, one title line, its content, and a
/// footer that says what's still needed before Continue.
struct SetupView: View {
    @State private var currentStep = 0
    @State private var permissionsGranted = false
    @State private var modelReady = false
    @State private var didActivateReadyTest = false
    /// Which way the last step change went, so content slides with it.
    @State private var movingForward = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var onComplete: (() -> Void)?
    var onReadyForTesting: (() -> Void)?

    private let steps = ["Welcome", "Permissions", "Engine", "Ready"]

    private var canContinue: Bool {
        switch currentStep {
        case 1: return permissionsGranted
        case 2: return modelReady
        default: return true
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            SetupStepTrack(titles: steps, current: currentStep)
                .padding(.horizontal, 40)
                .padding(.top, Spacing.lg)

            // The stage stays; only the scene inside cross-fades.
            SetupStepArt(step: currentStep, isComplete: isStepComplete)
                .frame(height: 148)
                .padding(.horizontal, 28)
                .padding(.top, Spacing.md)

            ZStack {
                VStack(spacing: 0) {
                    VStack(spacing: 5) {
                        Text(title)
                            .font(.system(size: 22, weight: .semibold, design: .rounded))
                            .foregroundStyle(Color.Orttaai.textPrimary)
                        Text(subtitle)
                            .font(.Orttaai.secondary)
                            .foregroundStyle(Color.Orttaai.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
                    .padding(.top, Spacing.md)

                    ScrollView(showsIndicators: false) {
                        stepContent
                            .padding(.horizontal, 28)
                            .padding(.top, Spacing.md)
                            .padding(.bottom, Spacing.lg)
                    }
                }
                .id(currentStep)
                .transition(stepTransition)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .clipped()

            footer
        }
        // The window takes its size from this view. A fixed size keeps it at
        // 600 x 750 on every step; long steps scroll instead of stretching
        // the window past the screen and hiding the footer.
        .frame(width: WindowSize.setup.width, height: WindowSize.setup.height)
        .background(Color.Orttaai.bgPrimary)
        .onChange(of: currentStep) { _, newValue in
            guard newValue == 3 else { return }
            activateReadyTestIfNeeded()
        }
        .task {
            // Ready before the Engine step, off the main thread.
            await Task.detached(priority: .utility) { _ = DownloadStepView.hardwareInfo }.value
        }
    }

    // MARK: - Steps

    private var title: String {
        switch currentStep {
        case 0: return "Welcome to Orttaai"
        case 1: return "Two quick permissions"
        case 2: return "Choose your voice engine"
        default: return "You're ready"
        }
    }

    private var subtitle: String {
        switch currentStep {
        case 0: return "Hold a key, speak, and Orttaai types it into any app. Privately, on this Mac."
        case 1: return "The microphone so it can hear you, and Accessibility so it can type where your cursor is."
        case 2: return "It runs entirely on this Mac. Pick one now; you can switch any time."
        default: return "Try your first dictation right here, then start using Orttaai."
        }
    }

    private var isStepComplete: Bool {
        switch currentStep {
        case 1: return permissionsGranted
        case 2: return modelReady
        default: return false
        }
    }

    @ViewBuilder
    private var stepContent: some View {
        switch currentStep {
        case 0:
            AboutSetupStepView()
        case 1:
            PermissionStepView(allGranted: $permissionsGranted)
        case 2:
            DownloadStepView(isModelReady: $modelReady)
        case 3:
            ReadyStepView(onStart: {
                onComplete?()
            })
            .onAppear {
                activateReadyTestIfNeeded()
            }
        default:
            EmptyView()
        }
    }

    private var stepTransition: AnyTransition {
        guard !reduceMotion else { return .opacity }
        return .asymmetric(
            insertion: .move(edge: movingForward ? .trailing : .leading).combined(with: .opacity),
            removal: .move(edge: movingForward ? .leading : .trailing).combined(with: .opacity)
        )
    }

    private func go(to step: Int) {
        movingForward = step > currentStep
        withAnimation(reduceMotion ? .easeInOut(duration: 0.2) : .spring(response: 0.45, dampingFraction: 0.86)) {
            currentStep = step
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: Spacing.md) {
            if currentStep > 0 {
                Button {
                    go(to: currentStep - 1)
                } label: {
                    Label("Back", systemImage: "chevron.left")
                }
                .buttonStyle(OrttaaiButtonStyle(.ghost))
            }

            Spacer(minLength: Spacing.sm)

            if let hint = continueHint {
                Text(hint)
                    .font(.Orttaai.caption)
                    .foregroundStyle(Color.Orttaai.textTertiary)
                    .lineLimit(1)
                    .transition(.opacity)
            }

            if currentStep < steps.count - 1 {
                Button {
                    go(to: currentStep + 1)
                } label: {
                    HStack(spacing: 6) {
                        Text(currentStep == 0 ? "Get Started" : "Continue")
                        Image(systemName: "arrow.right")
                            .font(.system(size: 11, weight: .bold))
                    }
                }
                .buttonStyle(OrttaaiButtonStyle(.primary))
                .disabled(!canContinue)
                .animation(.easeInOut(duration: 0.15), value: canContinue)
            }
        }
        .padding(.horizontal, 28)
        .padding(.vertical, Spacing.md)
        .background(
            Color.Orttaai.bgSecondary.opacity(0.55)
                .overlay(alignment: .top) {
                    Rectangle().fill(Color.Orttaai.border.opacity(0.6)).frame(height: 1)
                }
        )
        .animation(.easeInOut(duration: 0.2), value: continueHint)
    }

    /// Why Continue is off, in a few words.
    private var continueHint: String? {
        guard !canContinue else { return nil }
        switch currentStep {
        case 1: return "Allow Microphone and Accessibility to continue"
        case 2: return "Choose an engine to continue"
        default: return nil
        }
    }

    private func activateReadyTestIfNeeded() {
        guard !didActivateReadyTest else { return }
        didActivateReadyTest = true
        onReadyForTesting?()
    }
}

// MARK: - Step track

/// Four numbered nodes joined by a line that fills as setup moves on; the
/// current node pulses, finished ones show a check.
struct SetupStepTrack: View {
    let titles: [String]
    let current: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(Array(titles.enumerated()), id: \.offset) { index, title in
                node(index, title: title)
                if index < titles.count - 1 {
                    connector(filled: index < current)
                        .padding(.top, 11)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Step \(current + 1) of \(titles.count): \(titles[min(current, titles.count - 1)])")
    }

    private func node(_ index: Int, title: String) -> some View {
        let isDone = index < current
        let isCurrent = index == current
        return VStack(spacing: 6) {
            ZStack {
                if isCurrent {
                    PulseRing(reduceMotion: reduceMotion)
                }
                Circle()
                    .fill(isDone ? Color.Orttaai.accent : (isCurrent ? Color.Orttaai.accentSubtle : Color.Orttaai.bgTertiary))
                    .overlay(
                        Circle().stroke(isCurrent || isDone ? Color.Orttaai.accent : Color.Orttaai.border, lineWidth: 1.5)
                    )
                    .frame(width: 24, height: 24)
                if isDone {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .heavy))
                        .foregroundStyle(Color.Orttaai.bgPrimary)
                } else {
                    Text("\(index + 1)")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundStyle(isCurrent ? Color.Orttaai.accent : Color.Orttaai.textTertiary)
                }
            }
            .frame(width: 24, height: 24)

            Text(title)
                .font(.Orttaai.caption)
                .foregroundStyle(isCurrent ? Color.Orttaai.textPrimary : Color.Orttaai.textTertiary)
                .fixedSize()
        }
        .frame(width: 70)
    }

    private func connector(filled: Bool) -> some View {
        ZStack(alignment: .leading) {
            Capsule().fill(Color.Orttaai.bgTertiary)
            GeometryReader { geometry in
                Capsule()
                    .fill(LinearGradient(colors: [Color.Orttaai.accent, Color.Orttaai.accent.opacity(0.7)], startPoint: .leading, endPoint: .trailing))
                    .frame(width: filled ? geometry.size.width : 0)
            }
        }
        .frame(height: 3)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, -10)
        .animation(.easeInOut(duration: 0.45), value: filled)
    }
}

/// The current step's ring, pulsing outward. Driven by Core Animation, so
/// it costs nothing on the main thread.
private struct PulseRing: View {
    let reduceMotion: Bool
    @State private var isExpanded = false

    var body: some View {
        Circle()
            .stroke(Color.Orttaai.accent.opacity(reduceMotion ? 0.3 : (isExpanded ? 0 : 0.5)), lineWidth: 2)
            .frame(width: 24, height: 24)
            .scaleEffect(reduceMotion ? 1.25 : (isExpanded ? 1.6 : 1))
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeOut(duration: 1.6).repeatForever(autoreverses: false)) {
                    isExpanded = true
                }
            }
    }
}

// MARK: - Welcome

struct AboutSetupStepView: View {
    private let githubURL = AppLinks.githubProfileURL
    private let repoURL = AppLinks.githubRepositoryURL

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            feature(
                icon: "waveform",
                title: "Hold a key, speak, let go",
                detail: "Orttaai types what you said into whatever app you're in."
            )
            feature(
                icon: "lock.shield",
                title: "Stays on your Mac",
                detail: "Speech and AI run on your own hardware. Nothing is uploaded."
            )
            feature(
                icon: "text.badge.checkmark",
                title: "Learns your words",
                detail: "Names and terms you use get spelled right, and it improves as you fix them."
            )

            HStack(spacing: Spacing.sm) {
                OrttaaiAppIcon()
                    .frame(width: 22, height: 22)
                Text("Made by Olanrewaju Oyinbooke")
                    .font(.Orttaai.caption)
                    .foregroundStyle(Color.Orttaai.textTertiary)
                Spacer()
                Link(destination: githubURL) {
                    Label("GitHub", systemImage: "chevron.left.forwardslash.chevron.right")
                }
                .buttonStyle(OrttaaiButtonStyle(.ghost, size: .small))
                Link(destination: repoURL) {
                    Label("Project", systemImage: "arrow.up.right.square")
                }
                .buttonStyle(OrttaaiButtonStyle(.ghost, size: .small))
            }
            .padding(.top, Spacing.sm)
        }
    }

    private func feature(icon: String, title: String, detail: String) -> some View {
        HStack(spacing: Spacing.md) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Color.Orttaai.accent)
                .frame(width: 38, height: 38)
                .background(Color.Orttaai.accentSubtle, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.Orttaai.bodyMedium)
                    .foregroundStyle(Color.Orttaai.textPrimary)
                Text(detail)
                    .font(.Orttaai.secondary)
                    .foregroundStyle(Color.Orttaai.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.Orttaai.bgSecondary, in: RoundedRectangle(cornerRadius: CornerRadius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: CornerRadius.card, style: .continuous)
                .stroke(Color.Orttaai.border.opacity(0.6), lineWidth: BorderWidth.standard)
        )
    }
}
