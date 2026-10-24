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
