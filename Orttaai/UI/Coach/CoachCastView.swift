// CoachCastView.swift
// Orttaai
//
// Your coaches: one for each way of talking, picked by their voice, and the
// local models that judge and write.

import CoachCore
import Combine
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
        // The card is one button to VoiceOver, so Hear is offered as an action.
        .accessibilityAction(named: "Hear a sample") { CoachVoice.shared.speak(persona.sample) }
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
    @AppStorage(CoachPreferences.partnerModelKey) private var partnerModel = ""
    @AppStorage(CoachPreferences.readAloudKey) private var readAloud = false
    @State private var installed: [String]?
    @State private var loading = true
    @State private var comparing: String?
    @State private var comparison: [CoachModelComparison] = []
    @State private var comparedQuestion: CoachQuestion?
    @ObservedObject private var center = CoachCenter.shared
    @ObservedObject private var naturalVoice = CoachNaturalVoice.shared
    /// Read so grades redraw as soon as one is saved.
    @AppStorage(CoachPreferences.judgeGradesKey) private var gradesData = Data()

    var body: some View {
        let setup = CoachModels.current()
        CoachPage(eyebrow: "Cast", title: "Models") {
            HStack(spacing: 12) {
                CoachTag(
                    text: loading ? "Checking \(setup.provider.displayName)…" : installed == nil ? "\(setup.provider.displayName) isn't running" : "\(setup.provider.displayName) connected",
                    color: installed == nil ? CoachStyle.warmInk : CoachStyle.gain
                )
                Button("Set up models") { CoachModelSetupCenter.shared.present(atSetup: true) }
                    .buttonStyle(CoachSecondaryButtonStyle())
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
            VStack(spacing: 0) {
                jobRow(
                    title: "Coach",
                    icon: "text.bubble",
                    summary: "Writes your note after each rep",
                    info: "Writes the note after each rep, in your coach's voice. Only numbers Coach counted may appear in a note.",
                    current: setup.coachModel,
                    selection: $coachModel
                )
                Divider().overlay(CoachStyle.line)
                jobRow(
                    title: "Judge",
                    icon: "checkmark.seal",
                    summary: judgeSummary(setup.judgeModel),
                    info: "Answers one yes or no question per check, with how sure it is. It's only used once it has passed the judge check.",
                    current: setup.judgeModel,
                    selection: $judgeModel
                )
                Divider().overlay(CoachStyle.line)
                jobRow(
                    title: "Scene partner",
                    icon: "bubble.left.and.bubble.right",
                    summary: "Plays the people in scenes",
                    info: "Plays the people in scenes and answers while you wait, so a quick model feels most like talking. Its reply is spoken as it's written.",
                    current: setup.sceneModel,
                    selection: $partnerModel,
                    automatic: "Same as Coach"
                )
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 6)
            .coachSurface()
            judgeCheckCard
            compareCard
            VStack(spacing: 0) {
                HStack {
                    SettingsLabel(title: "Read the note aloud", info: "Uses the Mac's own voice, on this Mac, after each rep.")
                    Spacer()
                    OrttaaiSwitch(title: "Read the note aloud", isOn: $readAloud)
                }
                .frame(minHeight: 44)
                Divider().overlay(CoachStyle.line)
                naturalVoiceRow
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
        .onReceive(CoachModelSetupCenter.shared.$presenting.dropFirst()) { showing in
            if !showing { Task { installed = await CoachModels.installed() } }
        }
    }

    /// One job: what it does, and a dropdown of the models on the server.
    private func jobRow(
        title: String,
        icon: String,
        summary: String,
        info: String,
        current: String,
        selection: Binding<String>,
        automatic: String? = nil
    ) -> some View {
        _ = gradesData
        let best = CoachPreferences.bestPassingJudge?.model
        let automaticDetail = automatic ?? (best == nil ? "No model has passed yet" : "Best that passed the judge check")
        let options = [OrttaaiDropdown<String>.Option("", "Automatic", detail: automaticDetail)]
            + installedOptions(including: current).map { model in
                let detail = detail(for: model)
                return OrttaaiDropdown<String>.Option(model, model, detail: detail, warns: detail == "Not installed" || detail?.hasPrefix("Failed") == true)
            }
        return HStack(spacing: 16) {
            Image(systemName: icon)
                .font(.system(size: 18))
                .foregroundStyle(Color.Orttaai.accent)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(CoachStyle.ink)
                    CoachInfoButton(title: title, text: info)
                }
                Text(summary)
                    .font(.system(size: 13))
                    .foregroundStyle(summary.hasPrefix("Failed") || summary.hasPrefix("Not checked") ? CoachStyle.warmInk : CoachStyle.ink3)
            }
            Spacer(minLength: 16)
            OrttaaiDropdown(
                selection: selection,
                options: options,
                width: 340,
                triggerLabel: selection.wrappedValue.isEmpty ? "Automatic · \(current)" : current,
                searchPrompt: "Search models"
            )
            .accessibilityLabel("\(title) model")
        }
        .frame(minHeight: 66)
    }

    private func judgeSummary(_ model: String) -> String {
        _ = gradesData
        guard let grade = CoachPreferences.judgeGrade(for: model) else { return "Not checked yet: run the judge check" }
        return grade.passes
            ? "Scores your reps · passed the judge check at \(Int((grade.accuracy * 100).rounded()))%"
            : "Failed the judge check, so judged checks are off"
    }

    private var chatModels: [String] {
        (installed ?? []).filter { !$0.lowercased().contains("embed") }
    }

    /// Grades each model on dictations whose answers are plain, so a judge
    /// that says the same thing to everything never gets used.
    private var judgeCheckCard: some View {
        _ = gradesData
        let grades = CoachPreferences.judgeGrades.values
            .filter(\.isCurrent)
            .sorted { ($0.passes ? 1 : 0, $0.accuracy) > ($1.passes ? 1 : 0, $1.accuracy) }
        return VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 6) {
                Text("Judge check")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(CoachStyle.ink)
                CoachInfoButton(
                    title: "Judge check",
                    text: "Each model answers \(CoachCalibration.examples.count) questions about dictations whose answer is plain: half clearly do the thing, half clearly don't. A model passes at \(Int(JudgeGrade.passAccuracy * 100))% right, and only if it gets both kinds right, so one that always says no can't pass. Only a model that passed is used as judge."
                )
                Spacer()
                if case .checking(let model, let done, let total) = center.judgeState {
                    ProgressView(value: Double(done), total: Double(max(total, 1)))
                        .frame(width: 90)
                    Text("Checking \(model) · \(done) of \(total)")
                        .font(CoachStyle.label)
                        .foregroundStyle(CoachStyle.ink3)
                } else {
                    Button(grades.isEmpty ? "Check my models" : "Check again") {
                        Task { await center.checkJudges(chatModels) }
                    }
                    .buttonStyle(CoachSecondaryButtonStyle())
                    .disabled(chatModels.isEmpty)
                }
            }
            if grades.isEmpty {
                Text(chatModels.isEmpty ? "Needs a model on your server." : "Each model takes a few seconds, longer the first time it loads.")
                    .font(CoachStyle.label)
                    .foregroundStyle(CoachStyle.ink3)
            }
            ForEach(grades, id: \.model) { grade in
                HStack(spacing: 16) {
                    Text(grade.model)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(CoachStyle.ink)
                        .lineLimit(1)
                    Spacer()
                    Text("\(Int((grade.accuracy * 100).rounded()))% right")
                        .font(.system(size: 14))
                        .foregroundStyle(CoachStyle.ink2)
                    Text(grade.msPerAnswer.map { $0 < 1_000 ? "\($0) ms" : String(format: "%.1f s", Double($0) / 1_000) } ?? "–")
                        .font(.system(size: 14))
                        .foregroundStyle(CoachStyle.ink3)
                        .frame(width: 70, alignment: .trailing)
                    CoachTag(text: grade.passes ? "Passed" : "Failed", color: grade.passes ? CoachStyle.gain : CoachStyle.warmInk)
                        .help(grade.passes ? "Right on the yes and the no examples alike." : Self.whyFailed(grade))
                    Button(judgeModel == grade.model ? "Judging" : "Use as judge") { judgeModel = grade.model }
                        .buttonStyle(.plain)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(grade.passes ? Color.Orttaai.accent : CoachStyle.muted)
                        .disabled(!grade.passes || judgeModel == grade.model)
                        .frame(width: 90, alignment: .trailing)
                }
                .frame(minHeight: 36)
                .accessibilityElement(children: .combine)
            }
        }
        .padding(20)
        .coachSurface()
    }

    /// Scene partners in natural voices of their own, once the voice model
    /// is downloaded; until then they use the Mac's own voice.
    private var naturalVoiceRow: some View {
        HStack(spacing: 12) {
            SettingsLabel(
                title: "Natural voices",
                info: "Every scene partner speaks in a natural voice of its own, made on this Mac: Ola's by Pocket TTS from Kyutai, the others' by Phonon from Gradium. The voice models download once (\(naturalVoice.downloadSize)) into your model folder; until then partners use the Mac's own voice."
            )
            Spacer()
            switch naturalVoice.state {
            case .notInstalled:
                Button("Download · \(naturalVoice.downloadSize)") { Task { await naturalVoice.install() } }
                    .buttonStyle(CoachSecondaryButtonStyle())
            case .downloading(let fraction):
                ProgressView(value: fraction)
                    .frame(width: 120)
                Text("\(Int((fraction * 100).rounded()))%")
                    .font(.system(size: 14))
                    .foregroundStyle(CoachStyle.ink2)
                    .frame(width: 44, alignment: .trailing)
            case .ready:
                Text("Ready")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(CoachStyle.gain)
                Button("Remove") { naturalVoice.remove() }
                    .buttonStyle(.plain)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(CoachStyle.ink3)
            case .failed(let message):
                Text("Didn't work")
                    .font(.system(size: 14))
                    .foregroundStyle(CoachStyle.warmInk)
                    .help(message)
                Button("Try again") { Task { await naturalVoice.install() } }
                    .buttonStyle(CoachSecondaryButtonStyle())
            }
        }
        .frame(minHeight: 52)
    }

    static func whyFailed(_ grade: JudgeGrade) -> String {
        if Double(grade.answered) < Double(grade.total) * 0.9 { return "It didn't answer often enough." }
        if grade.noRecall < JudgeGrade.passRecall { return "It said yes too often, even when the answer was plainly no." }
        if grade.yesRecall < JudgeGrade.passRecall { return "It said no too often, even when the answer was plainly yes." }
        return "It got too many wrong."
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
        guard installed.contains(model) else { return "Not installed" }
        if let grade = CoachPreferences.judgeGrade(for: model) {
            return "\(grade.passes ? "Passed" : "Failed") the judge check · \(Int((grade.accuracy * 100).rounded()))%"
        }
        return model == CoachModels.insightsModel ? "Not checked · also used by Insights" : "Not checked"
    }
}
