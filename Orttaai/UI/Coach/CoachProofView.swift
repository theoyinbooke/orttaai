// CoachProofView.swift
// Orttaai
//
// Every habit as an experiment on real dictations: 20 before it started
// against the latest 20 since, with how much the skills nobody practised
// moved, so a good week doesn't take the credit.

import CoachCore
import SwiftUI

struct CoachProofView: View {
    let snapshot: CoachSnapshot
    @ObservedObject private var center = CoachCenter.shared

    var body: some View {
        CoachPage(eyebrow: "Proof", title: "In the wild") {
            if let drift = snapshot.habits.compactMap(\.verdict.controlDrift).first {
                HStack(spacing: 8) {
                    Text("Skills you didn't practise moved")
                        .font(.system(size: 14))
                        .foregroundStyle(CoachStyle.ink2)
                    Text(CoachFormat.points(drift))
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(CoachStyle.ink)
                    CoachInfoButton(
                        title: "A fair test",
                        text: "Over the same dictations, Coach checks the measures you weren't working on. A habit only counts as working when it moved more than they did."
                    )
                }
                .padding(.horizontal, 14)
                .frame(height: 40)
                .background(Capsule().fill(CoachStyle.surface))
                .overlay(Capsule().stroke(CoachStyle.line, lineWidth: 1))
            }
        } content: {
            if let featured = snapshot.habits.first {
                FeaturedHabitCard(state: featured) { center.endHabit(featured) }
                let rest = Array(snapshot.habits.dropFirst())
                if !rest.isEmpty {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 16)], spacing: 16) {
                        ForEach(rest) { state in
                            HabitCard(state: state) { center.endHabit(state) }
                        }
                    }
                }
                if snapshot.habits.count < 3, !snapshot.suggestions.isEmpty {
                    suggestionSection(title: "Try another", picks: Array(snapshot.suggestions.prefix(3 - snapshot.habits.count)))
                }
            } else {
                emptyHero
                if !snapshot.suggestions.isEmpty {
                    suggestionSection(title: "Picked from your dictations", picks: snapshot.suggestions)
                }
            }
        }
    }

    private var emptyHero: some View {
        HStack(spacing: 48) {
            VStack(spacing: 12) {
                ForEach(0..<2, id: \.self) { _ in
                    HStack(spacing: 8) {
                        ForEach(0..<10, id: \.self) { _ in
                            Circle()
                                .stroke(Color.white.opacity(0.22), style: StrokeStyle(lineWidth: 1.5, dash: [3, 3]))
                                .frame(width: 16, height: 16)
                        }
                    }
                }
            }
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 18) {
                Text("No habits yet.")
                    .font(CoachStyle.display(30))
                    .foregroundStyle(CoachStyle.ink)
                HStack(spacing: 28) {
                    step(1, "Pick a habit")
                    step(2, "Dictate as usual")
                    step(3, "See if it stuck")
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 40)
        .padding(.vertical, 36)
        .coachSurface()
    }

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(spacing: 12) {
            Text("\(number)")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.Orttaai.accent)
                .frame(width: 30, height: 30)
                .background(Circle().fill(Color.Orttaai.accent.opacity(0.16)))
            Text(text)
                .font(.system(size: 15))
                .foregroundStyle(CoachStyle.ink2)
        }
    }

    private func suggestionSection(title: String, picks: [CoachFocusPick]) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(CoachStyle.ink)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 280), spacing: 16)], spacing: 16) {
                ForEach(Array(picks.enumerated()), id: \.element.id) { index, pick in
                    SuggestionCard(pick: pick, highlighted: index == 0 && snapshot.habits.isEmpty) {
                        center.startHabit(pick)
                    }
                }
            }
        }
    }
}

private struct FeaturedHabitCard: View {
    let state: CoachHabitState
    let onStop: () -> Void

    var body: some View {
        let v = state.verdict
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 32) {
                headline.frame(width: 250, alignment: .leading)
                dots
                example.frame(width: 300)
            }
            .frame(idealWidth: 1_000)
            VStack(alignment: .leading, spacing: 24) {
                headline
                dots
                example
            }
        }
        .padding(26)
        .coachSurface()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(state.measure.habitTitle), \(v.status.title)")
    }

    private var headline: some View {
        let v = state.verdict
        return VStack(alignment: .leading, spacing: 10) {
            CoachTag(text: v.status.title, color: v.status.color)
            VStack(alignment: .leading, spacing: 2) {
                Text(state.measure.habitTitle)
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(CoachStyle.ink)
                    .fixedSize(horizontal: false, vertical: true)
                Text(CoachFormat.modeLabel(state.mode))
                    .font(CoachStyle.label)
                    .foregroundStyle(CoachStyle.ink3)
            }
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(CoachFormat.percent(v.beforeShare))
                    .font(CoachStyle.display(28))
                    .foregroundStyle(CoachStyle.muted)
                Image(systemName: "arrow.right")
                    .foregroundStyle(CoachStyle.ink3)
                Text(CoachFormat.percent(v.afterShare))
                    .font(CoachStyle.display(52))
                    .foregroundStyle(v.status == .working ? CoachStyle.gain : CoachStyle.ink)
            }
            Text("\(v.sinceCount) dictations since \(state.habit.startedAt.formatted(.dateTime.month().day()))")
                .font(CoachStyle.label)
                .foregroundStyle(CoachStyle.ink3)
            Button("Stop this habit", action: onStop)
                .buttonStyle(.plain)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.Orttaai.accent)
                .padding(.top, 4)
        }
    }

    private var dots: some View {
        let v = state.verdict
        return VStack(alignment: .leading, spacing: 14) {
            dotRow(title: "\(v.before.count) dictations before", hits: v.before, total: HabitJudge.window, warm: false)
            dotRow(title: v.after.isEmpty ? "Since you started" : "\(v.after.count) since you started", hits: v.after, total: HabitJudge.window, warm: true)
            HStack(spacing: 16) {
                key(Color.Orttaai.accent, state.measure.hitTitle)
                key(Color.white.opacity(0.14), "Not this time")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func dotRow(title: String, hits: [Bool], total: Int, warm: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(CoachStyle.label)
                .foregroundStyle(warm ? CoachStyle.warmInk : CoachStyle.ink3)
            HStack(spacing: 6) {
                ForEach(0..<total, id: \.self) { index in
                    if index < hits.count {
                        Circle()
                            .fill(hits[index] ? Color.Orttaai.accent : Color.white.opacity(0.14))
                            .frame(width: 14, height: 14)
                    } else {
                        Circle()
                            .stroke(Color.white.opacity(0.2), style: StrokeStyle(lineWidth: 1.5, dash: [3, 3]))
                            .frame(width: 14, height: 14)
                    }
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(hits.filter { $0 }.count) of \(hits.count) met it")
        }
    }

    private func key(_ color: Color, _ text: String) -> some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 10, height: 10)
            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(CoachStyle.ink2)
        }
    }

    @ViewBuilder
    private var example: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let quote = state.example {
                Text(exampleLabel(quote))
                    .font(CoachStyle.label)
                    .foregroundStyle(CoachStyle.ink3)
                Text("“\(quote.text)”")
                    .font(.system(size: 15))
                    .foregroundStyle(CoachStyle.ink)
                    .lineLimit(5)
            } else {
                Text("Best example")
                    .font(CoachStyle.label)
                    .foregroundStyle(CoachStyle.ink3)
                Text("Your first dictation that does it will show here.")
                    .font(.system(size: 15))
                    .foregroundStyle(CoachStyle.ink3)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color(hex: "1B1A1D")))
    }

    private func exampleLabel(_ quote: CoachQuote) -> String {
        let when = quote.createdAt.formatted(.dateTime.weekday(.abbreviated))
        if let app = quote.appName, !app.isEmpty { return "Best example · \(app), \(when)" }
        return "Best example · \(when)"
    }
}

private struct HabitCard: View {
    let state: CoachHabitState
    let onStop: () -> Void

    var body: some View {
        let v = state.verdict
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(state.measure.habitTitle)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(CoachStyle.ink)
                Spacer()
                CoachTag(text: v.status.title, color: v.status.color)
            }
            Text(CoachFormat.modeLabel(state.mode))
                .font(CoachStyle.label)
                .foregroundStyle(CoachStyle.ink3)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(CoachFormat.figure(v.beforeValue, state.measure))
                    .font(CoachStyle.display(22))
                    .foregroundStyle(CoachStyle.muted)
                Text("→").foregroundStyle(CoachStyle.ink3)
                Text(CoachFormat.figure(v.afterValue, state.measure))
                    .font(CoachStyle.display(40))
                    .foregroundStyle(CoachStyle.ink)
                Text(state.measure.unit)
                    .font(CoachStyle.label)
                    .foregroundStyle(CoachStyle.ink3)
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.08))
                    Capsule()
                        .fill(Color.Orttaai.accent)
                        .frame(width: proxy.size.width * Double(min(v.sinceCount, HabitJudge.window)) / Double(HabitJudge.window))
                }
            }
            .frame(height: 8)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(min(v.sinceCount, HabitJudge.window)) of \(HabitJudge.window) dictations since it started")
            HStack {
                Text(CoachCopy.progressLine(v))
                    .font(CoachStyle.label)
                    .foregroundStyle(CoachStyle.ink3)
                Spacer()
                Button("Stop", action: onStop)
                    .buttonStyle(.plain)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.Orttaai.accent)
            }
        }
        .padding(22)
        .coachSurface()
    }
}

private struct SuggestionCard: View {
    let pick: CoachFocusPick
    let highlighted: Bool
    let onStart: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(CoachFormat.modeLabel(pick.mode))
                .font(CoachStyle.label)
                .foregroundStyle(highlighted ? CoachStyle.warmInk : CoachStyle.ink3)
            Text(pick.measure.habitTitle)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(CoachStyle.ink)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(CoachFormat.figure(pick.figure, pick.measure))
                    .font(CoachStyle.display(40))
                    .foregroundStyle(CoachStyle.ink)
                Text(pick.measure.unit + " now")
                    .font(CoachStyle.label)
                    .foregroundStyle(CoachStyle.ink3)
            }
            if highlighted {
                Button("Start this habit", action: onStart)
                    .buttonStyle(CoachPrimaryButtonStyle())
                    .frame(maxWidth: .infinity)
            } else {
                Button("Start this habit", action: onStart)
                    .buttonStyle(CoachSecondaryButtonStyle())
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .coachSurface(highlighted ? CoachStyle.warm : CoachStyle.surface, border: highlighted ? CoachStyle.warmBorder : CoachStyle.line)
    }
}
