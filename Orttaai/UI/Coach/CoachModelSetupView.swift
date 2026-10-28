// CoachModelSetupView.swift
// Orttaai
//
// Getting Coach ready to talk: a card in What's New's style that walks
// through what a scene feels like and ends by setting up the models Coach
// recommends for this Mac, and the same list inline in the welcome.

import CoachCore
import SwiftUI

// MARK: - Card

/// The setup card over Coach, the first time it opens without its models
/// and from Cast › Models.
struct CoachSetupHost: View {
    @ObservedObject private var setup = CoachModelSetupCenter.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if setup.presenting {
                Color.black.opacity(0.55)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture {}
                    .transition(.opacity)
                CoachSetupCard(startPage: setup.startsAtSetup ? 3 : 0, onClose: setup.close)
                    .transition(reduceMotion ? .opacity : .scale(scale: 0.95).combined(with: .opacity))
            }
        }
        .animation(reduceMotion ? nil : .spring(response: 0.4, dampingFraction: 0.88), value: setup.presenting)
    }
}

struct CoachSetupCard: View {
    let onClose: () -> Void
    @ObservedObject private var setup = CoachModelSetupCenter.shared
    @State private var index: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private enum Page: Int, CaseIterable {
        case talk, handsFree, local, setUp
    }

    init(startPage: Int = 0, onClose: @escaping () -> Void) {
        _index = State(initialValue: startPage)
        self.onClose = onClose
    }

    private var page: Page { Page(rawValue: index) ?? .setUp }
    private var isLast: Bool { page == .setUp }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            WhatsNewArtPanel(sceneID: "\(page)", transition: slide) { art }
                .frame(height: 196)
                .frame(maxWidth: .infinity)
                .overlay(alignment: .topTrailing) { closeButton }

            VStack(alignment: .leading, spacing: 0) {
                Text(eyebrow)
                    .font(.system(size: 11, weight: .bold))
                    .tracking(0.9)
                    .foregroundStyle(Color.orttaai(light: "8A5A0F", dark: "E8B45A"))
                Group {
                    Text(title)
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(Color.Orttaai.textPrimary)
                        .padding(.top, 8)
                        .accessibilityAddTraits(.isHeader)
                    if isLast {
                        CoachModelSetupList(compact: true)
                            .padding(.top, 14)
                    } else {
                        Text(detail)
                            .font(.system(size: 14))
                            .foregroundStyle(Color.orttaai(light: "4A4642", dark: "C7C7CC"))
                            .lineSpacing(3)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 8)
                    }
                }
                .id("text-\(page)")
                .transition(.opacity)

                Spacer(minLength: 20)
                footer
            }
            .padding(.horizontal, 26)
            .padding(.top, 20)
            .padding(.bottom, 22)
            // Tall enough for the setup list, so the card keeps its size as you page.
            .frame(minHeight: 290, alignment: .top)
        }
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
        .background(Color.orttaai(light: "FFFFFF", dark: "232325"))
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(Color.Orttaai.bgTertiary, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.5), radius: 30, y: 22)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.28), value: index)
        .gesture(
            DragGesture(minimumDistance: 30).onEnded { drag in
                if drag.translation.width < -40, !isLast { index += 1 }
                if drag.translation.width > 40, index > 0 { index -= 1 }
            }
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Set up Coach")
        .task { await setup.refresh() }
    }

    private var eyebrow: String {
        isLast ? "SET UP COACH" : "COACH · \(index + 1) OF \(Page.allCases.count)"
    }

    private var title: String {
        switch page {
        case .talk: return "Talk it through with Ola"
        case .handsFree: return "Just talk. Pause when you're done."
        case .local: return "Two models, both on this Mac"
        case .setUp: return setup.step == .done || setup.isSetUp ? "You're ready to talk" : "Get everything in one go"
        }
    }

    private var detail: String {
        switch page {
        case .talk:
            return "Scenes are now a conversation. Ola, a client in Lagos, answers out loud in her own voice, sentence by sentence as she thinks."
        case .handsFree:
            return "The microphone opens when Ola stops, and your turn ends when you pause. To cut in, press Space, or with headphones on just start talking. Your coach scores the scene at the end."
        case .local:
            return "A quick model plays the people in scenes, so replies come in a blink. A careful one judges your reps and writes your notes. They run in Ollama, and nothing leaves this Mac."
        case .setUp:
            return ""
        }
    }

    private var slide: AnyTransition {
        reduceMotion ? .opacity : .asymmetric(
            insertion: .move(edge: .trailing).combined(with: .opacity),
            removal: .move(edge: .leading).combined(with: .opacity)
        )
    }

    @ViewBuilder
    private var art: some View {
        switch page {
        case .talk: CoachSetupTalkScene()
        case .handsFree: CoachSetupTurnScene()
        case .local: CoachSetupLocalScene(models: setup.models)
        case .setUp: CoachSetupProgressScene(progress: setup.progress, done: setup.step == .done || setup.isSetUp, working: setup.isWorking)
        }
    }

    private var closeButton: some View {
        Button(action: onClose) {
            Image(systemName: "xmark")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Color.Orttaai.textPrimary)
                .frame(width: 28, height: 28)
                .background(Circle().fill(Color.black.opacity(0.35)))
                .overlay(Circle().strokeBorder(CoachStyle.wash(0.08), lineWidth: 1))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
        .keyboardShortcut(.cancelAction)
        .padding(12)
        .help("Close")
        .accessibilityLabel("Close setup")
    }

    private var footer: some View {
        HStack(spacing: 12) {
            HStack(spacing: 5) {
                ForEach(Page.allCases, id: \.self) { dot in
                    Capsule()
                        .fill(dot == page ? Color.Orttaai.accent : Color.orttaai(light: "D8D1C6", dark: "48484A"))
                        .frame(width: dot == page ? 16 : 6, height: 6)
                        .onTapGesture { index = dot.rawValue }
                }
            }
            .accessibilityElement()
            .accessibilityLabel("\(index + 1) of \(Page.allCases.count)")
            Spacer()
            if isLast {
                if setup.step == .done || setup.isSetUp {
                    Button("Done", action: onClose)
                        .buttonStyle(WhatsNewPrimaryButtonStyle())
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("Not now", action: onClose)
                        .buttonStyle(.plain)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color.Orttaai.textSecondary)
                        .pointingHandCursor()
                    Button(setup.actionTitle) { Task { await setup.setUp() } }
                        .buttonStyle(WhatsNewPrimaryButtonStyle())
                        .keyboardShortcut(.defaultAction)
                        .disabled(!setup.canAct)
                        .opacity(setup.canAct ? 1 : 0.5)
                }
            } else {
                Button("Skip to setup") { index = Page.setUp.rawValue }
                    .buttonStyle(.plain)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.Orttaai.textSecondary)
                    .pointingHandCursor()
                Button("Next") { index += 1 }
                    .buttonStyle(WhatsNewPrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
            }
        }
    }
}

// MARK: - The list

/// The recommended models and Ola's voice, each with where it stands. Compact
/// in the card; roomy, with its own button, in the welcome.
struct CoachModelSetupList: View {
    var compact = false

    @ObservedObject private var setup = CoachModelSetupCenter.shared
    @ObservedObject private var voice = CoachNaturalVoice.shared
    @ObservedObject private var center = CoachCenter.shared

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 6 : 12) {
            if setup.server == .notRunning {
                serverMissing
            }
            ForEach(setup.models) { model in
                row(
                    icon: model.jobs.contains("Scene partner") ? "bubble.left.and.bubble.right" : "checkmark.seal",
                    title: model.name,
                    detail: model.jobs.joined(separator: " · ")
                ) { modelStatus(model) }
            }
            row(icon: "waveform", title: "Natural voices", detail: "A voice for each scene partner · \(voice.downloadSize)") {
                voiceStatus
            }
            if case .failed(let message) = setup.step {
                Text(message)
                    .font(.system(size: 13))
                    .foregroundStyle(CoachStyle.warmInk)
                    .fixedSize(horizontal: false, vertical: true)
            } else if setup.provider != .ollama {
                Text("Download these in \(setup.provider.displayName), then come back.")
                    .font(.system(size: 13))
                    .foregroundStyle(CoachStyle.ink3)
            }
            if !compact {
                HStack(spacing: 14) {
                    Label("Through Ollama, on this Mac", systemImage: "lock")
                        .font(.system(size: 14))
                        .foregroundStyle(CoachStyle.ink3)
                    Spacer(minLength: 12)
                    Button(setup.actionTitle) { Task { await setup.setUp() } }
                        .buttonStyle(CoachPrimaryButtonStyle())
                        .disabled(!setup.canAct)
                }
                .padding(.top, 6)
            }
        }
        .task { await setup.refresh() }
    }

    private var serverMissing: some View {
        let installed = setup.ollamaApp != nil
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(installed ? "Ollama isn't running" : "Coach's models run in Ollama")
                    .font(.system(size: compact ? 14 : 16, weight: .semibold))
                    .foregroundStyle(CoachStyle.ink)
                Text(installed ? "Open it and Coach downloads the rest." : "It's free and runs models on this Mac.")
                    .font(.system(size: compact ? 12 : 14))
                    .foregroundStyle(CoachStyle.ink2)
            }
            Spacer(minLength: 8)
            Button(installed ? "Open Ollama" : "Get Ollama") { Task { await setup.startOllama() } }
                .buttonStyle(CoachSecondaryButtonStyle())
            Button("Check again") { Task { await setup.refresh() } }
                .buttonStyle(.plain)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.Orttaai.accent)
        }
        .padding(compact ? 12 : 18)
        .coachSurface(CoachStyle.warm, border: CoachStyle.warmBorder)
    }

    @ViewBuilder
    private func modelStatus(_ model: CoachStarterModel) -> some View {
        if case .downloading(let current, let fraction) = setup.step, current == model.name {
            progress(fraction, label: "Downloading")
        } else if case .checking(let checking, let done, let total) = center.judgeState, checking == model.name {
            progress(Double(done) / Double(max(total, 1)), label: "Checking")
        } else if setup.server == .checking {
            status("Looking…", CoachStyle.ink3)
        } else if !setup.isInstalled(model.name) {
            status(model.size, CoachStyle.ink2)
        } else if model.name == setup.judge {
            if let grade = CoachPreferences.judgeGrade(for: model.name) {
                status(grade.passes ? "Passed · \(Int((grade.accuracy * 100).rounded()))%" : "Failed the check", grade.passes ? CoachStyle.gain : CoachStyle.warmInk)
            } else {
                status("Judge check next", CoachStyle.ink2)
            }
        } else {
            installedMark
        }
    }

    @ViewBuilder
    private var voiceStatus: some View {
        switch voice.state {
        case .ready:
            installedMark
        case .downloading(let fraction):
            progress(fraction, label: "Downloading")
        case .notInstalled, .failed:
            Toggle("Include", isOn: $setup.includeVoice)
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
                .disabled(setup.isWorking)
                .accessibilityLabel("Include Ola's voice")
        }
    }

    private var installedMark: some View {
        Label("Ready", systemImage: "checkmark.circle.fill")
            .font(.system(size: compact ? 12 : 14, weight: .semibold))
            .foregroundStyle(CoachStyle.gain)
    }

    private func row(icon: String, title: String, detail: String, @ViewBuilder trailing: () -> some View) -> some View {
        HStack(spacing: compact ? 12 : 16) {
            Image(systemName: icon)
                .font(.system(size: compact ? 14 : 18))
                .foregroundStyle(Color.Orttaai.accent)
                .frame(width: compact ? 22 : 32)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: compact ? 13 : 16, weight: .semibold))
                    .foregroundStyle(CoachStyle.ink)
                    .lineLimit(1)
                Text(detail)
                    .font(.system(size: compact ? 11 : 13))
                    .foregroundStyle(CoachStyle.ink3)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            trailing()
        }
        .padding(.horizontal, compact ? 12 : 20)
        .frame(height: compact ? 42 : 62)
        .background(
            RoundedRectangle(cornerRadius: compact ? 12 : 18, style: .continuous)
                .fill(Color(hex: compact ? "2A2A2D" : "1D1C1F"))
        )
        .overlay(
            RoundedRectangle(cornerRadius: compact ? 12 : 18, style: .continuous)
                .strokeBorder(CoachStyle.wash(0.06), lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
    }

    private func status(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(.system(size: compact ? 12 : 14))
            .foregroundStyle(color)
    }

    private func progress(_ fraction: Double?, label: String) -> some View {
        HStack(spacing: 8) {
            if !compact {
                Text(label)
                    .font(.system(size: 13))
                    .foregroundStyle(CoachStyle.ink3)
            }
            if let fraction {
                ProgressView(value: fraction)
                    .frame(width: compact ? 70 : 110)
                Text("\(Int((fraction * 100).rounded()))%")
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(CoachStyle.ink2)
                    .frame(width: 34, alignment: .trailing)
            } else {
                ProgressView().controlSize(.small)
            }
        }
    }
}

// MARK: - Pictures

/// Ola's line and yours, with her voice as a waveform.
private struct CoachSetupTalkScene: View {
    var body: some View {
        HStack(alignment: .center, spacing: 18) {
            ZStack {
                ForEach([96, 74], id: \.self) { size in
                    Circle()
                        .strokeBorder(Color(hex: "78AAE6").opacity(size == 74 ? 0.45 : 0.22), lineWidth: 1)
                        .frame(width: CGFloat(size), height: CGFloat(size))
                }
                Circle().fill(Color.orttaai(light: "C9DBF0", dark: "3E5F82")).frame(width: 56, height: 56)
                Text("O")
                    .font(.system(size: 26, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.orttaai(light: "1F3F66", dark: "F5F3F0"))
            }
            VStack(alignment: .leading, spacing: 10) {
                bubble("Can we also get the PDF export in by Friday?", partner: true)
                    .overlay(alignment: .bottomLeading) { Waveform().offset(x: 14, y: 16) }
                bubble("Friday for the calendar. PDF the week after?", partner: false)
                    .padding(.top, 10)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .frame(width: 250)
        }
    }

    private func bubble(_ text: String, partner: Bool) -> some View {
        Text(text)
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(partner ? Color.orttaai(light: "1F3F66", dark: "E3EDF9") : Color.orttaai(light: "6B4A12", dark: "F0DDBF"))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(partner ? Color(hex: "78AAE6").opacity(0.16) : Color.Orttaai.accent.opacity(0.16))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(partner ? Color(hex: "78AAE6").opacity(0.4) : Color.Orttaai.accent.opacity(0.45), lineWidth: 1)
            )
    }
}

private struct Waveform: View {
    private static let heights: [CGFloat] = [4, 9, 14, 8, 12, 5, 10, 15, 7, 11, 4]

    var body: some View {
        HStack(spacing: 2.5) {
            ForEach(Array(Self.heights.enumerated()), id: \.offset) { _, height in
                Capsule()
                    .fill(Color.orttaai(light: "4F7DB5", dark: "9CC0EA"))
                    .frame(width: 2.5, height: height)
            }
        }
    }
}

/// A turn: the level rising while you talk, then the pause that ends it.
private struct CoachSetupTurnScene: View {
    private static let levels: [CGFloat] = [6, 10, 22, 34, 28, 40, 30, 18, 36, 26, 12, 5, 3, 3, 3, 3]

    var body: some View {
        VStack(spacing: 16) {
            HStack(alignment: .center, spacing: 3) {
                ForEach(Array(Self.levels.enumerated()), id: \.offset) { index, level in
                    Capsule()
                        .fill(index < 11 ? Color.Orttaai.accent : CoachStyle.wash(0.18))
                        .frame(width: 5, height: level)
                }
                Text("pause")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.Orttaai.textSecondary)
                    .padding(.leading, 8)
            }
            .frame(height: 44)
            HStack(spacing: 10) {
                ZStack {
                    Circle().fill(Color.Orttaai.accent).frame(width: 34, height: 34)
                    Image(systemName: "mic.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.Orttaai.bgPrimary)
                }
                Text("Listening. Pause when you're done.")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.Orttaai.textPrimary)
                Text("Space")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Color.Orttaai.textSecondary)
                    .padding(.horizontal, 7)
                    .frame(height: 20)
                    .background(RoundedRectangle(cornerRadius: 5).strokeBorder(CoachStyle.wash(0.2), lineWidth: 1))
            }
            .padding(.leading, 6)
            .padding(.trailing, 14)
            .frame(height: 46)
            .background(Capsule().fill(Color.orttaai(light: "FFFFFF", dark: "2C2C2F")))
            .overlay(Capsule().strokeBorder(CoachStyle.wash(0.08), lineWidth: 1))
            .shadow(color: .black.opacity(0.35), radius: 10, y: 6)
        }
    }
}

/// The two models as chips around a Mac that keeps them.
private struct CoachSetupLocalScene: View {
    let models: [CoachStarterModel]

    var body: some View {
        HStack(spacing: 18) {
            VStack(alignment: .trailing, spacing: 10) {
                ForEach(models) { model in
                    HStack(spacing: 8) {
                        Image(systemName: model.jobs.contains("Scene partner") ? "bubble.left.and.bubble.right.fill" : "checkmark.seal.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(Color.Orttaai.accent)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(model.name)
                                .font(.system(size: 11.5, weight: .semibold))
                                .foregroundStyle(Color.Orttaai.textPrimary)
                            Text(model.jobs.joined(separator: " · "))
                                .font(.system(size: 10))
                                .foregroundStyle(Color.Orttaai.textSecondary)
                        }
                    }
                    .padding(.horizontal, 12)
                    .frame(height: 40)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.Orttaai.accent.opacity(0.10)))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.Orttaai.accent.opacity(0.35), lineWidth: 1))
                }
            }
            Image(systemName: "arrow.right")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Color.Orttaai.textSecondary)
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.Orttaai.textPrimary.opacity(0.8), lineWidth: 2)
                    .frame(width: 92, height: 62)
                Image(systemName: "lock.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Color.Orttaai.accent)
                Capsule()
                    .fill(Color.Orttaai.textPrimary.opacity(0.8))
                    .frame(width: 112, height: 5)
                    .offset(y: 36)
            }
        }
    }
}

/// The download ring, live: how far the current step is, then a tick.
private struct CoachSetupProgressScene: View {
    let progress: Double?
    let done: Bool
    let working: Bool

    var body: some View {
        ZStack {
            ForEach([150, 118], id: \.self) { size in
                Circle()
                    .strokeBorder(Color.Orttaai.accent.opacity(0.16), lineWidth: 1)
                    .frame(width: CGFloat(size), height: CGFloat(size))
            }
            Circle().stroke(Color.orttaai(light: "E2DCD2", dark: "3A3A3C"), lineWidth: 7)
                .frame(width: 92, height: 92)
            Circle()
                .trim(from: 0, to: done ? 1 : (progress ?? (working ? 0.08 : 0)))
                .stroke(Color.Orttaai.accent, style: StrokeStyle(lineWidth: 7, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .frame(width: 92, height: 92)
                .animation(.easeOut(duration: 0.3), value: progress)
            Image(systemName: done ? "checkmark" : "arrow.down")
                .font(.system(size: 28, weight: .bold))
                .foregroundStyle(Color.Orttaai.accent)
        }
    }
}
