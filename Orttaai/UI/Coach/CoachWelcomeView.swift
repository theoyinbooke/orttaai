// CoachWelcomeView.swift
// Orttaai
//
// Coach's first run: what it found on this Mac, which apps it may read, and
// your first voice shape. Choosing a coach and its models comes with
// practice.

import CoachCore
import SwiftUI

struct CoachWelcomeView: View {
    let onDone: () -> Void

    @ObservedObject private var center = CoachCenter.shared
    /// Read so the checkboxes redraw as soon as a choice is saved.
    @AppStorage(CoachPreferences.overridesKey) private var overridesJSON = ""
    @State private var step: Int
    @State private var installed: [String]?
    @AppStorage(CoachPreferences.personasKey) private var personasJSON = ""
    private let steps = 5

    init(step: Int = 1, onDone: @escaping () -> Void) {
        _step = State(initialValue: step)
        self.onDone = onDone
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            // Centred when it fits; scrolls when the window is short. Without
            // the fallback the window takes the step's height at its narrowest
            // as its minimum, and lays it out far below a normal window.
            ViewThatFits(in: .vertical) {
                stepContent
                    .frame(maxWidth: 1_100, maxHeight: .infinity)
                ScrollView(showsIndicators: false) {
                    stepContent
                        .frame(maxWidth: 1_100)
                        .padding(.vertical, 24)
                }
            }
            footer
        }
        .padding(.horizontal, 64)
        .padding(.top, 28)
        .padding(.bottom, 36)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(alignment: .topTrailing) {
            Circle()
                .fill(RadialGradient(colors: [Color.Orttaai.accent.opacity(0.12), .clear], center: .center, startRadius: 0, endRadius: 340))
                .frame(width: 680, height: 680)
                .offset(x: 200, y: 80)
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private var stepContent: some View {
        if let snapshot = center.snapshot {
            switch step {
            case 1: found(snapshot)
            case 2: apps(snapshot)
            case 3: pickCoach
            case 4: models
            default: firstShape(snapshot)
            }
        } else {
            CoachLoadingView()
        }
    }

    private var header: some View {
        HStack {
            CoachEyebrow(text: "Coach")
            Spacer()
            HStack(spacing: 8) {
                ForEach(1...steps, id: \.self) { index in
                    Capsule()
                        .fill(index <= step ? Color.Orttaai.accent : Color.white.opacity(0.16))
                        .frame(width: index == step ? 28 : 8, height: 8)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Step \(step) of \(steps)")
            Spacer()
            Button("Skip setup", action: onDone)
                .buttonStyle(.plain)
                .font(.system(size: 14))
                .foregroundStyle(Color.Orttaai.accent)
        }
    }

    private var footer: some View {
        HStack(spacing: 14) {
            if step > 1 {
                Button("Back") { withAnimation { step -= 1 } }
                    .buttonStyle(CoachSecondaryButtonStyle())
            }
            Spacer()
            if step == 4, installed?.isEmpty != false {
                Button("Start without them") { withAnimation { step += 1 } }
                    .buttonStyle(CoachSecondaryButtonStyle())
            }
            if step < steps {
                Button(step == 1 ? "Show me" : "Continue") { withAnimation { step += 1 } }
                    .buttonStyle(CoachPrimaryButtonStyle())
                    .disabled(center.snapshot == nil)
            } else {
                Button("Open Today", action: onDone)
                    .buttonStyle(CoachPrimaryButtonStyle())
            }
        }
    }

    // MARK: Steps

    private func found(_ snapshot: CoachSnapshot) -> some View {
        let apps = snapshot.apps.filter { !$0.key.isEmpty }
        let total = snapshot.apps.reduce(0) { $0 + $1.dictations }
        let split = modeSplit(snapshot)
        return HStack(alignment: .center, spacing: 64) {
            VStack(alignment: .leading, spacing: 22) {
                Text("Coach learns from how you already talk.")
                    .font(CoachStyle.display(52))
                    .foregroundStyle(CoachStyle.ink)
                    .fixedSize(horizontal: false, vertical: true)
                Text("No quizzes. It starts from the dictations already on this Mac.")
                    .font(.system(size: 19))
                    .foregroundStyle(Color(hex: "C9C5BF"))
            }
            VStack(alignment: .leading, spacing: 26) {
                bigStat(total.formatted(), sinceLine(snapshot.apps))
                bigStat("\(apps.count)", apps.count == 1 ? "app you talk to" : "apps you talk to")
                VStack(alignment: .leading, spacing: 10) {
                    GeometryReader { proxy in
                        HStack(spacing: 3) {
                            ForEach(split, id: \.mode) { part in
                                Rectangle()
                                    .fill(color(for: part.mode))
                                    .frame(width: max(0, proxy.size.width * part.share - 3))
                            }
                        }
                    }
                    .frame(height: 14)
                    .clipShape(Capsule())
                    HStack(spacing: 18) {
                        ForEach(split, id: \.mode) { part in
                            Text("\(part.mode.shortTitle) \(CoachFormat.percent(part.share))")
                                .font(.system(size: 13))
                                .foregroundStyle(CoachStyle.ink2)
                        }
                    }
                }
                .accessibilityElement(children: .combine)
            }
            .frame(width: 400, alignment: .leading)
        }
        .frame(maxHeight: .infinity)
    }

    private func apps(_ snapshot: CoachSnapshot) -> some View {
        _ = overridesJSON
        let overrides = CoachPreferences.overrides
        let listed = snapshot.apps.filter { !$0.key.isEmpty }
        let groups = CoachMode.allCases.map { mode in
            (mode, listed.filter { app in
                let rule = CoachPreferences.rule(for: app, overrides: overrides)
                let home = rule == .off ? CoachAppCatalog.builtInMode(bundleID: app.bundleID, appName: app.appName) : rule.mode
                return home == mode
            })
        }
        // Every card gets the same list height: the longest list, up to a
        // cap past which it scrolls.
        let rowHeight: CGFloat = 38
        let longest = groups.map(\.1.count).max() ?? 0
        let listHeight = min(max(CGFloat(longest) * rowHeight, rowHeight * 3), 380)
        return VStack(alignment: .leading, spacing: 26) {
            HStack(alignment: .bottom) {
                Text("Choose what Coach may read.")
                    .font(CoachStyle.display(46))
                    .foregroundStyle(CoachStyle.ink)
                Spacer()
                Label("Stays on this Mac", systemImage: "lock")
                    .font(.system(size: 15))
                    .foregroundStyle(Color(hex: "C9C5BF"))
            }
            HStack(alignment: .top, spacing: 16) {
                ForEach(groups, id: \.0) { mode, members in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(mode.title)
                            .font(CoachStyle.label)
                            .foregroundStyle(CoachStyle.ink3)
                            .padding(.bottom, 6)
                        ScrollView(showsIndicators: false) {
                            VStack(alignment: .leading, spacing: 2) {
                                if members.isEmpty {
                                    Text("None yet")
                                        .font(.system(size: 14))
                                        .foregroundStyle(CoachStyle.muted)
                                }
                                ForEach(members) { app in
                                    Toggle(isOn: Binding(
                                        get: { CoachPreferences.rule(for: app, overrides: CoachPreferences.overrides) != .off },
                                        set: { on in
                                            let builtIn = CoachAppCatalog.builtInMode(bundleID: app.bundleID, appName: app.appName)
                                            center.setRule(on ? (CoachAppRule(rawValue: builtIn.rawValue) ?? .elsewhere) : .off, for: app)
                                        }
                                    )) {
                                        Text(app.displayName)
                                            .font(.system(size: 15))
                                            .foregroundStyle(CoachStyle.ink)
                                            .lineLimit(1)
                                    }
                                    .toggleStyle(.checkbox)
                                    .frame(height: rowHeight - 2)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(height: listHeight)
                    }
                    .padding(20)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .coachSurface(Color(hex: "1D1C1F"))
                }
            }
        }
        .frame(maxHeight: .infinity)
    }

    private var pickCoach: some View {
        _ = personasJSON
        let chosen = CoachPreferences.persona(for: .ai)
        return VStack(alignment: .leading, spacing: 30) {
            HStack(alignment: .bottom) {
                Text("Who should coach you?")
                    .font(CoachStyle.display(46))
                    .foregroundStyle(CoachStyle.ink)
                Spacer()
                Text("You can mix them later")
                    .font(.system(size: 15))
                    .foregroundStyle(Color(hex: "C9C5BF"))
            }
            HStack(spacing: 14) {
                ForEach(CoachPersona.allCases) { persona in
                    let on = persona == chosen
                    Button {
                        for mode in CoachMode.allCases { CoachPreferences.setPersona(persona, for: mode) }
                    } label: {
                        VStack(spacing: 12) {
                            CoachPersonaGlyph(persona: persona, size: 76)
                            Text(persona.name)
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundStyle(CoachStyle.ink)
                            Text(persona.trait)
                                .font(.system(size: 13))
                                .foregroundStyle(CoachStyle.ink2)
                                .multilineTextAlignment(.center)
                        }
                        .padding(.vertical, 24)
                        .padding(.horizontal, 12)
                        .frame(maxWidth: .infinity)
                        .coachSurface(on ? CoachStyle.warm : Color(hex: "1D1C1F"), border: on ? Color.Orttaai.accent.opacity(0.6) : CoachStyle.line)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
            Text("“\(chosen.sample)”")
                .font(.system(size: 19))
                .foregroundStyle(CoachStyle.ink2)
        }
        .frame(maxHeight: .infinity)
    }

    private var models: some View {
        VStack(alignment: .leading, spacing: 26) {
            HStack(alignment: .bottom) {
                Text("Give Coach its voice.")
                    .font(CoachStyle.display(46))
                    .foregroundStyle(CoachStyle.ink)
                Spacer()
                Text("Change these any time in Cast › Models.")
                    .font(.system(size: 15))
                    .foregroundStyle(Color(hex: "C9C5BF"))
            }
            CoachModelSetupList()
        }
        .frame(maxHeight: .infinity)
        .task { installed = await CoachModels.installed() }
        // Seen here, so it doesn't pop up again the moment the welcome ends.
        .onDisappear { UserDefaults.standard.set(true, forKey: CoachPreferences.modelSetupSeenKey) }
    }

    private func firstShape(_ snapshot: CoachSnapshot) -> some View {
        let mode = snapshot.busiestMode
        let shape = snapshot.shape(for: mode)
        let strongest = shape.now.max { $0.value < $1.value }?.key
        let room = snapshot.focus?.measure ?? shape.now.min { $0.value < $1.value }?.key
        return HStack(alignment: .center, spacing: 56) {
            VStack(alignment: .leading, spacing: 26) {
                Text(shape.now.isEmpty ? "Your shape starts with your next dictation." : "Here's how you talk to \(mode == .ai ? "AI" : mode == .people ? "people" : "the page").")
                    .font(CoachStyle.display(50))
                    .foregroundStyle(CoachStyle.ink)
                    .fixedSize(horizontal: false, vertical: true)
                if let strongest, let room, strongest != room {
                    HStack(spacing: 40) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Strongest").font(.system(size: 14)).foregroundStyle(CoachStyle.ink3)
                            Text(strongest.axisTitle).font(.system(size: 24, weight: .semibold)).foregroundStyle(CoachStyle.ink)
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Most room").font(.system(size: 14)).foregroundStyle(CoachStyle.ink3)
                            Text(room.axisTitle).font(.system(size: 24, weight: .semibold)).foregroundStyle(Color.Orttaai.accent)
                        }
                    }
                }
                Text(shape.isComplete ? "It sharpens as you keep dictating." : "Keep dictating as usual; the rest fills in on its own.")
                    .font(.system(size: 19))
                    .foregroundStyle(Color(hex: "C9C5BF"))
            }
            VoiceShapeView(shape: shape, showsThen: false)
                .frame(width: 440, height: 440)
        }
        .frame(maxHeight: .infinity)
    }

    // MARK: Helpers

    private func bigStat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(value)
                .font(CoachStyle.display(60))
                .foregroundStyle(CoachStyle.ink)
            Text(label)
                .font(.system(size: 14))
                .foregroundStyle(CoachStyle.ink3)
        }
    }

    private func sinceLine(_ apps: [CoachAppUsage]) -> String {
        guard let first = apps.compactMap(\.firstAt).min() else { return "dictations" }
        return "dictations since \(first.formatted(.dateTime.month(.wide).year()))"
    }

    private func modeSplit(_ snapshot: CoachSnapshot) -> [(mode: CoachMode, share: Double)] {
        let overrides = CoachPreferences.overrides
        var counts: [CoachMode: Int] = [:]
        for app in snapshot.apps {
            guard let mode = CoachPreferences.rule(for: app, overrides: overrides).mode else { continue }
            counts[mode, default: 0] += app.dictations
        }
        let total = max(1, counts.values.reduce(0, +))
        return CoachMode.allCases
            .compactMap { mode in counts[mode].map { (mode: mode, share: Double($0) / Double(total)) } }
            .filter { $0.share > 0 }
    }

    private func color(for mode: CoachMode) -> Color {
        switch mode {
        case .ai: return Color.Orttaai.accent
        case .people: return Color(hex: "B07A2E")
        case .writing: return Color(hex: "6B5532")
        case .elsewhere: return Color(hex: "4A4642")
        }
    }
}
