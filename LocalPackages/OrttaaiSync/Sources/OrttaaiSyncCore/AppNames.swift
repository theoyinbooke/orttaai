// AppNames.swift
// OrttaaiSync
//
// One name per app across every device. The Mac reports apps by their
// display name ("Google Chrome"), Windows and Linux by their program file
// ("chrome", "gnome-terminal"); in one archive the same app would otherwise
// show twice in Top Apps. Orttaai for Windows and Linux has the same rules
// (core/src/apps.rs); Tests/Fixtures/app-names.json keeps them in step.

import Foundation

public enum AppNames {
    public static let unknown = "Unknown App"

    /// The name to show and group by.
    public static func display(_ raw: String?) -> String {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return unknown }
        let key = matchKey(trimmed)
        if let known = aliases[key] { return known }
        // A program file's name ("obsidian", "gnome-terminal"): capitalised.
        if trimmed == trimmed.lowercased(), !trimmed.contains(" ") {
            var stem = trimmed
            if stem.hasSuffix(".exe") { stem.removeLast(4) }
            let words = stem.split(whereSeparator: { $0 == "-" || $0 == "_" || $0 == "." }).filter { !$0.isEmpty }
            if !words.isEmpty {
                return words.map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
            }
        }
        return trimmed
    }

    /// Lowercase letters and digits only, without ".exe": "Google Chrome",
    /// "googlechrome" and "Google-Chrome.exe" all match.
    static func matchKey(_ name: String) -> String {
        var lower = name.lowercased()
        if lower.hasSuffix(".exe") { lower.removeLast(4) }
        return String(lower.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(Character.init))
    }

    static let aliases: [String: String] = {
        let groups: [(String, [String])] = [
            ("Google Chrome", ["chrome", "googlechrome"]),
            ("Microsoft Edge", ["msedge", "microsoftedge"]),
            ("Firefox", ["firefox", "mozillafirefox"]),
            ("Brave Browser", ["brave", "bravebrowser"]),
            ("Arc", ["arc"]),
            ("Safari", ["safari"]),
            ("Opera", ["opera"]),
            ("Vivaldi", ["vivaldi"]),
            ("Visual Studio Code", ["code", "visualstudiocode", "vscode"]),
            ("Visual Studio Code - Insiders", ["codeinsiders", "visualstudiocodeinsiders"]),
            ("Visual Studio", ["devenv", "visualstudio"]),
            ("Cursor", ["cursor"]),
            ("Windsurf", ["windsurf"]),
            ("Zed", ["zed"]),
            ("IntelliJ IDEA", ["idea64", "idea", "intellijidea"]),
            ("PyCharm", ["pycharm64", "pycharm"]),
            ("Sublime Text", ["sublimetext"]),
            ("Slack", ["slack"]),
            ("Discord", ["discord"]),
            ("Microsoft Teams", ["teams", "msteams", "microsoftteams"]),
            ("Zoom", ["zoom", "zoomus"]),
            ("WhatsApp", ["whatsapp"]),
            ("Telegram", ["telegram", "telegramdesktop"]),
            ("Signal", ["signal"]),
            ("Microsoft Word", ["winword", "microsoftword", "word"]),
            ("Microsoft Excel", ["excel", "microsoftexcel"]),
            ("Microsoft PowerPoint", ["powerpnt", "microsoftpowerpoint", "powerpoint"]),
            ("Microsoft Outlook", ["outlook", "olk", "microsoftoutlook"]),
            ("Microsoft OneNote", ["onenote", "microsoftonenote"]),
            ("Notion", ["notion"]),
            ("Obsidian", ["obsidian"]),
            ("Claude", ["claude"]),
            ("ChatGPT", ["chatgpt"]),
            ("Windows Terminal", ["windowsterminal", "wt"]),
            ("Command Prompt", ["cmd", "commandprompt"]),
            ("PowerShell", ["powershell", "pwsh", "windowspowershell"]),
            ("File Explorer", ["explorer", "fileexplorer"]),
            ("Notepad", ["notepad"]),
            ("Sticky Notes", ["stickynotes", "microsoftstickynotes", "microsoftnotes"]),
            ("GNOME Terminal", ["gnometerminal", "gnometerminalserver"]),
            ("Thunderbird", ["thunderbird"]),
            ("iTerm", ["iterm", "iterm2"]),
        ]
        var map: [String: String] = [:]
        for (name, keys) in groups {
            for key in keys { map[key] = name }
            map[matchKey(name)] = name
        }
        return map
    }()
}
