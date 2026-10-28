// CoachPathView.swift
// Orttaai
//
// Each track as a journey: mastered skills lit, the current one glowing,
// reviews flagged, and the reps for whichever skill you pick.

import CoachCore
import SwiftUI

struct CoachPathView: View {
    let snapshot: CoachSnapshot
    @ObservedObject private var center = CoachCenter.shared
    @State private var track: CoachTrack?
    @State private var selected: String?

    private var currentTrack: CoachTrack { track ?? snapshot.todaysSkill.track }

    var body: some View {
        let track = currentTrack
        let current = snapshot.currentSkill(in: track)
        let skill = track.skills.first { $0.id == selected } ?? current
        CoachPage(eyebrow: "Path", title: track.title) {
            trackTabs
        } content: {
            journey(track, current: current, selected: skill)
                .frame(height: 280)
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 20) {
                    repsCard(skill).frame(minWidth: 520, idealWidth: 720, maxWidth: .infinity)
                    trackCard(track).frame(width: 300)
                }
                VStack(spacing: 20) {
                    repsCard(skill)
                    trackCard(track)
                }
            }
        }
    }

    /// The tracks, on the title row's right.
    private var trackTabs: some View {
        HStack(spacing: 24) {
            ForEach(CoachTrack.allCases) { item in
                let on = item == currentTrack
                Button {
                    track = item
                    selected = nil
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.title)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(on ? CoachStyle.ink : CoachStyle.ink3)
                        Text(snapshot.masteredCount(in: item) == 0 ? "Start here" : "Level \(snapshot.level(of: item)) · \(snapshot.masteredCount(in: item)) of \(item.skills.count)")
                            .font(.system(size: 12))
                            .foregroundStyle(CoachStyle.ink3)
                    }
                    .fixedSize()
                    .padding(.bottom, 8)
                    .overlay(alignment: .bottom) {
                        Rectangle().fill(on ? Color.Orttaai.accent : .clear).frame(height: 2)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
    }

    // MARK: Journey

    private func journey(_ track: CoachTrack, current: CoachSkill, selected: CoachSkill) -> some View {
        let skills = track.skills
        let currentIndex = skills.firstIndex(of: current) ?? 0
        return GeometryReader { proxy in
            let points = nodePoints(count: skills.count, size: proxy.size)
            ZStack(alignment: .topLeading) {
                Path { path in
                    guard let first = points.first else { return }
                    path.move(to: first)
                    for index in 1..<max(1, currentIndex + 1) where index < points.count {
                        curve(&path, from: points[index - 1], to: points[index])
                    }
                }
                .stroke(Color.Orttaai.accent, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                Path { path in
                    guard currentIndex < points.count else { return }
                    path.move(to: points[currentIndex])
                    for index in (currentIndex + 1)..<max(currentIndex + 1, points.count) {
                        curve(&path, from: points[index - 1], to: points[index])
                    }
                }
                .stroke(Color.white.opacity(0.16), style: StrokeStyle(lineWidth: 3, lineCap: .round, dash: [2, 10]))
                ForEach(Array(skills.enumerated()), id: \.element.id) { index, skill in
                    node(skill, number: index + 1, isCurrent: skill == current, isSelected: skill == selected)
                        .position(points[index])
                    label(skill, isCurrent: skill == current)
                        .position(x: points[index].x, y: points[index].y + (index.isMultiple(of: 2) ? 58 : -60))
                }
            }
        }
    }

    private func nodePoints(count: Int, size: CGSize) -> [CGPoint] {
        guard count > 0 else { return [] }
        let inset: CGFloat = 70
        let step = count > 1 ? (size.width - inset * 2) / CGFloat(count - 1) : 0
        return (0..<count).map { index in
            CGPoint(x: inset + step * CGFloat(index), y: index.isMultiple(of: 2) ? size.height * 0.62 : size.height * 0.36)
        }
    }

    private func curve(_ path: inout Path, from a: CGPoint, to b: CGPoint) {
        let midX = (a.x + b.x) / 2
        path.addCurve(to: b, control1: CGPoint(x: midX, y: a.y), control2: CGPoint(x: midX, y: b.y))
    }

    private func node(_ skill: CoachSkill, number: Int, isCurrent: Bool, isSelected: Bool) -> some View {
        let progress = snapshot.progress(skill)
        let mastered = progress.mastered
        let due = progress.reviewDue(now: snapshot.builtAt)
        return Button {
            selected = skill.id
        } label: {
            ZStack {
                if isCurrent {
                    Circle().stroke(Color.Orttaai.accent.opacity(0.25), lineWidth: 1).frame(width: 112, height: 112)
                    Circle().stroke(Color.Orttaai.accent.opacity(0.45), lineWidth: 1).frame(width: 92, height: 92)
                    Circle().fill(Color.Orttaai.accent).frame(width: 70, height: 70)
                        .shadow(color: Color.Orttaai.accent.opacity(0.35), radius: 14, y: 8)
                    Text("\(number)")
                        .font(CoachStyle.display(26))
                        .foregroundStyle(Color(hex: "1B1917"))
                } else if mastered {
                    Circle().fill(Color.Orttaai.accent).frame(width: 46, height: 46)
                    Image(systemName: "checkmark")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(Color(hex: "1B1917"))
                } else {
                    Circle().fill(Color(hex: "1C1B1E")).frame(width: 46, height: 46)
                    Circle().stroke(Color.white.opacity(0.22), lineWidth: 2).frame(width: 46, height: 46)
                    Text("\(number)")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(CoachStyle.ink2)
                }
                if isSelected && !isCurrent {
                    Circle().stroke(CoachStyle.ink, lineWidth: 2).frame(width: 56, height: 56)
                }
                if due {
                    Text("Review")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color(hex: "F0C27A"))
                        .padding(.horizontal, 7)
                        .frame(height: 20)
                        .background(Capsule().fill(Color(hex: "3A3122")))
                        .overlay(Capsule().stroke(Color.Orttaai.accent.opacity(0.4), lineWidth: 1))
                        .offset(x: 30, y: -30)
                }
            }
            .frame(width: 112, height: 112)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(skill.title)\(mastered ? ", mastered" : "")\(isCurrent ? ", you are here" : "")")
    }

    private func label(_ skill: CoachSkill, isCurrent: Bool) -> some View {
        VStack(spacing: 2) {
            Text(skill.title)
                .font(.system(size: isCurrent ? 16 : 14, weight: .semibold))
                .foregroundStyle(isCurrent || snapshot.progress(skill).mastered ? CoachStyle.ink : CoachStyle.ink2)
            if isCurrent {
                Text("You are here")
                    .font(.system(size: 12))
                    .foregroundStyle(CoachStyle.warmInk)
            }
        }
        .fixedSize()
        .accessibilityHidden(true)
    }

    // MARK: Reps

    private func repsCard(_ skill: CoachSkill) -> some View {
        let progress = snapshot.progress(skill)
        return VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                Text(skill.title)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(CoachStyle.ink)
                Spacer()
                masteryDots(progress)
            }
            Text(skill.why)
                .font(.system(size: 15))
                .foregroundStyle(CoachStyle.ink2)
            VStack(spacing: 10) {
                ForEach(CoachRepKind.practice, id: \.self) { kind in
                    repRow(skill, kind)
                }
            }
        }
        .padding(22)
        .coachSurface()
    }

    private func masteryDots(_ progress: CoachSkillProgress) -> some View {
        HStack(spacing: 6) {
            ForEach(0..<CoachScore.repsToMaster, id: \.self) { index in
                Circle()
                    .fill(index < progress.strongReps ? Color.Orttaai.accent : Color.white.opacity(0.12))
                    .frame(width: 10, height: 10)
            }
            Text(progress.mastered ? "Mastered" : "\(min(progress.strongReps, CoachScore.repsToMaster)) of \(CoachScore.repsToMaster) strong reps")
                .font(CoachStyle.label)
                .foregroundStyle(CoachStyle.ink3)
        }
        .accessibilityElement(children: .combine)
    }

    private func repRow(_ skill: CoachSkill, _ kind: CoachRepKind) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon(kind))
                .font(.system(size: 18))
                .foregroundStyle(Color.Orttaai.accent)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(kind.title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(CoachStyle.ink)
                Text(kind == .drill ? skill.drill : kind == .redo ? "One of your own dictations, said better" : "A minute, from your own work")
                    .font(CoachStyle.label)
                    .foregroundStyle(CoachStyle.ink3)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Button("Speak") { Task { await center.beginRep(skill, kind: kind, spoken: true) } }
                .buttonStyle(CoachPrimaryButtonStyle())
            if !skill.speakOnly && kind != .timed {
                Button("Type") { Task { await center.beginRep(skill, kind: kind, spoken: false) } }
                    .buttonStyle(CoachSecondaryButtonStyle())
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(CoachStyle.surfaceRaised))
    }

    private func icon(_ kind: CoachRepKind) -> String {
        switch kind {
        case .redo: return "arrow.counterclockwise"
        case .drill: return "square.text.square"
        case .timed: return "timer"
        case .scene: return "person.2.wave.2"
        }
    }

    private func trackCard(_ track: CoachTrack) -> some View {
        let reps = track.skills.reduce(0) { $0 + snapshot.progress($1).reps }
        return VStack(alignment: .leading, spacing: 14) {
            Text("This track")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(CoachStyle.ink)
            stat("\(snapshot.level(of: track))", "level")
            stat("\(snapshot.masteredCount(in: track)) of \(track.skills.count)", "skills mastered")
            stat("\(reps)", reps == 1 ? "rep so far" : "reps so far")
            Text("A skill is mastered after three reps scoring 4 or more with its own check met.")
                .font(CoachStyle.label)
                .foregroundStyle(CoachStyle.ink3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .coachSurface()
    }

    private func stat(_ value: String, _ label: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(value)
                .font(CoachStyle.display(26))
                .foregroundStyle(CoachStyle.ink)
            Text(label)
                .font(.system(size: 14))
                .foregroundStyle(CoachStyle.ink3)
        }
    }
}
