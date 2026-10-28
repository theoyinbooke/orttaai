// CoachCastView.swift
// Orttaai
//
// Your coaches: one for each way of talking, picked by their voice, and the
// local models that judge and write.

import CoachCore
import SwiftUI

struct CoachCastView: View {
    let snapshot: CoachSnapshot
    @State private var seat: CoachMode = .ai
    @State private var showingModels = false
    /// Read so the cards redraw when a coach is chosen.
    @AppStorage(CoachPreferences.personasKey) private var personasJSON = ""

    var body: some View {
        if showingModels {
            CoachModelsView(onBack: { showingModels = false })
        } else {
            cast
        }
    }

    private var cast: some View {
        _ = personasJSON
        let setup = CoachModels.current()
        return CoachPage(eyebrow: "Cast", title: "Your coaches") {
            CoachInfoButton(title: "Your coaches", text: "Coaches change the words, never the score. Pick a seat, then the coach for it.")
        } content: {
            HStack(spacing: 14) {
                ForEach(CoachMode.shaped) { mode in
                    seatButton(mode)
                }
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 12)], spacing: 12) {
                ForEach(CoachPersona.allCases) { persona in
                    personaCard(persona)
                }
            }
            HStack(spacing: 22) {
                Text("On this Mac")
                    .font(CoachStyle.label)
                    .foregroundStyle(CoachStyle.ink3)
                modelLabel("Coach", setup.coachModel)
                modelLabel("Judge", setup.judgeModel)
                modelLabel("Server", setup.provider.displayName)
                Spacer()
                Button("Change models") { showingModels = true }
                    .buttonStyle(.plain)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.Orttaai.accent)
            }
            .padding(.horizontal, 20)
            .frame(height: 52)
            .coachSurface()
        }
    }

    private func seatButton(_ mode: CoachMode) -> some View {
        let persona = CoachPreferences.persona(for: mode)
        let on = mode == seat
        return Button {
            seat = mode
        } label: {
            HStack(spacing: 14) {
                CoachPersonaGlyph(persona: persona, size: 48)
                VStack(alignment: .leading, spacing: 2) {
                    Text(mode.title)
                        .font(CoachStyle.label)
                        .foregroundStyle(CoachStyle.ink3)
                    Text(persona.name)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(CoachStyle.ink)
                }
                Spacer(minLength: 0)
                Text(CoachFormat.percent(share(of: mode)))
                    .font(CoachStyle.label)
                    .foregroundStyle(CoachStyle.ink3)
            }
            .padding(16)
            .frame(maxWidth: .infinity)
            .coachSurface(on ? CoachStyle.warm : CoachStyle.surface, border: on ? Color.Orttaai.accent.opacity(0.6) : CoachStyle.line)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private func share(of mode: CoachMode) -> Double? {
        let total = CoachMode.shaped.reduce(0) { $0 + (snapshot.recentByMode[$1] ?? 0) }
        guard total > 0 else { return nil }
        return Double(snapshot.recentByMode[mode] ?? 0) / Double(total)
    }

    private func personaCard(_ persona: CoachPersona) -> some View {
        let on = CoachPreferences.persona(for: seat) == persona
        return Button {
            CoachPreferences.setPersona(persona, for: seat)
        } label: {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    CoachPersonaGlyph(persona: persona, size: 60)
                    Spacer()
                    if on {
                        Image(systemName: "checkmark")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(Color.Orttaai.accent)
                    }
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(persona.name)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(CoachStyle.ink)
                    Text(persona.trait)
                        .font(CoachStyle.label)
                        .foregroundStyle(CoachStyle.warmInk)
                }
                Text("“\(persona.sample)”")
                    .font(.system(size: 14))
                    .foregroundStyle(CoachStyle.ink2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button {
                    CoachVoice.shared.speak(persona.sample)
                } label: {
                    Label("Hear", systemImage: "play.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(CoachStyle.ink)
                        .padding(.horizontal, 12)
                        .frame(height: 30)
                        .background(Capsule().fill(Color.white.opacity(0.07)))
                }
                .buttonStyle(.plain)
            }
            .padding(18)
            .frame(maxWidth: .infinity, minHeight: 280, alignment: .topLeading)
            .coachSurface(on ? CoachStyle.warm : CoachStyle.surface, border: on ? Color.Orttaai.accent.opacity(0.6) : CoachStyle.line)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(persona.name), \(persona.trait)")
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private func modelLabel(_ job: String, _ model: String) -> some View {
        HStack(spacing: 5) {
            Text(job).foregroundStyle(CoachStyle.ink2)
            Text(model).fontWeight(.semibold).foregroundStyle(CoachStyle.ink)
        }
        .font(.system(size: 14))
        .lineLimit(1)
    }
}

/// Which local model coaches and which judges, from the models on the
/// person's own server.
struct CoachModelsView: View {
    let onBack: () -> Void

    @AppStorage(CoachPreferences.coachModelKey) private var coachModel = ""
    @AppStorage(CoachPreferences.judgeModelKey) private var judgeModel = ""
    @AppStorage(CoachPreferences.readAloudKey) private var readAloud = false
    @State private var installed: [String]?
    @State private var loading = true
    @State private var comparing: String?
    @State private var comparison: [CoachModelComparison] = []
    @State private var comparedQuestion: CoachQuestion?

    var body: some View {
        let setup = CoachModels.current()
        CoachPage(eyebrow: "Cast", title: "Models") {
            HStack(spacing: 12) {
                CoachTag(
                    text: loading ? "Checking \(setup.provider.displayName)…" : installed == nil ? "\(setup.provider.displayName) isn't running" : "\(setup.provider.displayName) connected",
                    color: installed == nil ? CoachStyle.warmInk : CoachStyle.gain
                )
                Button("Back to coaches", action: onBack)
                    .buttonStyle(CoachSecondaryButtonStyle())
            }
        } content: {
            if !loading, installed == nil {
                Text("Start Ollama or LM Studio to use models. Until then, reps are scored on the counted checks and your coach uses its own lines.")
                    .font(.system(size: 15))
                    .foregroundStyle(CoachStyle.ink2)
                    .padding(20)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .coachSurface(CoachStyle.warm, border: CoachStyle.warmBorder)
            }
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 20) {
                    jobCard(title: "Coach", info: "Writes the note after each rep, in your coach's voice. Only numbers Coach counted may appear in it.", current: setup.coachModel, selection: $coachModel, allowSame: false)
                    jobCard(title: "Judge", info: "Answers one yes or no question per check, with how sure it is. A small model is enough.", current: setup.judgeModel, selection: $judgeModel, allowSame: true)
                }
                VStack(spacing: 20) {
                    jobCard(title: "Coach", info: "Writes the note after each rep, in your coach's voice.", current: setup.coachModel, selection: $coachModel, allowSame: false)
                    jobCard(title: "Judge", info: "Answers one yes or no question per check.", current: setup.judgeModel, selection: $judgeModel, allowSame: true)
                }
            }
            compareCard
            VStack(spacing: 0) {
                HStack {
                    SettingsLabel(title: "Read the note aloud", info: "Uses the Mac's own voice, on this Mac, after each rep.")
                    Spacer()
                    OrttaaiSwitch(title: "Read the note aloud", isOn: $readAloud)
                }
                .frame(minHeight: 44)
                Divider().overlay(CoachStyle.line)
                HStack {
                    SettingsLabel(title: "Hearing you", info: "Practice uses the same speech engine and Polish as your dictation.")
                    Spacer()
                    Text("Same as dictation")
                        .font(.system(size: 14))
                        .foregroundStyle(CoachStyle.ink2)
                }
                .frame(minHeight: 44)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 6)
            .coachSurface()
        }
        .task {
            loading = true
            installed = await CoachModels.installed()
            loading = false
        }
    }

    private func jobCard(title: String, info: String, current: String, selection: Binding<String>, allowSame: Bool) -> some View {
        let options = installedOptions(including: current)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(CoachStyle.ink)
                CoachInfoButton(title: title, text: info)
                Spacer()
            }
            if allowSame {
                optionRow("Same as coach", detail: nil, selected: selection.wrappedValue.isEmpty) { selection.wrappedValue = "" }
            }
            ForEach(options, id: \.self) { model in
                let chosen = allowSame ? selection.wrappedValue == model : (selection.wrappedValue.isEmpty ? model == current : selection.wrappedValue == model)
                optionRow(model, detail: detail(for: model), selected: chosen) { selection.wrappedValue = model }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .coachSurface()
    }

    private var chatModels: [String] {
        (installed ?? []).filter { !$0.lowercased().contains("embed") }
    }

    private var compareCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 6) {
                Text("Compare on my dictations")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(CoachStyle.ink)
                CoachInfoButton(
                    title: "Compare on my dictations",
                    text: "Each model judges the same 20 of your recent dictations on one question. Agreement is how often it matched the majority. Where they agree, pick the faster one. Nothing is kept."
                )
                Spacer()
                if let comparing {
                    ProgressView().controlSize(.small)
                    Text("Asking \(comparing)…")
                        .font(CoachStyle.label)
                        .foregroundStyle(CoachStyle.ink3)
                } else {
                    Button("Compare") { Task { await compare() } }
                        .buttonStyle(CoachSecondaryButtonStyle())
                        .disabled(chatModels.count < 2)
                }
            }
            if let comparedQuestion, !comparison.isEmpty {
                Text("On “\(comparedQuestion.label.lowercased())”")
                    .font(CoachStyle.label)
                    .foregroundStyle(CoachStyle.ink3)
                ForEach(comparison) { row in
                    HStack(spacing: 16) {
                        Text(row.model)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(CoachStyle.ink)
                            .lineLimit(1)
                        Spacer()
                        Text(row.agreement.map { "\(Int(($0 * 100).rounded()))% agree" } ?? "No answers")
                            .font(.system(size: 14))
                            .foregroundStyle(CoachStyle.ink2)
                        Text(row.msPerAnswer.map { "\($0) ms" } ?? "–")
                            .font(.system(size: 14))
                            .foregroundStyle(CoachStyle.ink3)
                            .frame(width: 70, alignment: .trailing)
                        Button(judgeModel == row.model ? "Judging" : "Use as judge") { judgeModel = row.model }
                            .buttonStyle(.plain)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Color.Orttaai.accent)
                            .disabled(judgeModel == row.model)
                    }
                    .frame(minHeight: 36)
                }
            } else if chatModels.count < 2 {
                Text("Needs at least two models on your server.")
                    .font(CoachStyle.label)
                    .foregroundStyle(CoachStyle.ink3)
            }
        }
        .padding(20)
        .coachSurface()
    }

    private func compare() async {
        let sample = CoachCenter.shared.comparisonSample()
        guard !sample.texts.isEmpty else { return }
        let models = Array(chatModels.prefix(4))
        comparing = models.first
        comparedQuestion = sample.question
        comparison = await CoachModelComparison.run(
            models: models,
            texts: sample.texts,
            question: sample.question,
            setup: CoachModels.current(),
            progress: { model in Task { @MainActor in comparing = model } }
        )
        comparing = nil
    }

    private func installedOptions(including current: String) -> [String] {
        let chat = (installed ?? []).filter { !$0.lowercased().contains("embed") }
        return chat.contains(current) ? chat : [current] + chat
    }

    private func detail(for model: String) -> String? {
        guard let installed else { return nil }
        return installed.contains(model) ? (model == CoachModels.insightsModel ? "Installed · also used by Insights" : "Installed") : "Not installed"
    }

    private func optionRow(_ title: String, detail: String?, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                ZStack {
                    Circle().stroke(selected ? Color.Orttaai.accent : Color.white.opacity(0.28), lineWidth: 2).frame(width: 20, height: 20)
                    if selected { Circle().fill(Color.Orttaai.accent).frame(width: 10, height: 10) }
                }
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(CoachStyle.ink)
                    .lineLimit(1)
                Spacer(minLength: 8)
                if let detail {
                    Text(detail)
                        .font(CoachStyle.label)
                        .foregroundStyle(detail == "Not installed" ? CoachStyle.warmInk : CoachStyle.ink3)
                }
            }
            .padding(.horizontal, 14)
            .frame(height: 46)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(selected ? CoachStyle.warm : Color(hex: "1D1C1F")))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(selected ? Color.Orttaai.accent.opacity(0.5) : CoachStyle.line, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
