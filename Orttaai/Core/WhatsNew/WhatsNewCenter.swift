// WhatsNewCenter.swift
// Orttaai

import Combine
import Foundation

/// Decides when What's New shows: once, the first time an updated Orttaai
/// opens its window. A fresh install starts with none; setup comes first.
/// The version counts as seen only when the card is closed, so quitting
/// before it shows keeps it for next time.
@MainActor
final class WhatsNewCenter: ObservableObject {
    static let shared = WhatsNewCenter()
    static let lastSeenVersionKey = "whatsNewLastSeenVersion"

    @Published private(set) var release: WhatsNewRelease?

    private let defaults: UserDefaults
    private let catalog: [WhatsNewRelease]

    init(defaults: UserDefaults = .standard, catalog: [WhatsNewRelease] = WhatsNewCatalog.releases) {
        self.defaults = defaults
        self.catalog = catalog
    }

    /// At launch. `isExistingUser` is whether setup was already done, which
    /// tells an update from a first install when no version was recorded
    /// (every version before What's New).
    func evaluate(currentVersion: String, isExistingUser: Bool) {
        let lastSeen = defaults.string(forKey: Self.lastSeenVersionKey)
        guard lastSeen != currentVersion else { return }
        let updated: Bool
        if let lastSeen {
            updated = currentVersion.compare(lastSeen, options: .numeric) == .orderedDescending
        } else {
            updated = isExistingUser
        }
        guard updated, let notes = catalog.first(where: { $0.version == currentVersion }), !notes.items.isEmpty else {
            defaults.set(currentVersion, forKey: Self.lastSeenVersionKey)
            return
        }
        release = notes
    }

    func dismiss() {
        if let release {
            defaults.set(release.version, forKey: Self.lastSeenVersionKey)
        }
        release = nil
    }

    #if DEBUG
    /// `-OrttaaiWhatsNewPreview YES` on a Debug build shows the newest notes.
    func preview() {
        release = catalog.first
    }
    #endif
}
