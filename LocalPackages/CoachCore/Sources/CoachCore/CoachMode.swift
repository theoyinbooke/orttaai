// CoachMode.swift
// CoachCore
//
// The way someone was talking, from the app they dictated into: to an AI
// agent, to people, or thinking on the page.

import Foundation

public enum CoachMode: String, CaseIterable, Codable, Sendable, Identifiable {
    case ai
    case people
    case writing
    /// Browsers, unknown apps and Orttakey, which never learns the app.
    case elsewhere

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .ai: return "Talking to AI"
        case .people: return "Talking to people"
        case .writing: return "Thinking and writing"
        case .elsewhere: return "Elsewhere"
        }
    }

    public var shortTitle: String {
        switch self {
        case .ai: return "AI"
        case .people: return "People"
        case .writing: return "Writing"
        case .elsewhere: return "Elsewhere"
        }
    }

    /// The modes that get a voice shape.
    public static let shaped: [CoachMode] = [.ai, .people, .writing]
}

/// What the person chose for an app.
public enum CoachAppRule: String, Codable, Sendable, CaseIterable {
    case ai
    case people
    case writing
    case elsewhere
    /// Coach never reads it.
    case off

    public var mode: CoachMode? { CoachMode(rawValue: rawValue) }
}

public enum CoachAppCatalog {
    /// Lowercased bundle identifiers.
    static let byBundleID: [String: CoachMode] = [
        // Agents and the editors and terminals they run in.
        "com.anthropic.claudefordesktop": .ai,
        "com.openai.codex": .ai,
        "com.openai.chat": .ai,
        "com.todesktop.230313mzl4w4u92": .ai, // Cursor
        "com.exafunction.windsurf": .ai,
        "com.microsoft.vscode": .ai,
        "com.microsoft.vscodeinsiders": .ai,
        "com.vscodium": .ai,
        "dev.zed.zed": .ai,
        "com.apple.terminal": .ai,
        "com.googlecode.iterm2": .ai,
        "com.mitchellh.ghostty": .ai,
        "dev.warp.warp-stable": .ai,
        "com.github.wez.wezterm": .ai,
        "net.kovidgoyal.kitty": .ai,
        "com.cmuxterm.app": .ai,
        "com.t3tools.t3code": .ai,
        "com.google.antigravity": .ai,
        "ai.opencode.desktop": .ai,
        "com.orttaai.orttaai": .ai, // Orttaai's own Chat AI
        // People.
        "com.tinyspeck.slackmacgap": .people,
        "com.apple.mail": .people,
        "com.apple.mobilesms": .people,
        "net.whatsapp.whatsapp": .people,
        "desktop.whatsapp": .people,
        "ru.keepcoder.telegram": .people,
        "com.tdesktop.telegram": .people,
        "com.hnc.discord": .people,
        "com.microsoft.teams2": .people,
        "com.microsoft.teams": .people,
        "com.microsoft.outlook": .people,
        "com.readdle.smartemail-mac": .people,
        "com.superhuman.electron": .people,
        "com.facebook.archon": .people,
        // Thinking on the page.
        "com.apple.notes": .writing,
        "com.apple.iwork.pages": .writing,
        "md.obsidian": .writing,
        "com.microsoft.word": .writing,
        "notion.id": .writing,
        "net.shinyfrog.bear": .writing,
        "com.apple.textedit": .writing,
        "com.ulyssesapp.mac": .writing,
        "com.lukilabs.lukiapp": .writing, // Craft
    ]

    /// Lowercased app names, for rows that only kept the name.
    static let byName: [String: CoachMode] = [
        "claude": .ai, "codex": .ai, "chatgpt": .ai, "cursor": .ai, "windsurf": .ai,
        "visual studio code": .ai, "code": .ai, "zed": .ai, "terminal": .ai, "iterm2": .ai,
        "iterm": .ai, "ghostty": .ai, "warp": .ai, "wezterm": .ai, "kitty": .ai,
        "cmux": .ai, "t3 code": .ai, "t3 code (beta)": .ai, "antigravity": .ai, "opencode": .ai,
        "devin": .ai, "orttaai": .ai,
        "slack": .people, "mail": .people, "messages": .people, "whatsapp": .people,
        "telegram": .people, "discord": .people, "microsoft teams": .people, "teams": .people,
        "microsoft outlook": .people, "outlook": .people, "spark": .people, "superhuman": .people,
        "messenger": .people,
        "notes": .writing, "pages": .writing, "obsidian": .writing, "microsoft word": .writing,
        "word": .writing, "notion": .writing, "bear": .writing, "textedit": .writing,
        "ulysses": .writing, "craft": .writing,
    ]

    /// The key a person's choice for an app is kept under.
    public static func key(bundleID: String?, appName: String?) -> String? {
        if let id = bundleID?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !id.isEmpty { return id }
        if let name = appName?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !name.isEmpty { return "name:" + name }
        return nil
    }

    public static func builtInMode(bundleID: String?, appName: String?) -> CoachMode {
        if let id = bundleID?.lowercased(), let mode = byBundleID[id] { return mode }
        if let name = appName?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), let mode = byName[name] { return mode }
        return .elsewhere
    }

    /// The mode Coach files a dictation under, or nil when its app is off.
    public static func mode(bundleID: String?, appName: String?, overrides: [String: CoachAppRule]) -> CoachMode? {
        if let key = key(bundleID: bundleID, appName: appName), let rule = overrides[key] {
            return rule.mode
        }
        return builtInMode(bundleID: bundleID, appName: appName)
    }
}
