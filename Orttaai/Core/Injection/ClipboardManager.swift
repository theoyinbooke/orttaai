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
    /// True when the copy now on the pasteboard came from a code editor
    /// with nothing selected (VS Code and its forks copy the whole line).
    func copiedFromEmptySelection() -> Bool
    /// Pasteboard change counter — bumps whenever any app writes to it, so a
    /// synthetic Cmd+C landing can be detected without polling contents.
    var changeCount: Int { get }
}

extension ClipboardManaging {
    func copiedFromEmptySelection() -> Bool { false }
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

    private let pasteboard: NSPasteboard
    private let readItems: @Sendable () -> [SavedItem]

    /// - Parameters:
    ///   - pasteboard: the pasteboard to manage. Tests pass a private one, so
    ///     running them never touches the system clipboard.
    ///   - readItems: reads the pasteboard's contents, all of `pasteboard`'s
    ///     items unless given; tests pass a slow one.
    init(pasteboard: NSPasteboard = .general, readItems: (@Sendable () -> [SavedItem])? = nil) {
        self.pasteboard = pasteboard
        // Read off the main thread by `save(giveUpAfterMs:)`, which a
        // pasteboard allows even while this thread writes to it.
        nonisolated(unsafe) let pasteboardToRead = pasteboard
        self.readItems = readItems ?? { ClipboardManager.readItems(from: pasteboardToRead) }
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
        pasteboard.clearContents()
        pasteboard.setString(string, forType: .string)
    }

    func getString() -> String? {
        pasteboard.string(forType: .string)
    }

    func copiedFromEmptySelection() -> Bool {
        guard let item = pasteboard.pasteboardItems?.first else { return false }
        return item.types.contains { type in
            guard type != .string, let data = item.data(forType: type) else { return false }
            return Self.marksEmptySelection(data)
        }
    }

    /// VS Code (and Cursor, Windsurf, VSCodium) tags its copies with JSON
    /// metadata, `"isFromEmptySelection":true` when the line was copied
    /// because nothing was selected. macOS won't take "vscode-editor-data"
    /// as a pasteboard type, so Chromium packs it into its own custom-data
    /// type as UTF-16. The bytes are searched directly, in UTF-8 and UTF-16,
    /// since the rest of that format isn't text.
    nonisolated static func marksEmptySelection(_ data: Data) -> Bool {
        guard data.count <= 256_000 else { return false }
        let marker = "\"isFromEmptySelection\":true"
        if data.range(of: Data(marker.utf8)) != nil { return true }
        if let utf16 = marker.data(using: .utf16LittleEndian), data.range(of: utf16) != nil { return true }
        return false
    }

    var changeCount: Int {
        pasteboard.changeCount
    }
}
