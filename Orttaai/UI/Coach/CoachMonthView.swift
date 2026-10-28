// CoachMonthView.swift
// Orttaai
//
// Your month: a calendar month looked back on, and stepped back through.
// The numbers, the voice shape against the month before, what moved, the
// practice and habits, and the month's best moment. Plus the monthly card.

import CoachCore
import SwiftUI

struct CoachMonthView: View {
    let onBack: () -> Void
    @ObservedObject private var center = CoachCenter.shared
    @State private var month = Date()
    @State private var report: CoachMonthReport?
    @State private var lens: CoachMode?
    @State private var sharing = false

    /// Opens on this month, or on a report already worked out.
    init(report: CoachMonthReport? = nil, lens: CoachMode? = nil, onBack: @escaping () -> Void) {
        self.onBack = onBack
        _report = State(initialValue: report)
        _month = State(initialValue: report?.month.start ?? Date())
        _lens = State(initialValue: lens)
    }

    var body: some View {
        CoachPage(eyebrow: "Your month", title: (report?.month.start ?? month).formatted(.dateTime.month(.wide).year())) {
            HStack(spacing: 10) {
                stepper
                if let report, !report.isEmpty {
                    Button {
                        sharing = true
                    } label: {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(CoachSecondaryButtonStyle())
                }
                Button("Proof", action: onBack)
                    .buttonStyle(CoachSecondaryButtonStyle())
            }
        } content: {
            if let report {
                if report.isEmpty {
                    emptyCard(report)
                } else {
                    stats(report)
                    shapeRow(report)
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .top, spacing: 16) {
                            practiceCard(report)
                            habitsCard(report)
                        }
                        VStack(spacing: 16) {
                            practiceCard(report)
                            habitsCard(report)
                        }
                    }
                    if let quote = report.bestMoment {
                        momentCard(quote, axis: report.bestMomentAxis)
                    }
                }
            } else {
                CoachLoadingView()
                    .frame(height: 300)
            }
        }
        .task(id: month) {
            report = await center.monthReport(for: month)
        }
        .sheet(isPresented: $sharing) {
            if let report {
                CoachCardShareSheet(
                    title: "Share this month",
                    fileName: "Orttaai-Coach-\(report.month.start.formatted(.iso8601.year().month())).png",
                    size: CoachMonthCard.size,
                    card: CoachMonthCard(report: report)
                )
            }
        }
    }

    // MARK: Stepping between months

    private var stepper: some View {
        let calendar = Calendar.current
        let start = report?.month.start ?? month
        let canGoBack = report?.firstMonth.map { $0 < start } ?? false
        let canGoForward = !(report?.isCurrent ?? true)
        return HStack(spacing: 2) {
            stepButton("chevron.left", label: "Previous month", enabled: canGoBack) {
                month = calendar.date(byAdding: .month, value: -1, to: start) ?? start
            }
            stepButton("chevron.right", label: "Next month", enabled: canGoForward) {
                month = calendar.date(byAdding: .month, value: 1, to: start) ?? start
            }
        }
        .padding(4)
        .background(Capsule().fill(Color.white.opacity(0.06)))
        .overlay(Capsule().stroke(Color.white.opacity(0.12), lineWidth: 1))
    }

    private func stepButton(_ icon: String, label: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(enabled ? CoachStyle.ink : CoachStyle.muted.opacity(0.5))
                .frame(width: 36, height: 36)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(label)
    }

    // MARK: Numbers

    private func stats(_ report: CoachMonthReport) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 16), count: 4), spacing: 16) {
            stat("\(report.dictations)", "dictations", note: comparison(report.dictations, report.dictationsBefore))
            stat(report.words.formatted(), "words", note: nil)
            stat("\(report.daysDictated)", report.daysDictated == 1 ? "day dictated" : "days dictated", note: nil)
            stat("\(report.reps)", report.reps == 1 ? "rep" : "reps", note: report.masteredCount > 0 ? "\(report.masteredCount) mastered" : nil)
        }
    }

    private func comparison(_ now: Int, _ before: Int) -> String? {
        guard before > 0 else { return nil }
        let change = Double(now - before) / Double(before)
        if abs(change) < 0.05 { return "about the same as last month" }
        return "\(change > 0 ? "+" : "")\(Int((change * 100).rounded()))% on last month"
    }

    private func stat(_ value: String, _ label: String, note: String?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value)
                .font(CoachStyle.display(38))
                .foregroundStyle(CoachStyle.ink)
            Text(label)
                .font(.system(size: 14))
                .foregroundStyle(CoachStyle.ink2)
            Text(note ?? " ")
                .font(CoachStyle.label)
                .foregroundStyle(CoachStyle.ink3)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .coachSurface()
        .accessibilityElement(children: .combine)
    }

    // MARK: Shape and what moved

    private func shapeRow(_ report: CoachMonthReport) -> some View {
        let shape = report.shape(for: lens)
        let moves = report.moves(for: lens)
        return VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 6) {
                Text("Your voice this month")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(CoachStyle.ink)
                CoachInfoButton(
                    title: "Your voice this month",
                    text: "The month so far, or the whole month once it's over, against the month before as the dashed outline. Points marked with a bubble are judged by your local model; the rest are counted. Each needs 8 dictations in the month."
                )
                Spacer()
                lensPicker
            }
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 28) {
                    VoiceShapeView(shape: shape)
                        .frame(width: 400, height: 360)
                    movesList(moves, shape: shape)
                }
                .frame(idealWidth: 1_000)
                VStack(alignment: .leading, spacing: 18) {
                    VoiceShapeView(shape: shape)
                        .frame(height: 360)
                    movesList(moves, shape: shape)
                }
            }
            HStack(spacing: 16) {
                legend("This month", dashed: false)
                if !shape.thenAxes.isEmpty {
                    legend(report.previous.start.formatted(.dateTime.month(.wide)), dashed: true)
                }
            }
        }
        .padding(22)
        .coachSurface()
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

    private var lensPicker: some View {
        HStack(spacing: 4) {
            ForEach([nil] + CoachMode.shaped.map(Optional.some), id: \.self) { (item: CoachMode?) in
                let selected = item == lens
                Button {
                    lens = item
                } label: {
                    Text(CoachFormat.modeLabel(item))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(selected ? Color(hex: "1B1917") : CoachStyle.ink2)
                        .padding(.horizontal, 12)
                        .frame(height: 30)
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

    @ViewBuilder
    private func movesList(_ moves: [CoachMonthMove], shape: CoachShape) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("What moved")
                .font(CoachStyle.eyebrow)
                .tracking(1)
                .foregroundStyle(CoachStyle.ink3)
            if moves.isEmpty {
                Text(shape.thenIsComplete ? "Everything held within 3 points of last month." : "Last month didn't have enough dictations here to compare.")
                    .font(.system(size: 15))
                    .foregroundStyle(CoachStyle.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(moves) { move in
                    HStack(spacing: 12) {
                        Text(move.axis.title)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(CoachStyle.ink)
                        Spacer(minLength: 8)
                        Text("\(CoachFormat.percent(move.then)) → \(CoachFormat.percent(move.now))")
                            .font(.system(size: 14))
                            .foregroundStyle(CoachStyle.ink3)
                        CoachTag(text: CoachFormat.points(move.change), color: move.change > 0 ? CoachStyle.gain : CoachStyle.warmInk)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    // MARK: Practice and habits

    private func practiceCard(_ report: CoachMonthReport) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Practice")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(CoachStyle.ink)
            if report.reps == 0 {
                Text("No reps this month.")
                    .font(.system(size: 15))
                    .foregroundStyle(CoachStyle.ink2)
            } else {
                ForEach(report.tracks.filter { $0.reps > 0 }) { item in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(item.track.title)
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(CoachStyle.ink)
                            Spacer()
                            Text("\(item.reps) \(item.reps == 1 ? "rep" : "reps")")
                                .font(.system(size: 14))
                                .foregroundStyle(CoachStyle.ink3)
                        }
                        if !item.mastered.isEmpty {
                            Text("Mastered " + item.mastered.map(\.title).joined(separator: ", "))
                                .font(.system(size: 13))
                                .foregroundStyle(CoachStyle.gain)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
                if let best = report.bestRep {
                    Divider().overlay(CoachStyle.line)
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(String(format: "%.1f", best.score))
                            .font(CoachStyle.display(30))
                            .foregroundStyle(Color.Orttaai.accent)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Best rep: \(best.skill.title)")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(CoachStyle.ink)
                            Text(best.createdAt.formatted(.dateTime.month(.abbreviated).day()))
                                .font(CoachStyle.label)
                                .foregroundStyle(CoachStyle.ink3)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .coachSurface()
    }

    private func habitsCard(_ report: CoachMonthReport) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 6) {
                Text("Habits")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(CoachStyle.ink)
                CoachInfoButton(
                    title: "Habits this month",
                    text: "Each habit that ran this month, judged on your dictations up to the month's end: the share that met it in the 20 before it started, and in the latest 20 since."
                )
            }
            if report.habits.isEmpty {
                Text("No habits ran this month.")
                    .font(.system(size: 15))
                    .foregroundStyle(CoachStyle.ink2)
            } else {
                ForEach(report.habits) { state in
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(state.title)
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(CoachStyle.ink)
                            Text("\(CoachFormat.percent(state.verdict.beforeShare)) → \(CoachFormat.percent(state.verdict.afterShare)) · \(CoachFormat.modeLabel(state.mode))")
                                .font(.system(size: 13))
                                .foregroundStyle(CoachStyle.ink3)
                        }
                        Spacer(minLength: 8)
                        CoachTag(text: state.habit.endedAt == nil ? state.verdict.status.title : "Stopped", color: state.habit.endedAt == nil ? state.verdict.status.color : CoachStyle.muted)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .coachSurface()
    }

    // MARK: Best moment and empty

    private func momentCard(_ quote: CoachQuote, axis: CoachAxis?) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(["Best moment", axis?.title, quote.appName, quote.createdAt.formatted(.dateTime.month(.abbreviated).day())]
                .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                .font(CoachStyle.label)
                .foregroundStyle(CoachStyle.warmInk)
            Text("“\(quote.text)”")
                .font(.system(size: 19, weight: .medium))
                .foregroundStyle(CoachStyle.ink)
                .lineLimit(5)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .coachSurface(CoachStyle.warm, border: CoachStyle.warmBorder)
    }

    private func emptyCard(_ report: CoachMonthReport) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(report.isCurrent ? "This month has only just begun." : "Nothing to look back on in \(report.month.start.formatted(.dateTime.month(.wide))).")
                .font(CoachStyle.display(26))
                .foregroundStyle(CoachStyle.ink)
            Text("Dictate as usual or do a rep, and your month fills in here.")
                .font(.system(size: 15))
                .foregroundStyle(CoachStyle.ink2)
        }
        .padding(28)
        .frame(maxWidth: .infinity, alignment: .leading)
        .coachSurface()
    }
}

/// The monthly card to share: the month's headline, the shape it was in and
/// three numbers. Numbers only, never anything you said.
struct CoachMonthCard: View {
    static let size = CGSize(width: 1_080, height: 1_350)

    let report: CoachMonthReport

    var body: some View {
        let gain = report.topGain
        let shape = report.shape(for: gain?.mode)
        VStack(alignment: .leading, spacing: 40) {
            HStack(spacing: 16) {
                OrttaaiBrandMark()
                    .frame(width: 42, height: 36)
                Text("COACH")
                    .font(.system(size: 22, weight: .semibold))
                    .tracking(2.6)
                    .foregroundStyle(Color.Orttaai.accent)
                Spacer()
                Text(report.month.start.formatted(.dateTime.month(.wide).year()))
                    .font(.system(size: 22))
                    .foregroundStyle(CoachStyle.ink3)
            }
            headline(gain)
                .font(.system(size: 72, weight: .semibold, design: .rounded))
                .foregroundStyle(CoachStyle.ink)
                .fixedSize(horizontal: false, vertical: true)
            VoiceShapeView(shape: shape, labelFont: .system(size: 20, weight: .semibold))
                .frame(width: 580, height: 580)
                .frame(maxWidth: .infinity)
            HStack(spacing: 24) {
                stat("\(report.dictations)", "dictations")
                stat("\(report.daysDictated)", "days dictated")
                stat("\(report.reps)", "reps")
            }
            Spacer(minLength: 0)
            HStack {
                Text(gain?.mode.map { "Judged and counted on my Mac · \($0.title)" } ?? "Counted on my Mac")
                Spacer()
                Text("Made with Orttaai")
            }
            .font(.system(size: 20))
            .foregroundStyle(CoachStyle.ink3)
        }
        .padding(80)
        .frame(width: Self.size.width, height: Self.size.height)
        .background(CoachStyle.ground)
        .environment(\.colorScheme, .dark)
    }

    private func headline(_ gain: CoachMonthMove?) -> Text {
        let monthName = report.month.start.formatted(.dateTime.month(.wide))
        if let gain {
            return Text(gain.axis.title).foregroundColor(Color.Orttaai.accent)
                + Text(" grew most in \(monthName): \(CoachFormat.percent(gain.then)) to \(CoachFormat.percent(gain.now)).")
        }
        return Text("I talked instead of typed on ")
            + Text("\(report.daysDictated) \(report.daysDictated == 1 ? "day" : "days")").foregroundColor(Color.Orttaai.accent)
            + Text(" in \(monthName).")
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value)
                .font(.system(size: 64, weight: .semibold, design: .rounded))
                .foregroundStyle(CoachStyle.ink)
            Text(label)
                .font(.system(size: 22))
                .foregroundStyle(CoachStyle.ink3)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
