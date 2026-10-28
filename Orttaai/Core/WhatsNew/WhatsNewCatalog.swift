// WhatsNewCatalog.swift
// Orttaai

import Foundation

/// The picture at the top of a What's New card, drawn in vectors.
nonisolated enum WhatsNewArt: Hashable, Sendable {
    /// A milestone badge with rays.
    case milestones
    /// A misheard word fixed to the right one.
    case learning
    /// The sidebar's download ring.
    case updates
    /// Any SF Symbol, in the accent rings, for a highlight without its own picture.
    case symbol(String)
}

nonisolated struct WhatsNewItem: Identifiable, Hashable, Sendable {
    let id: String
    /// Short: about four words.
    let title: String
    /// One or two sentences.
    let detail: String
    let art: WhatsNewArt
}

nonisolated struct WhatsNewRelease: Hashable, Sendable {
    let version: String
    let items: [WhatsNewItem]
}

/// What's New for each release, newest first. Every release adds an entry
/// before it ships (scripts/release_dmg.sh refuses one without it): at most
/// three highlights, the ones people will notice, in plain words. See
/// docs/whats-new.md.
nonisolated enum WhatsNewCatalog {
    static let maxItems = 3
    static let maxTitleLength = 32
    static let maxDetailLength = 140

    static let releases: [WhatsNewRelease] = [
        WhatsNewRelease(version: "1.15.2", items: [
            WhatsNewItem(
                id: "1.15.2-handsfree",
                title: "Hands-free keeps listening",
                detail: "On a quiet microphone, hands-free no longer stops while you're still talking. It now adjusts to how loud your mic is.",
                art: .symbol("waveform.and.mic")
            ),
            WhatsNewItem(
                id: "1.15.2-paste",
                title: "Quicker, steadier pasting",
                detail: "Dictations land in Codex about 0.4 s sooner, and something copied on your iPhone can no longer hold up a paste.",
                art: .symbol("doc.on.clipboard")
            ),
            WhatsNewItem(
                id: "1.15.2-lighter",
                title: "Lighter on your Mac",
                detail: "S1-mini uses about 220 MB less memory, the pill stops using the CPU once it hides, and Home and Analytics open without freezing.",
                art: .symbol("gauge.with.dots.needle.33percent")
            ),
        ]),
        WhatsNewRelease(version: "1.15.1", items: [
            WhatsNewItem(
                id: "1.15.1-devices",
                title: "Your devices, side by side",
                detail: "Analytics shows each device's words and dictations, and can show just your Mac, iPhone or iPad.",
                art: .symbol("chart.bar.xaxis")
            ),
            WhatsNewItem(
                id: "1.15.1-lists",
                title: "Numbered and lettered lists",
                detail: "Say \u{201C}letter a\u{201D} for lettered points, nested under a number. Lists end where your paragraph does, and Polish keeps them.",
                art: .symbol("list.bullet.indent")
            ),
            WhatsNewItem(
                id: "1.15.1-quit",
                title: "No crash on quit",
                detail: "Quitting or updating with Polish on no longer ends in a crash report.",
                art: .symbol("checkmark.seal")
            ),
        ]),
        WhatsNewRelease(version: "1.15.0", items: [
            WhatsNewItem(
                id: "1.15-iphone",
                title: "Your iPhone dictations here",
                detail: "With Orttakey on iPhone or iPad, what you dictate there shows up in History and counts in your stats, marked with its device.",
                art: .symbol("laptopcomputer.and.iphone")
            ),
            WhatsNewItem(
                id: "1.15-sync",
                title: "Faster, private sync",
                detail: "iCloud Sync now sends only what changed, encrypted, and updates your history in place instead of reloading all of it.",
                art: .symbol("lock.icloud")
            ),
            WhatsNewItem(
                id: "1.15-history",
                title: "Where you said it",
                detail: "History marks each dictation's device, filters by device, and shows what you actually said when it differs from the text.",
                art: .symbol("text.magnifyingglass")
            ),
        ]),
        WhatsNewRelease(version: "1.14.0", items: [
            WhatsNewItem(
                id: "1.14-formatting",
                title: "Lists and paragraphs",
                detail: "Say \u{201C}first, \u{2026} second, \u{2026}\u{201D} for a numbered list. Long dictations are split into paragraphs where you move on.",
                art: .symbol("list.number")
            ),
            WhatsNewItem(
                id: "1.14-polish",
                title: "Polish built in",
                detail: "S1-mini cleans up each dictation on your Mac, long ones included, with no server to run. Download it in Model settings.",
                art: .symbol("text.badge.checkmark")
            ),
            WhatsNewItem(
                id: "1.14-learning",
                title: "Learns in more apps",
                detail: "Learn from My Edits now reads your fixes in Claude, Slack, ChatGPT and other Electron and Chrome-based apps.",
                art: .learning
            ),
        ]),
        WhatsNewRelease(version: "1.13.0", items: [
            WhatsNewItem(
                id: "1.13-milestones",
                title: "Milestones",
                detail: "Earn 22 badges as you dictate, from your first words to a novel's worth. Share a card when you reach one.",
                art: .milestones
            ),
            WhatsNewItem(
                id: "1.13-learning",
                title: "Learns from your fixes",
                detail: "Fix a name after dictating and Orttaai suggests it for your dictionary. Memory shows each check it made.",
                art: .learning
            ),
            WhatsNewItem(
                id: "1.13-updates",
                title: "Updates you can see",
                detail: "A new version shows at the bottom left. One click downloads it, with its progress, and restarts.",
                art: .updates
            ),
        ]),
    ]

    static func release(for version: String) -> WhatsNewRelease? {
        releases.first { $0.version == version }
    }
}
