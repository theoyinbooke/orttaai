// ClipboardManager.swift
// Orttaai

import AppKit
import os

/// Testable seam over pasteboard save/set/restore so injection tests can
/// assert clipboard semantics without touching the real system pasteboard.
protocol ClipboardManaging: AnyObject {
    /// The pasteboard's contents to restore later, or nil when reading them
    /// took longer than `giveUpAfterMs` (see `ClipboardManager.saveLimitMs`).
    func save(giveUpAfterMs: Int) async -> [ClipboardManager.SavedItem]?
    func restore(_ savedItems: [ClipboardManager.SavedItem])
    func setString(_ string: String)
    /// Current plain-string contents, nil when the pasteboard holds none.
    func getString() -> String?
    /// Pasteboard change counter — bumps whenever any app writes to it, so a
    /// synthetic Cmd+C landing can be detected without polling contents.
    var changeCount: Int { get }
}

final class ClipboardManager: ClipboardManaging {

    nonisolated struct SavedItem: Sendable {
        let types: [NSPasteboard.PasteboardType]
        let dataByType: [NSPasteboard.PasteboardType: Data]
    }

    /// How long saving the pasteboard before a paste or a copy may take.
    /// Some data is only fetched when asked for: an item copied on an iPhone
    /// or iPad comes over the air through Universal Clipboard, and when the
    /// device doesn't answer macOS gives up only after 20 s, which held a
    /// paste for 22 s. Data from apps on this Mac arrives well within this.
    nonisolated static let saveLimitMs = 1_000

    private let readItems: @Sendable () -> [SavedItem]

    /// - Parameter readItems: reads the pasteboard's contents; tests pass a
    ///   slow one.
    init(readItems: @escaping @Sendable () -> [SavedItem] = { ClipboardManager.readItems(from: .general) }) {
        self.readItems = readItems
    }

    func save() -> [SavedItem] {
        readItems()
    }

    /// Reads the pasteboard away from the main thread, giving up after
    /// `limitMs`. A read given up on finishes in the background and is
    /// dropped: new contents can be staged meanwhile, and they make the late
    /// read come back empty.
    func save(giveUpAfterMs limitMs: Int) async -> [SavedItem]? {
        let readItems = self.readItems
        return await withCheckedContinuation { continuation in
            let answered = OSAllocatedUnfairLock(initialState: false)
            let answer: @Sendable ([SavedItem]?) -> Void = { items in
                let isFirst = answered.withLock { done in
                    defer { done = true }
                    return !done
                }
                if isFirst {
                    continuation.resume(returning: items)
                }
            }
            DispatchQueue.global(qos: .userInitiated).async {
                answer(readItems())
            }
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + .milliseconds(limitMs)) {
                answer(nil)
            }
        }
    }

    nonisolated static func readItems(from pasteboard: NSPasteboard) -> [SavedItem] {
        guard let items = pasteboard.pasteboardItems else { return [] }

        return items.compactMap { item -> SavedItem? in
            var dataByType: [NSPasteboard.PasteboardType: Data] = [:]
            let types = item.types.filter { !$0.rawValue.contains("promise") }

            for type in types {
                if let data = item.data(forType: type) {
                    dataByType[type] = data
                }
            }

            guard !dataByType.isEmpty else { return nil }
            return SavedItem(types: types, dataByType: dataByType)
        }
    }

    func restore(_ savedItems: [SavedItem]) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()

        guard !savedItems.isEmpty else { return }

        let pasteboardItems = savedItems.map { savedItem -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in savedItem.dataByType {
                item.setData(data, forType: type)
            }
            return item
        }

        pasteboard.writeObjects(pasteboardItems)
        Logger.injection.info("Clipboard restored with \(savedItems.count) item(s)")
    }

    func setString(_ string: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(string, forType: .string)
    }

    func getString() -> String? {
        NSPasteboard.general.string(forType: .string)
    }

    var changeCount: Int {
        NSPasteboard.general.changeCount
    }
}
