// CoachTodayView.swift
// Orttaai
//
// Coach's home: your voice shape for each way of talking, this week's focus
// or the habit you're on, the days you dictated, and a real moment caught
// in the wild.

import CoachCore
import SwiftUI

struct CoachTodayView: View {
    let snapshot: CoachSnapshot
    let onShowProof: () -> Void
    let onShareWeek: () -> Void

    @ObservedObject private var center = CoachCenter.shared
    @State private var lens: CoachMode?

    private var mode: CoachMode { lens ?? snapshot.busiestMode }

    var body: some View {
        CoachPage(eyebrow: "Coach", title: CoachCopy.greeting(for: snapshot.builtAt)) {
            Button(action: onShareWeek) {
                Label("Share this week", systemImage: "square.and.arrow.up")
            }
            .buttonStyle(CoachSecondaryButtonStyle())
        } content: {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 20) {
                    voiceCard.frame(width: 500)
                    // An ideal width, so the long focus line is measured
                    // wrapped rather than on one line.
                    rightColumn.frame(minWidth: 440, idealWidth: 520, maxWidth: .infinity)
                }
                VStack(spacing: 20) {
                    voiceCard
                    rightColumn
                }
            }
        }
    }

    // MARK: Voice shape

    private var voiceCard: some View {
        let shape = snapshot.shape(for: mode)
        let recent = snapshot.recentByMode[mode] ?? 0
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text("Your voice")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(CoachStyle.ink)
                CoachInfoButton(
                    title: "Your voice",
                    text: "Six things Coach counts in your last 28 days of dictation, from 0 at the centre to best at the edge. The dashed outline is the 28 days before. Each point needs 8 dictations."
                )
                Spacer()
            }
            lensPicker
            ZStack {
                VoiceShapeView(now: shape.now, then: shape.then)
                    .frame(height: 400)
                if !shape.isComplete {
                    VStack(spacing: 2) {
                        Text("\(recent)")
                            .font(CoachStyle.display(40))
                            .foregroundStyle(CoachStyle.ink)
                        Text("of \(CoachSnapshot.fullShapeDictations) dictations")
                            .font(CoachStyle.label)
                            .foregroundStyle(CoachStyle.ink3)
                    }
                }
            }
            HStack(spacing: 16) {
                legend("Now", dashed: false)
                if shape.then.count == CoachMeasure.allCases.count {
                    legend("4 weeks ago", dashed: true)
                }
                Spacer(minLength: 8)
                Text(CoachCopy.insight(shape))
                    .font(.system(size: 13))
                    .foregroundStyle(CoachStyle.ink)
                    .multilineTextAlignment(.trailing)
            }
        }
        .padding(22)
        .coachSurface()
    }

    private var lensPicker: some View {
        HStack(spacing: 4) {
            ForEach(CoachMode.shaped) { item in
                let selected = item == mode
                Button {
                    lens = item
                } label: {
                    Text(item.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(selected ? Color(hex: "1B1917") : CoachStyle.ink2)
                        .padding(.horizontal, 12)
                        .frame(height: 32)
                        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(selected ? Color.Orttaai.accent : .clear))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(4)
        .background(RoundedRectangle(cornerRadius: 13, style: .continuous).fill(Color(hex: "18171A")))
    }

    private func legend(_ title: String, dashed: Bool) -> some View {
        HStack(spacing: 8) {
            if dashed {
                Rectangle()
                    .stroke(style: StrokeStyle(lineWidth: 2, dash: [3, 3]))
                    .foregroundStyle(CoachStyle.muted)
                    .frame(width: 16, height: 1)
            } else {
                Capsule().fill(Color.Orttaai.accent).frame(width: 16, height: 3)
            }
            Text(title)
                .font(.system(size: 13))
                .foregroundStyle(dashed ? CoachStyle.ink3 : CoachStyle.ink2)
        }
    }

    // MARK: Right column

    private var rightColumn: some View {
        VStack(spacing: 16) {
            todaysRepCard
            weekCard
            if let habit = snapshot.habits.first, snapshot.caught == nil {
                habitCard(habit)
            } else {
                caughtCard
            }
        }
    }

    private var todaysRepCard: some View {
        let skill = snapshot.todaysSkill
        let persona = CoachPreferences.persona(for: skill.track.mode ?? snapshot.busiestMode)
        return VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 6) {
                CoachEyebrow(text: "Today's rep")
                Text("· \(skill.track.title) · \(snapshot.todaysKind.title)")
                    .font(CoachStyle.label)
                    .foregroundStyle(Color(hex: "C9B79B"))
            }
            HStack(alignment: .top, spacing: 14) {
                CoachPersonaGlyph(persona: persona, size: 44)
                Text("“\(CoachCopy.repIntro(persona, skill: skill, kind: snapshot.todaysKind))”")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(CoachStyle.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(skill.title)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(CoachStyle.ink)
                    Text(skill.why)
                        .font(CoachStyle.label)
                        .foregroundStyle(Color(hex: "C9B79B"))
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
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
        .padding(26)
        .frame(maxWidth: .infinity, minHeight: 230, alignment: .topLeading)
        .coachSurface(CoachStyle.warm, border: CoachStyle.warmBorder)
    }

    private func habitCard(_ state: CoachHabitState) -> some View {
        let verdict = state.verdict
        return VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 6) {
                CoachEyebrow(text: "Your habit")
                Text("· " + CoachFormat.modeLabel(state.mode))
                    .font(CoachStyle.label)
                    .foregroundStyle(Color(hex: "C9B79B"))
                Spacer()
                CoachTag(text: verdict.status.title, color: verdict.status.color)
            }
            Text(state.title)
                .font(CoachStyle.display(28))
                .foregroundStyle(CoachStyle.ink)
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(CoachFormat.percent(verdict.beforeShare))
                    .font(CoachStyle.display(24))
                    .foregroundStyle(CoachStyle.muted)
                Image(systemName: "arrow.right")
                    .foregroundStyle(CoachStyle.ink3)
                Text(CoachFormat.percent(verdict.afterShare))
                    .font(CoachStyle.display(44))
                    .foregroundStyle(verdict.status == .working ? CoachStyle.gain : CoachStyle.ink)
                Text("of dictations")
                    .font(CoachStyle.label)
                    .foregroundStyle(CoachStyle.ink3)
            }
            HStack(spacing: 6) {
                ForEach(0..<HabitJudge.window, id: \.self) { index in
                    if index < verdict.after.count {
                        Circle()
                            .fill(verdict.after[index] ? Color.Orttaai.accent : Color.white.opacity(0.14))
                            .frame(width: 12, height: 12)
                    } else {
                        Circle()
                            .stroke(Color.white.opacity(0.2), style: StrokeStyle(lineWidth: 1.5, dash: [3, 3]))
                            .frame(width: 12, height: 12)
                    }
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(verdict.after.filter { $0 }.count) of the last \(verdict.after.count) dictations met it")
            Spacer(minLength: 0)
            HStack {
                Text(CoachCopy.progressLine(verdict))
                    .font(CoachStyle.label)
                    .foregroundStyle(Color(hex: "C9B79B"))
                Spacer(minLength: 8)
                Button("See proof", action: onShowProof)
                    .buttonStyle(CoachPrimaryButtonStyle())
            }
        }
        .padding(26)
        .frame(maxWidth: .infinity, minHeight: 250, alignment: .topLeading)
        .coachSurface(CoachStyle.warm, border: CoachStyle.warmBorder)
    }

    private var weekCard: some View {
        HStack(spacing: 24) {
            VStack(alignment: .leading, spacing: 2) {
                Text("This week")
                    .font(CoachStyle.label)
                    .foregroundStyle(CoachStyle.ink3)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("\(snapshot.repsThisWeek)")
                        .font(CoachStyle.display(26))
                        .foregroundStyle(CoachStyle.ink)
                    Text(snapshot.repsThisWeek == 1 ? "rep" : "reps")
                        .font(.system(size: 14))
                        .foregroundStyle(CoachStyle.ink3)
                }
            }
            .frame(width: 130, alignment: .leading)
            HStack {
                ForEach(snapshot.week) { day in
                    let practised = snapshot.repDays.contains(day.date)
                    VStack(spacing: 6) {
                        ZStack {
                            Circle()
                                .stroke(
                                    practised ? Color.Orttaai.accent : day.dictated ? Color.Orttaai.accent.opacity(0.3) : Color.white.opacity(day.isFuture ? 0.06 : 0.10),
                                    style: StrokeStyle(lineWidth: 5, dash: day.isFuture ? [3, 5] : [])
                                )
                        }
                        .frame(width: 34, height: 34)
                        Text(day.label)
                            .font(.system(size: 12, weight: day.isToday ? .semibold : .regular))
                            .foregroundStyle(day.isToday ? CoachStyle.ink : CoachStyle.ink3)
                    }
                    .frame(maxWidth: .infinity)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(day.label): \(practised ? "practised" : day.dictated ? "dictated, no rep" : "nothing yet")")
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
        .coachSurface()
    }

    @ViewBuilder
    private var caughtCard: some View {
        if let caught = snapshot.caught {
            Button(action: onShowProof) {
                HStack(spacing: 22) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(CoachCopy.caughtLabel(caught.quote))
                            .font(CoachStyle.label)
                            .foregroundStyle(CoachStyle.ink3)
                        Text("“\(caught.quote.text)”")
                            .font(.system(size: 16))
                            .foregroundStyle(CoachStyle.ink)
                            .lineLimit(3)
                            .multilineTextAlignment(.leading)
                    }
                    Spacer(minLength: 0)
                    if caught.streak >= 2 {
                        VStack(alignment: .trailing, spacing: 2) {
                            Text("\(caught.streak)")
                                .font(CoachStyle.display(34))
                                .foregroundStyle(CoachStyle.gain)
                            Text("in a row")
                                .font(CoachStyle.label)
                                .foregroundStyle(CoachStyle.ink3)
                        }
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 20)
                .frame(maxWidth: .infinity, alignment: .leading)
                .coachSurface()
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        } else {
            HStack(spacing: 18) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 22))
                    .foregroundStyle(CoachStyle.muted)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Caught in the wild")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(CoachStyle.ink)
                    Text("Your best real moments will show up here.")
                        .font(.system(size: 14))
                        .foregroundStyle(CoachStyle.ink3)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
            .overlay(
                RoundedRectangle(cornerRadius: CoachStyle.radius, style: .continuous)
                    .stroke(Color.white.opacity(0.14), style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
            )
        }
    }
}

/// Coach's words, from the numbers.
enum CoachCopy {
    static func greeting(for date: Date) -> String {
        switch Calendar.current.component(.hour, from: date) {
        case 5..<12: return "Good morning."
        case 12..<17: return "Good afternoon."
        default: return "Good evening."
        }
    }

    static func insight(_ shape: CoachShape) -> String {
        if !shape.isComplete { return "Keep dictating; your shape fills in." }
        if let gain = shape.biggestGain { return "\(gain.axisTitle) grew most in 4 weeks" }
        if shape.then.count < CoachMeasure.allCases.count { return "Four weeks from now, you'll see how it moved" }
        return "Holding steady over 4 weeks"
    }

    /// The coach introducing today's rep, in its own way.
    static func repIntro(_ persona: CoachPersona, skill: CoachSkill, kind: CoachRepKind) -> String {
        let what = skill.title.prefix(1).lowercased() + skill.title.dropFirst()
        let redo = kind == .redo
        switch persona {
        case .mentor: return redo ? "Let's take one of yours and work on \(what)." : "Today, let's work on \(what)."
        case .editor: return "Today: \(what)."
        case .socratic: return "What would change if you focused on \(what) today?"
        case .sergeant: return redo ? "One of yours, redone. Focus: \(what)." : "Today's drill: \(what). No excuses."
        case .peer: return redo ? "Want to redo one of yours? Let's try \(what)." : "Quick one today: \(what)."
        }
    }

    static func progressLine(_ verdict: HabitVerdict) -> String {
        switch verdict.status {
        case .watching:
            if verdict.before.count < HabitJudge.minimumBaseline { return "Building a baseline: \(verdict.sinceCount) dictations so far" }
            return "\(verdict.stillNeeded) more dictations to know"
        case .working: return "It's working on your real dictations"
        case .notMoving: return "Not moving yet. Keep at it."
        }
    }

    static func caughtLabel(_ quote: CoachQuote) -> String {
        let when = quote.createdAt.formatted(.relative(presentation: .named))
        if let app = quote.appName, !app.isEmpty { return "Caught in the wild · \(app), \(when)" }
        return "Caught in the wild · \(when)"
    }
}
