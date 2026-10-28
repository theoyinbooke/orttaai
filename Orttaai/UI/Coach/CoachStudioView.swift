// CoachStudioView.swift
// Orttaai
//
// Studio: today's rep and where each track left off. Starting one opens the
// rep full screen, by voice or by typing.

import CoachCore
import SwiftUI

struct CoachStudioView: View {
    let snapshot: CoachSnapshot
    @ObservedObject private var center = CoachCenter.shared

    var body: some View {
        CoachPage(eyebrow: "Studio", title: "Practise") {
            EmptyView()
        } content: {
            // Compact, so today's rep, every scene and every track fit in the
            // window without scrolling.
            todaysRep
            section("Scenes") {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 12)], spacing: 12) {
                    ForEach(CoachScene.all) { scene in
                        sceneTile(scene)
                    }
                }
            }
            section("Where each track left off") {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 250), spacing: 12)], spacing: 12) {
                    ForEach(CoachTrack.allCases) { track in
                        trackTile(track)
                    }
                }
            }
        }
    }

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(CoachStyle.ink)
            content()
        }
    }

    private var todaysRep: some View {
        let skill = snapshot.todaysSkill
        let persona = CoachPreferences.persona(for: skill.track.mode ?? snapshot.busiestMode)
        return HStack(alignment: .center, spacing: 18) {
            CoachPersonaGlyph(persona: persona, size: 48)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    CoachEyebrow(text: "Today's rep")
                    Text("· \(skill.track.title) · \(snapshot.todaysKind.title)")
                        .font(CoachStyle.label)
                        .foregroundStyle(Color.orttaai(light: "6B5532", dark: "C9B79B"))
                        .lineLimit(1)
                }
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(skill.title)
                        .font(CoachStyle.display(24))
                        .foregroundStyle(CoachStyle.ink)
                        .layoutPriority(1)
                    Text(skill.why)
                        .font(.system(size: 14))
                        .foregroundStyle(CoachStyle.ink2)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 12)
            HStack(spacing: 10) {
                Button {
                    Task { await center.beginRep(skill, kind: snapshot.todaysKind, spoken: true) }
                } label: {
                    Label("Speak it", systemImage: "mic")
                }
                .buttonStyle(CoachPrimaryButtonStyle())
                if !skill.speakOnly {
                    Button("Type it") {
                        Task { await center.beginRep(skill, kind: snapshot.todaysKind, spoken: false) }
                    }
                    .buttonStyle(CoachSecondaryButtonStyle())
                }
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 16)
        .coachSurface(CoachStyle.warm, border: CoachStyle.warmBorder)
    }

    /// Every scene card is the same size: one line each for the title, the
    /// partner and the goal. The full text is in the tooltip and VoiceOver.
    private func sceneTile(_ scene: CoachScene) -> some View {
        let role = scene.partnerRole.prefix(1).lowercased() + scene.partnerRole.dropFirst()
        let partner = "\(scene.partnerName), \(role)"
        // The card shows who they are; how they are is in the tooltip.
        let shortPartner = "\(scene.partnerName), \(role.split(separator: ",").first.map(String.init) ?? role)"
        return Button {
            center.beginScene(scene)
        } label: {
            HStack(alignment: .center, spacing: 14) {
                Text(String(scene.partnerName.prefix(1)))
                    .font(CoachStyle.display(18))
                    .foregroundStyle(CoachStyle.ink)
                    .frame(width: 38, height: 38)
                    .background(Circle().fill(Color.orttaai(light: "C9DBF0", dark: "3E5F82")))
                VStack(alignment: .leading, spacing: 2) {
                    Text(scene.title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(CoachStyle.ink)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                    Text(shortPartner)
                        .font(CoachStyle.label)
                        .foregroundStyle(CoachStyle.ink3)
                        .lineLimit(1)
                    Text(scene.goal)
                        .font(.system(size: 13))
                        .foregroundStyle(CoachStyle.ink2)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(CoachStyle.ink3)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .coachSurface()
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("\(scene.title) — \(partner). \(scene.goal)")
        .accessibilityLabel("Scene: \(scene.title), with \(partner). Goal: \(scene.goal)")
    }

    private func trackTile(_ track: CoachTrack) -> some View {
        let skill = snapshot.currentSkill(in: track)
        let progress = snapshot.progress(skill)
        return VStack(alignment: .leading, spacing: 6) {
            Text(track.title)
                .font(.system(size: 12))
                .foregroundStyle(CoachStyle.ink3)
            Text(skill.title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(CoachStyle.ink)
                .lineLimit(1)
                .help(skill.title)
            HStack(spacing: 6) {
                ForEach(0..<CoachScore.repsToMaster, id: \.self) { index in
                    Circle()
                        .fill(index < progress.strongReps ? Color.Orttaai.accent : CoachStyle.wash(0.12))
                        .frame(width: 7, height: 7)
                }
                if let usual = progress.usual {
                    Text("usual \(String(format: "%.1f", usual))")
                        .font(.system(size: 12))
                        .foregroundStyle(CoachStyle.ink3)
                }
                Spacer(minLength: 8)
                Button("Speak") { Task { await center.beginRep(skill, kind: .drill, spoken: true) } }
                    .buttonStyle(CoachSecondaryButtonStyle(compact: true))
                if !skill.speakOnly {
                    Button("Type") { Task { await center.beginRep(skill, kind: .drill, spoken: false) } }
                        .buttonStyle(CoachSecondaryButtonStyle(compact: true))
                }
            }
            .padding(.top, 4)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .coachSurface()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(track.title): \(skill.title), \(progress.strongReps) of \(CoachScore.repsToMaster) strong reps")
    }
}

/// A rep, full screen: what to do, then doing it, then the reveal.
struct CoachSessionView: View {
    @ObservedObject var session: CoachPracticeSession
    @ObservedObject private var center = CoachCenter.shared

    var body: some View {
        VStack(spacing: 0) {
            header
            Group {
                switch session.phase {
                case .revealed(let result):
                    CoachRevealView(
                        result: result,
                        onAgain: { session.again() },
                        onNext: { Task { await center.nextRep(after: result.plan) } },
                        onDone: { center.endRep() }
                    )
                case .scoring(let message):
                    VStack(spacing: 14) {
                        ProgressView().controlSize(.regular)
                        Text(message)
                            .font(.system(size: 15))
                            .foregroundStyle(CoachStyle.ink2)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .failed(let message):
                    VStack(spacing: 16) {
                        Text(message)
                            .font(.system(size: 17))
                            .foregroundStyle(CoachStyle.ink)
                            .multilineTextAlignment(.center)
                        Button("Try again") { session.again() }
                            .buttonStyle(CoachPrimaryButtonStyle())
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .ready, .recording:
                    // Scrolls when the window is short; otherwise the window
                    // takes the rep's height at its narrowest as its minimum
                    // and lays it out far below the screen.
                    ViewThatFits(in: .vertical) {
                        doing
                        ScrollView(showsIndicators: false) {
                            doing.padding(.vertical, 24)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 40)
        .padding(.top, 24)
        .padding(.bottom, 30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(alignment: .center) {
            Circle()
                .fill(RadialGradient(colors: [Color.Orttaai.accent.opacity(0.14), .clear], center: .center, startRadius: 0, endRadius: 300))
                .frame(width: 600, height: 600)
                .offset(y: 60)
                .accessibilityHidden(true)
        }
        .background(Color.orttaai(light: "F5F3F0", dark: "121113"))
        .onExitCommand { center.endRep() }
    }

    private var header: some View {
        HStack(spacing: 16) {
            Button { center.endRep() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(CoachStyle.ink)
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(CoachStyle.wash(0.05)))
                    .overlay(Circle().stroke(CoachStyle.wash(0.14), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Leave the studio")
            Spacer()
            Text("\(session.plan.skill.title) · \(session.plan.kind.title)")
                .font(.system(size: 14))
                .foregroundStyle(CoachStyle.ink3)
            Spacer()
            if session.phase == .ready && session.canType {
                HStack(spacing: 4) {
                    modeButton("Speak", on: session.spoken) { session.spoken = true }
                    modeButton("Type", on: !session.spoken) { session.spoken = false }
                }
                .padding(4)
                .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(CoachStyle.wash(0.05)))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(CoachStyle.wash(0.08), lineWidth: 1))
            } else {
                Color.clear.frame(width: 44, height: 44)
            }
        }
    }

    private func modeButton(_ title: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(on ? Color.orttaai(light: "FFFFFF", dark: "1B1917") : CoachStyle.ink2)
                .padding(.horizontal, 18)
                .frame(height: 36)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(on ? Color.Orttaai.accent : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    // MARK: Doing the rep

    private var doing: some View {
        VStack(spacing: 22) {
            brief
            if session.spoken {
                speaking
            } else {
                typing
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var brief: some View {
        VStack(spacing: 10) {
            if let source = session.plan.source {
                Text(sourceLabel(source))
                    .font(CoachStyle.label)
                    .foregroundStyle(CoachStyle.ink3)
                Text("“\(source.text)”")
                    .font(.system(size: 17))
                    .foregroundStyle(Color.orttaai(light: "5E5A55", dark: "B9B5AF"))
                    .multilineTextAlignment(.center)
                    .lineLimit(4)
            }
            Text(session.plan.instruction)
                .font(CoachStyle.display(30))
                .foregroundStyle(CoachStyle.ink)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, session.plan.source == nil ? 30 : 8)
        }
        .frame(maxWidth: 880)
    }

    private func sourceLabel(_ quote: CoachQuote) -> String {
        let when = quote.createdAt.formatted(.dateTime.month(.abbreviated).day())
        if let app = quote.appName, !app.isEmpty { return "You said, to \(app) · \(when)" }
        return "You said · \(when)"
    }

    @ViewBuilder
    private var speaking: some View {
        let recording: Bool = { if case .recording = session.phase { return true } else { return false } }()
        let limit = Double(session.plan.kind.timeLimitSeconds)
        VStack(spacing: 22) {
            Spacer(minLength: 0)
            Button {
                if recording {
                    Task { await session.finishRecording() }
                } else {
                    session.startRecording()
                }
            } label: {
                ZStack {
                    Circle().stroke(CoachStyle.wash(0.07), lineWidth: 4).frame(width: 280, height: 280)
                    if recording {
                        Circle()
                            .trim(from: 0, to: min(1, session.elapsed / limit))
                            .stroke(Color.Orttaai.accent, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                            .frame(width: 280, height: 280)
                    }
                    Circle().stroke(Color.Orttaai.accent.opacity(0.22), lineWidth: 1.5)
                        .frame(width: 200 + CGFloat(session.level) * 50, height: 200 + CGFloat(session.level) * 50)
                    Circle().stroke(Color.Orttaai.accent.opacity(0.35), lineWidth: 1.5)
                        .frame(width: 170 + CGFloat(session.level) * 30, height: 170 + CGFloat(session.level) * 30)
                    Circle().fill(Color.Orttaai.accent).frame(width: 140, height: 140)
                    Image(systemName: recording ? "stop.fill" : "mic.fill")
                        .font(.system(size: 40, weight: .medium))
                        .foregroundStyle(Color.orttaai(light: "FFFFFF", dark: "1B1917"))
                }
                .animation(.easeOut(duration: 0.08), value: session.level)
                .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(recording ? "Finish and reveal" : "Start speaking")
            .keyboardShortcut(.space, modifiers: [])
            Text(recording ? "\(timeText(session.elapsed)) of \(timeText(limit))" : "Press to start, or the space bar")
                .font(.system(size: 15))
                .foregroundStyle(CoachStyle.ink2)
                .monospacedDigit()
            Spacer(minLength: 0)
            HStack(spacing: 14) {
                if recording {
                    Button("Start over") { session.again() }
                        .buttonStyle(CoachSecondaryButtonStyle())
                    Button("Finish and reveal") { Task { await session.finishRecording() } }
                        .buttonStyle(CoachPrimaryButtonStyle())
                } else {
                    Text("Coach stays quiet until you finish.")
                        .font(CoachStyle.label)
                        .foregroundStyle(CoachStyle.ink3)
                }
            }
        }
    }

    private var typing: some View {
        let words = CoachCounting.wordCount(session.typed)
        let sentences = CoachCounting.sentenceLengths(in: session.typed).count
        return VStack(spacing: 16) {
            HStack(spacing: 10) {
                chip("\(words) \(words == 1 ? "word" : "words")")
                chip("\(sentences) \(sentences == 1 ? "sentence" : "sentences")")
                chip(session.plan.skill.drill)
            }
            TextEditor(text: $session.typed)
                .font(.system(size: 20, weight: .medium))
                .scrollContentBackground(.hidden)
                .padding(24)
                .frame(maxWidth: 860, maxHeight: .infinity)
                .background(RoundedRectangle(cornerRadius: 28, style: .continuous).fill(Color.orttaai(light: "FFFFFF", dark: "1D1C1F")))
                .overlay(RoundedRectangle(cornerRadius: 28, style: .continuous).stroke(CoachStyle.wash(0.10), lineWidth: 1))
                .accessibilityLabel("Your attempt")
            HStack(spacing: 16) {
                Text("Typed reps score what you wrote. Speak it to also hear your pace.")
                    .font(CoachStyle.label)
                    .foregroundStyle(CoachStyle.ink3)
                Button("Reveal") { Task { await session.submitTyped() } }
                    .buttonStyle(CoachPrimaryButtonStyle())
                    .disabled(words < 3)
                    .keyboardShortcut(.return, modifiers: .command)
            }
        }
    }

    private func chip(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13))
            .foregroundStyle(CoachStyle.ink2)
            .lineLimit(1)
            .padding(.horizontal, 14)
            .frame(height: 32)
            .background(Capsule().fill(CoachStyle.wash(0.06)))
            .overlay(Capsule().stroke(CoachStyle.wash(0.10), lineWidth: 1))
    }

    private func timeText(_ seconds: Double) -> String {
        let total = Int(seconds)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
