// CoachRevealView.swift
// Orttaai
//
// The moment after a rep: the score against your usual, the coach's note,
// your words before and after, each check as the judge or the count saw it,
// and what to do next.

import CoachCore
import SwiftUI

struct CoachRevealView: View {
    let result: CoachRepResult
    var nextTitle = "Next rep"
    let onAgain: () -> Void
    let onNext: () -> Void
    let onDone: () -> Void
    @ObservedObject private var center = CoachCenter.shared
    @State private var habitStarted = false

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 20) {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .center, spacing: 24) {
                        scoreBlock.frame(width: 340, alignment: .leading)
                        noteCard
                    }
                    VStack(alignment: .leading, spacing: 20) {
                        scoreBlock
                        noteCard
                    }
                }
                words
                checksStrip
                actions
            }
            .frame(maxWidth: 1_160)
            .padding(.top, 18)
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: Score and note

    private var scoreBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(result.score.map { String(format: "%.1f", $0) } ?? "–")
                    .font(.system(size: 112, weight: .semibold, design: .rounded))
                    .foregroundStyle(CoachStyle.ink)
                Text("/ 5")
                    .font(.system(size: 22))
                    .foregroundStyle(CoachStyle.ink3)
            }
            if let score = result.score, let usual = result.usual {
                let change = score - usual
                CoachTag(
                    text: change >= 0.05 ? "+\(String(format: "%.1f", change)) on your usual" : change <= -0.05 ? "\(String(format: "%.1f", change)) on your usual" : "Level with your usual",
                    color: change >= 0.05 ? CoachStyle.gain : CoachStyle.ink2
                )
            } else {
                CoachTag(text: "Your first rep at this skill", color: CoachStyle.ink2)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var noteCard: some View {
        HStack(alignment: .center, spacing: 20) {
            CoachPersonaGlyph(persona: result.plan.persona, size: 60)
            VStack(alignment: .leading, spacing: 8) {
                Text(result.plan.persona.name.uppercased())
                    .font(CoachStyle.eyebrow)
                    .tracking(1)
                    .foregroundStyle(CoachStyle.warmInk)
                Text("“\(result.note)”")
                    .font(.system(size: 21, weight: .medium))
                    .foregroundStyle(CoachStyle.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Button {
                CoachVoice.shared.speak(result.note)
            } label: {
                Image(systemName: "play.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(Color(hex: "1B1917"))
                    .frame(width: 50, height: 50)
                    .background(Circle().fill(Color.Orttaai.accent))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Hear \(result.plan.persona.name) say it")
        }
        .padding(24)
        .frame(maxWidth: .infinity)
        .coachSurface(CoachStyle.warm, border: CoachStyle.warmBorder)
    }

    // MARK: Words

    @ViewBuilder
    private var words: some View {
        if let source = result.plan.source {
            HStack(alignment: .top, spacing: 14) {
                wordsCard(title: "Before · \(source.createdAt.formatted(.dateTime.month(.abbreviated).day()))", text: source.text, warm: false)
                Image(systemName: "arrow.right")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Color.Orttaai.accent)
                    .padding(.top, 60)
                    .accessibilityHidden(true)
                wordsCard(title: "After · just now", text: result.text, warm: true)
            }
        } else {
            wordsCard(title: "What you said", text: result.text, warm: true)
        }
    }

    private func wordsCard(title: String, text: String, warm: Bool) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(CoachStyle.label)
                .foregroundStyle(warm ? CoachStyle.warmInk : CoachStyle.ink3)
            Text("“\(text)”")
                .font(.system(size: 17))
                .foregroundStyle(warm ? CoachStyle.ink : Color(hex: "B9B5AF"))
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .coachSurface(Color(hex: "1D1C1F"), border: warm ? CoachStyle.warmBorder : CoachStyle.line)
    }

    // MARK: Checks

    private var checksStrip: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("How it was scored")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(CoachStyle.ink)
                CoachInfoButton(
                    title: "How it was scored",
                    text: result.judgeModel.map { "Counted checks are exact. The others were each asked as one yes or no question of \($0) on this Mac, with how sure it was. Your coach doesn't change the score." }
                        ?? "Only the counted checks ran. Start your local model server (Ollama or LM Studio) to judge the rest."
                )
                Spacer()
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), spacing: 18)], spacing: 16) {
                ForEach(result.checks) { check in
                    checkCell(check)
                }
            }
            if !result.figures.isEmpty {
                Divider().overlay(CoachStyle.line)
                HStack(spacing: 32) {
                    ForEach(result.figures) { figure in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(figure.label)
                                .font(CoachStyle.label)
                                .foregroundStyle(CoachStyle.ink3)
                            Text(figure.value)
                                .font(.system(size: 22, weight: .semibold))
                                .foregroundStyle(figure.better == true ? CoachStyle.gain : CoachStyle.ink)
                            if let usual = figure.usual {
                                Text("usual \(usual)")
                                    .font(.system(size: 12))
                                    .foregroundStyle(CoachStyle.ink3)
                            }
                        }
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(22)
        .coachSurface()
    }

    private func checkCell(_ check: CheckResult) -> some View {
        let isSkill = check.check == result.plan.skill.check
        let (text, color, fill): (String, Color, Double) = {
            switch check.answer {
            case .yes?: return ("Yes", CoachStyle.gain, check.confidence ?? 1)
            case .partly?: return ("Partly", CoachStyle.warmInk, check.confidence ?? 0.5)
            case .no?: return ("Not yet", Color.Orttaai.accent, check.confidence ?? 1)
            case nil: return ("Not judged", CoachStyle.muted, 0)
            }
        }()
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(check.check.label)
                    .font(.system(size: 14, weight: isSkill ? .semibold : .regular))
                    .foregroundStyle(CoachStyle.ink)
                    .lineLimit(2)
                if isSkill {
                    Image(systemName: "scope")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.Orttaai.accent)
                        .accessibilityLabel("This skill")
                }
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.08))
                    Capsule().fill(color).frame(width: proxy.size.width * fill)
                }
            }
            .frame(height: 6)
            Text(check.confidence.map { "\(text) · \(String(format: "%.2f", $0))" } ?? text)
                .font(.system(size: 12))
                .foregroundStyle(CoachStyle.ink3)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: Actions

    /// The skill as a habit: its counted measure, or its judged question,
    /// checked on your real dictations.
    private var habitTarget: CoachHabitTarget? {
        switch result.plan.skill.check {
        case .counted(.measure(let m)): return .measure(m)
        case .judged(let q): return .question(q)
        default: return nil
        }
    }

    private var habitMode: CoachMode? {
        result.plan.skill.track.mode ?? center.snapshot?.busiestMode
    }

    private var actions: some View {
        HStack(spacing: 14) {
            Button("Again", action: onAgain)
                .buttonStyle(CoachSecondaryButtonStyle())
            if let target = habitTarget {
                Button(habitStarted ? "Habit started" : "Make it a habit") {
                    center.startHabit(target, mode: habitMode)
                    habitStarted = true
                }
                .buttonStyle(CoachPrimaryButtonStyle())
                .disabled(habitStarted || center.snapshot?.habits.contains { $0.target == target } == true)
            }
            Button(action: onNext) {
                Label(nextTitle, systemImage: "chevron.right")
                    .labelStyle(.titleAndIcon)
            }
            .buttonStyle(CoachSecondaryButtonStyle())
            Button("Done", action: onDone)
                .buttonStyle(.plain)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(CoachStyle.ink2)
                .padding(.horizontal, 12)
        }
        .padding(.bottom, 8)
    }
}
