// WorkActivity.swift
// Orttaai

import Foundation

/// The kind of work a dictation session was doing.
nonisolated enum WorkActivity: String, Codable, Sendable, CaseIterable {
    case building
    case fixing
    case designing
    case planning
    case researching
    case writing
    case communicating
    case setup
    case reviewing
    case other

    var title: String {
        switch self {
        case .building: return "Building features"
        case .fixing: return "Fixing problems"
        case .designing: return "Designing the interface"
        case .planning: return "Planning and deciding"
        case .researching: return "Researching and learning"
        case .writing: return "Writing and content"
        case .communicating: return "Communicating"
        case .setup: return "Setup and tooling"
        case .reviewing: return "Reviewing and testing"
        case .other: return "Other"
        }
    }

    /// Lowercase phrase for sentences ("most of it was fixing problems").
    var phrase: String { title.prefix(1).lowercased() + title.dropFirst() }

    var symbol: String {
        switch self {
        case .building: return "hammer"
        case .fixing: return "wrench.adjustable"
        case .designing: return "paintbrush.pointed"
        case .planning: return "map"
        case .researching: return "magnifyingglass"
        case .writing: return "text.quote"
        case .communicating: return "bubble.left.and.bubble.right"
        case .setup: return "gearshape.2"
        case .reviewing: return "checkmark.seal"
        case .other: return "circle.dotted"
        }
    }
}

/// What got in the way during a session.
nonisolated enum FrictionType: String, Codable, Sendable, CaseIterable {
    case bugs
    case layout
    case performance
    case tooling
    case aiQuality = "ai_quality"
    case integration
    case direction
    case other

    var title: String {
        switch self {
        case .bugs: return "Bugs and errors"
        case .layout: return "UI and layout"
        case .performance: return "Speed and performance"
        case .tooling: return "Tools and setup"
        case .aiQuality: return "AI output quality"
        case .integration: return "Integrations and APIs"
        case .direction: return "Unclear direction"
        case .other: return "Other"
        }
    }
}

/// What one working session was about. Produced by a local model when one is
/// available, otherwise estimated on-device from wording.
nonisolated struct SessionAnalysis: Codable, Hashable, Sendable {
    var activity: WorkActivity
    var subject: String?
    var goal: String?
    var friction: String?
    var frictionType: FrictionType?
    var decision: String?
    var openQuestion: String?
    /// Model name, or nil for the on-device estimate.
    var model: String?

    var isEstimate: Bool { model == nil }
}

/// Consecutive dictations in one app, close together in time: one piece of
/// work. The unit everything in the activity view is counted in.
nonisolated struct WorkSession: Identifiable, Sendable {
    /// Stable while the session is unchanged; changes when it grows, so a
    /// cached analysis is redone for the session that is still going.
    let key: String
    let dictationIDs: [Int64]
    let start: Date
    let end: Date
    let appName: String?
    let text: String
    let conceptKeys: [String]

    var id: String { key }
}

nonisolated enum WorkSessionBuilder {
    static let gap: TimeInterval = 30 * 60
    /// Enough context for a small model; long sessions keep their start
    /// and end, where goals and conclusions tend to be.
    static let maxTextLength = 3_600

    static func sessions(
        sources: [ConceptSource],
        conceptsByDictation: [Int64: [ExtractedConcept]] = [:]
    ) -> [WorkSession] {
        var groups: [[ConceptSource]] = []
        var openGroupByApp: [String: (index: Int, last: Date)] = [:]
        for source in sources.sorted(by: { $0.createdAt < $1.createdAt }) {
            let app = source.targetAppName ?? ""
            if let open = openGroupByApp[app], source.createdAt.timeIntervalSince(open.last) <= gap {
                groups[open.index].append(source)
                openGroupByApp[app] = (open.index, source.createdAt)
            } else {
                groups.append([source])
                openGroupByApp[app] = (groups.count - 1, source.createdAt)
            }
        }

        return groups.map { group in
            let ids = group.map(\.id)
            var seen = Set<String>()
            let keys = group.flatMap { conceptsByDictation[$0.id] ?? [] }
                .filter { $0.kind != .topic || $0.key.contains(" ") }
                .map(\.key)
                .filter { seen.insert($0).inserted }
            return WorkSession(
                key: "\(ids.first!)-\(ids.count)-\(group.reduce(0) { $0 + $1.text.count })",
                dictationIDs: ids,
                start: group.first!.createdAt,
                end: group.last!.createdAt,
                appName: group.first!.targetAppName,
                text: condensed(group.map(\.text)),
                conceptKeys: keys
            )
        }
    }

    static func condensed(_ texts: [String]) -> String {
        let joined = texts
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
        guard joined.count > maxTextLength else { return joined }
        let head = joined.prefix(maxTextLength * 2 / 3)
        let tail = joined.suffix(maxTextLength / 3)
        return "\(head)\n\n[…]\n\n\(tail)"
    }
}

// MARK: - On-device estimate

/// A fast, wording-based estimate used until (or instead of) a local model.
/// Conservative on purpose: it reports friction, decisions, and questions
/// only when the words say so.
nonisolated enum SessionHeuristics {
    static func analyze(_ session: WorkSession) -> SessionAnalysis {
        let lowered = session.text.lowercased()
        var scores: [WorkActivity: Double] = [:]
        for (activity, cues) in activityCues {
            scores[activity] = cues.reduce(0) { $0 + Double(occurrences(of: $1, in: lowered)) }
        }
        let activity = scores
            .filter { $0.value > 0 }
            .max { $0.value == $1.value ? $0.key.rawValue > $1.key.rawValue : $0.value < $1.value }?
            .key ?? .other

        let sentences = sentences(in: session.text)
        let frictionSentence = sentences.first { sentence in
            let lower = sentence.lowercased()
            return frictionCues.contains(where: lower.contains)
        }
        let frictionType = frictionSentence.map { sentence -> FrictionType in
            let lower = sentence.lowercased()
            return frictionTypeCues.first { _, cues in cues.contains(where: lower.contains) }?.key ?? .bugs
        }
        let decision = sentences.first { sentence in
            let lower = sentence.lowercased()
            return decisionCues.contains(where: lower.contains)
        }
        let question = sentences.last { $0.hasSuffix("?") && $0.count > 20 }

        return SessionAnalysis(
            activity: activity,
            subject: nil,
            goal: nil,
            friction: frictionSentence.map { clipped($0) },
            frictionType: frictionType,
            decision: decision.map { clipped($0) },
            openQuestion: question.map { clipped($0) },
            model: nil
        )
    }

    private static let activityCues: [WorkActivity: [String]] = [
        .fixing: ["bug", "error", "crash", "broken", "not working", "doesn't work", "does not work", "fix", "issue", "wrong", "failing", "fails", "stuck"],
        .designing: ["layout", "design", "color", "spacing", "padding", "font", "icon", "align", "button", "screen", "look", "ui", "compact", "card"],
        .building: ["add ", "implement", "build", "create", "feature", "integrate", "support for", "new page", "port"],
        .planning: ["plan", "strategy", "priorit", "roadmap", "should we", "decide", "approach", "next step", "goal"],
        .researching: ["how does", "what is", "explain", "research", "learn", "understand", "compare", "difference between", "look up"],
        .writing: ["write", "post", "caption", "script", "blog", "article", "email", "tweet", "newsletter", "copy"],
        .communicating: ["tell him", "tell her", "reply", "message", "let them know", "meeting", "call with"],
        .setup: ["install", "configure", "setup", "set up", "deploy", "account", "domain", "sign in", "permission", "dns"],
        .reviewing: ["test", "verify", "check", "review", "confirm", "screenshot", "try it", "works now"]
    ]

    /// Only unambiguous complaints; words like "still" or "can't" are as
    /// common in instructions as in frustration.
    private static let frictionCues = [
        "not working", "doesn't work", "does not work", "isn't working", "is not working",
        "still not", "still doesn't", "still broken", "broken", "error", "crash", "failed",
        "fails", "stuck", "bug", "not showing", "doesn't show", "not loading", "frustrat",
        "annoying", "keeps breaking", "keeps failing", "went wrong", "is wrong"
    ]

    private static let frictionTypeCues: [(key: FrictionType, value: [String])] = [
        (.layout, ["layout", "align", "spacing", "padding", "overlap", "too big", "too small", "cut off", "ui", "look"]),
        (.performance, ["slow", "lag", "fast", "performance", "freeze", "hang", "memory", "cpu"]),
        (.tooling, ["install", "build", "xcode", "config", "setup", "deploy", "sign", "permission", "terminal"]),
        (.aiQuality, ["model", "hallucinat", "ai ", "agent", "prompt", "response", "output", "chatgpt", "claude", "codex"]),
        (.integration, ["api", "endpoint", "integration", "sync", "server", "webhook", "auth"]),
        (.direction, ["not sure", "confus", "unclear", "don't know", "which one"])
    ]

    private static let decisionCues = [
        "let's go with", "we'll go with", "we are going with", "we're going with", "decided",
        "i've decided", "going forward", "from now on", "the plan is", "let's stick with"
    ]

    private static func occurrences(of cue: String, in text: String) -> Int {
        text.components(separatedBy: cue).count - 1
    }

    static func sentences(in text: String) -> [String] {
        var result: [String] = []
        text.enumerateSubstrings(in: text.startIndex..<text.endIndex, options: .bySentences) { sentence, _, _, _ in
            if let sentence = sentence?.trimmingCharacters(in: .whitespacesAndNewlines), !sentence.isEmpty {
                result.append(sentence)
            }
        }
        return result
    }

    static func clipped(_ text: String, limit: Int = 140) -> String {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleaned.count > limit else { return cleaned }
        return String(cleaned.prefix(limit - 1)).trimmingCharacters(in: .whitespaces) + "…"
    }
}

// MARK: - Local model

nonisolated enum SessionModelAnalyzer {
    static let promptVersion = 2

    static func prompt(for session: WorkSession) -> String {
        """
        Below is one working session of a person's voice dictation, spoken while they were in \(session.appName ?? "an app"). Describe what was going on in it.

        Return JSON with:
        - activity: the main kind of work. building = adding or extending features; fixing = something is broken or wrong and they want it repaired; designing = how things look or are laid out; planning = strategy, priorities, deciding what to do next; researching = learning or asking how something works; writing = content, posts, emails, docs; communicating = messages to other people; setup = installing, configuring, deploying, accounts; reviewing = testing or checking results; other.
        - subject: the project or thing it was about, 1 to 4 words, using its real name when one is said.
        - goal: what they were trying to get done, specific, under 12 words.
        - friction: a problem that actually got in their way: something failed, broke, errored, behaved wrongly, was slow, or blocked them. A change they simply want is NOT friction. Under 12 words, or null.
        - friction_type (null when friction is null): bugs = errors, crashes, broken behavior; layout = something displays wrongly (misaligned, cut off, overlapping, cluttered); performance = slow, lagging, heavy; tooling = build, install, signing, developer tools; ai_quality = an AI assistant or model gave poor or wrong output; integration = an API, sync, service, or account misbehaved; direction = they said they were confused or unsure what to do; other.
        - decision: a choice they clearly made ("let's use X", "we'll drop Y"), under 12 words, or null.
        - open_question: a question they asked that is still open, written as a question, under 14 words, or null.

        Session:
        \(session.text)
        """
    }

    static let schemaJSON = """
    {"type":"object","properties":{
    "activity":{"type":"string","enum":["building","fixing","designing","planning","researching","writing","communicating","setup","reviewing","other"]},
    "subject":{"type":"string"},
    "goal":{"type":"string"},
    "friction":{"type":["string","null"]},
    "friction_type":{"type":["string","null"],"enum":["bugs","layout","performance","tooling","ai_quality","integration","direction","other",null]},
    "decision":{"type":["string","null"]},
    "open_question":{"type":["string","null"]}},
    "required":["activity","subject","goal","friction","friction_type","decision","open_question"]}
    """

    private struct Payload: Decodable {
        let activity: String
        let subject: String?
        let goal: String?
        let friction: String?
        let friction_type: String?
        let decision: String?
        let open_question: String?
    }

    static func decode(_ response: String, model: String) -> SessionAnalysis? {
        guard let start = response.firstIndex(of: "{"), let end = response.lastIndex(of: "}") else { return nil }
        let json = String(response[start...end])
        guard let payload = try? JSONDecoder().decode(Payload.self, from: Data(json.utf8)) else { return nil }
        func clean(_ value: String?) -> String? {
            guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "."))),
                  !value.isEmpty, value.lowercased() != "null", value.lowercased() != "none" else { return nil }
            return SessionHeuristics.clipped(value, limit: 120)
        }
        let friction = clean(payload.friction)
        return SessionAnalysis(
            activity: WorkActivity(rawValue: payload.activity) ?? .other,
            subject: clean(payload.subject),
            goal: clean(payload.goal),
            friction: friction,
            frictionType: friction == nil ? nil : (payload.friction_type.flatMap(FrictionType.init(rawValue:)) ?? .other),
            decision: clean(payload.decision),
            openQuestion: clean(payload.open_question),
            model: model
        )
    }
}
