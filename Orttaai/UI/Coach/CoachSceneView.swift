// CoachSceneView.swift
// Orttaai
//
// A scene, full screen: the partner with a mood that moves, the goal, the
// conversation as subtitles (the partner's reply appears as it's written),
// and your turn by voice or by typing. Hands-free, the microphone opens when
// the partner stops, or while they speak if you're on headphones, so talking
// cuts in; Space always does.

import CoachCore
import SwiftUI

struct CoachSceneView: View {
    @ObservedObject var session: CoachSceneSession
    @ObservedObject private var center = CoachCenter.shared

    var body: some View {
        VStack(spacing: 20) {
            header
            switch session.phase {
            case .ended(let result):
                CoachRevealView(
                    result: result,
                    nextTitle: "Another scene",
                    onAgain: { center.beginScene(session.scene) },
                    onNext: { center.beginScene(nextScene) },
                    onDone: { center.endScene() }
                )
            case .scoring(let message):
                VStack(spacing: 14) {
                    ProgressView()
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
                        .frame(maxWidth: 520)
                    Button("Back to Studio") { center.endScene() }
                        .buttonStyle(CoachPrimaryButtonStyle())
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            default:
                stage
            }
        }
        .padding(.horizontal, 40)
        .padding(.top, 24)
        .padding(.bottom, 30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(alignment: .topLeading) {
            Circle()
                .fill(RadialGradient(colors: [Color(hex: "78AAE6").opacity(0.12), .clear], center: .center, startRadius: 0, endRadius: 280))
                .frame(width: 560, height: 560)
                .offset(x: -80, y: 80)
                .accessibilityHidden(true)
        }
        .background(Color.orttaai(light: "F5F3F0", dark: "111214"))
        .onExitCommand { center.endScene() }
    }

    private var nextScene: CoachScene {
        let all = CoachScene.all
        let index = all.firstIndex(of: session.scene) ?? 0
        return all[(index + 1) % all.count]
    }

    private var header: some View {
        HStack(spacing: 16) {
            Button { center.endScene() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(CoachStyle.ink)
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(CoachStyle.wash(0.05)))
                    .overlay(Circle().stroke(CoachStyle.wash(0.14), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Leave the scene")
            Spacer()
            VStack(spacing: 2) {
                Text("SCENE")
                    .font(CoachStyle.eyebrow)
                    .tracking(1)
                    .foregroundStyle(Color.Orttaai.accent)
                Text(session.scene.title)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(CoachStyle.ink)
            }
            Spacer()
            HStack(spacing: 4) {
                ForEach(CoachSceneSession.ReplyMode.allCases) { mode in
                    let on = session.replyMode == mode
                    Button {
                        session.replyMode = mode
                        if !mode.speaks { CoachVoice.shared.stop() }
                    } label: {
                        Text(mode.title)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(on ? Color.orttaai(light: "FFFFFF", dark: "1B1917") : CoachStyle.ink2)
                            .padding(.horizontal, 16)
                            .frame(height: 36)
                            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(on ? Color.Orttaai.accent : .clear))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
            .padding(4)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(CoachStyle.wash(0.05)))
            .accessibilityElement(children: .contain)
            .accessibilityLabel("\(session.scene.partnerName) replies in")
        }
    }

    // MARK: The stage

    private var stage: some View {
        HStack(alignment: .top, spacing: 32) {
            VStack(spacing: 16) {
                partnerCard
                goalCard
                HStack(spacing: 10) {
                    CoachPersonaGlyph(persona: session.persona, size: 24)
                    Text("\(session.persona.name) is listening. Notes when the scene ends.")
                        .font(CoachStyle.label)
                        .foregroundStyle(Color.orttaai(light: "4A4642", dark: "C9C5BF"))
                }
            }
            .frame(width: 320)
            VStack(spacing: 0) {
                conversation
                yourTurn
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var partnerCard: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle().stroke(Color(hex: "78AAE6").opacity(0.3), lineWidth: 1).frame(width: 150, height: 150)
                Circle().stroke(Color(hex: "78AAE6").opacity(0.45), lineWidth: 1).frame(width: 122, height: 122)
                Circle().fill(Color.orttaai(light: "C9DBF0", dark: "3E5F82")).frame(width: 94, height: 94)
                Text(String(session.scene.partnerName.prefix(1)))
                    .font(CoachStyle.display(40))
                    .foregroundStyle(CoachStyle.ink)
            }
            .scaleEffect(session.phase == .thinking ? 1.04 : 1)
            .animation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true), value: session.phase == .thinking)
            VStack(spacing: 2) {
                Text(session.scene.partnerName)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(CoachStyle.ink)
                Text(session.scene.partnerRole)
                    .font(CoachStyle.label)
                    .foregroundStyle(CoachStyle.ink3)
            }
            VStack(spacing: 10) {
                Text(moodLine)
                    .font(.system(size: 14))
                    .foregroundStyle(Color.orttaai(light: "2F5A8A", dark: "C4DAF5"))
                HStack(spacing: 6) {
                    ForEach(PartnerMood.allCases, id: \.self) { mood in
                        VStack(spacing: 6) {
                            Capsule()
                                .fill(mood.step <= session.mood.step ? Color.orttaai(light: "4F7DB5", dark: "9CC0EA") : CoachStyle.wash(0.10))
                                .frame(height: 6)
                            Text(mood.title)
                                .font(.system(size: 12, weight: mood == session.mood ? .semibold : .regular))
                                .foregroundStyle(mood == session.mood ? CoachStyle.ink : CoachStyle.ink3)
                        }
                    }
                }
                .animation(.easeOut(duration: 0.4), value: session.mood)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Mood: \(session.mood.title)")
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity)
        .coachSurface(Color.orttaai(light: "EEF3FA", dark: "1A1D22"), border: Color(hex: "78AAE6").opacity(0.22))
    }

    private var moodLine: String {
        let name = session.scene.partnerName
        switch session.mood {
        case .pushing: return "\(name) is pushing"
        case .weighing: return "\(name) is weighing it"
        case .agreed: return "\(name) agrees"
        }
    }

    private var goalCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Your goal")
                .font(CoachStyle.label)
                .foregroundStyle(CoachStyle.ink3)
            Text(session.scene.goal)
                .font(.system(size: 16))
                .foregroundStyle(CoachStyle.ink)
            Text("Turn \(min(session.yourTurns + 1, CoachScene.maxTurns)) of \(CoachScene.maxTurns)")
                .font(.system(size: 12))
                .foregroundStyle(CoachStyle.ink3)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .coachSurface(Color.orttaai(light: "FFFFFF", dark: "1D1C1F"))
    }

    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 20) {
                    ForEach(Array(session.turns.enumerated()), id: \.element.id) { index, turn in
                        let latest = index == session.turns.count - 1
                        turnView(turn, latest: latest)
                            .id(turn.id)
                    }
                    if let live = session.liveReply, !live.isEmpty {
                        liveView(live)
                            .id("live")
                    } else if session.phase == .thinking {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("\(session.scene.partnerName) is thinking…")
                                .font(CoachStyle.label)
                                .foregroundStyle(CoachStyle.ink3)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 16)
            }
            .onChange(of: session.turns.count) { _, _ in
                if let last = session.turns.last {
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
            .onChange(of: session.liveReply == nil) { _, streaming in
                if !streaming { proxy.scrollTo("live", anchor: .bottom) }
            }
        }
    }

    private func liveView(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(session.scene.partnerName)
                .font(CoachStyle.label)
                .foregroundStyle(Color.orttaai(light: "2F5A8A", dark: "C4DAF5"))
            Text("“\(text)”")
                .font(.system(size: 28, weight: .medium))
                .foregroundStyle(CoachStyle.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func turnView(_ turn: SceneTurn, latest: Bool) -> some View {
        switch turn.speaker {
        case .partner:
            VStack(alignment: .leading, spacing: 8) {
                Text(session.scene.partnerName)
                    .font(CoachStyle.label)
                    .foregroundStyle(Color.orttaai(light: "2F5A8A", dark: "C4DAF5"))
                if session.replyMode != .voice || latest {
                    Text(latest ? "“\(turn.text)”" : turn.text)
                        .font(.system(size: latest ? 28 : 18, weight: latest ? .medium : .regular))
                        .foregroundStyle(CoachStyle.ink.opacity(latest ? 1 : 0.6))
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                if session.replyMode.speaks {
                    Button {
                        CoachVoice.shared.speak(turn.text, as: session.scene.partnerName)
                    } label: {
                        Label("Hear again", systemImage: "play.fill")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Color.orttaai(light: "2F5A8A", dark: "C4DAF5"))
                            .padding(.horizontal, 14)
                            .frame(height: 32)
                            .background(Capsule().fill(Color(hex: "78AAE6").opacity(0.10)))
                            .overlay(Capsule().stroke(Color(hex: "78AAE6").opacity(0.35), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .disabled(session.phase != .talking)
                }
            }
        case .you:
            VStack(alignment: .trailing, spacing: 6) {
                Text(turn.durationMs == nil ? "You · typed" : "You · spoken")
                    .font(CoachStyle.label)
                    .foregroundStyle(CoachStyle.warmInk)
                Text(turn.text)
                    .font(.system(size: 18))
                    .foregroundStyle(Color.orttaai(light: "6B4A12", dark: "F0DDBF"))
                    .multilineTextAlignment(.trailing)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    // MARK: Your turn

    @ViewBuilder
    private var yourTurn: some View {
        let recording: Bool = { if case .recording = session.phase { return true } else { return false } }()
        let ready = session.phase == .talking
        if session.replyMode == .text {
            HStack(spacing: 12) {
                TextField("Reply to \(session.scene.partnerName)", text: $session.typed)
                    .textFieldStyle(.plain)
                    .font(.system(size: 18))
                    .foregroundStyle(CoachStyle.ink)
                    .onSubmit { Task { await session.sendTyped() } }
                    .disabled(!ready)
                Button("Send") { Task { await session.sendTyped() } }
                    .buttonStyle(CoachPrimaryButtonStyle())
                    .disabled(!ready || session.typed.trimmingCharacters(in: .whitespaces).isEmpty)
                endButton
            }
            .padding(.leading, 22)
            .padding(.trailing, 10)
            .frame(height: 68)
            .background(Capsule().fill(Color.orttaai(light: "FFFFFF", dark: "1D1C1F")))
            .overlay(Capsule().stroke(CoachStyle.wash(0.08), lineWidth: 1))
        } else {
            HStack(spacing: 16) {
                Button {
                    if session.partnerSpeaking {
                        session.cutIn()
                    } else if recording {
                        Task { await session.finishRecording() }
                    } else {
                        session.startRecording()
                    }
                } label: {
                    Image(systemName: recording ? "stop.fill" : "mic.fill")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(Color.orttaai(light: "FFFFFF", dark: "1B1917"))
                        .frame(width: 60, height: 60)
                        .background(Circle().fill(Color.Orttaai.accent))
                        .overlay(Circle().stroke(Color.Orttaai.accent.opacity(0.4), lineWidth: 6 + CGFloat(session.level) * 10))
                }
                .buttonStyle(.plain)
                .disabled(!(ready || recording))
                .keyboardShortcut(.space, modifiers: [])
                .accessibilityLabel(session.partnerSpeaking ? "Cut in" : recording ? "Finish your turn" : "Talk")
                Text(status(recording: recording, ready: ready))
                    .font(.system(size: 15))
                    .foregroundStyle(ready && session.notice != nil ? CoachStyle.warmInk : CoachStyle.ink2)
                    .lineLimit(2)
                    .help(session.notice ?? "")
                Spacer(minLength: 0)
                Toggle(isOn: $session.handsFree) {
                    Text("Hands-free")
                        .font(CoachStyle.label)
                        .foregroundStyle(CoachStyle.ink2)
                }
                .toggleStyle(.switch)
                .controlSize(.small)
                .help("Your turn starts when \(session.scene.partnerName) stops, and ends when you pause.")
                endButton
            }
            .padding(.horizontal, 16)
            .frame(height: 92)
            .background(Capsule().fill(Color.orttaai(light: "FFFFFF", dark: "1D1C1F")))
            .overlay(Capsule().stroke(CoachStyle.wash(0.08), lineWidth: 1))
        }
    }

    private func status(recording: Bool, ready: Bool) -> String {
        let name = session.scene.partnerName
        if recording, session.partnerSpeaking { return "\(name) is speaking. Just talk to cut in." }
        if recording {
            return session.handsFree ? "Listening. Pause when you're done." : "Listening. Press again when you're done."
        }
        if session.partnerSpeaking { return "\(name) is speaking. Press Space to cut in." }
        if ready, let notice = session.notice { return notice }
        if ready { return "Your turn. Press to talk, or the space bar." }
        return "\(name) is answering…"
    }

    private var endButton: some View {
        Button("End scene") { Task { await session.end() } }
            .buttonStyle(CoachSecondaryButtonStyle())
            .disabled(!session.canEnd)
    }
}
