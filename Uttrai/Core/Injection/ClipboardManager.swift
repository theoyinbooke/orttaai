// ClipboardManager.swift
// Uttrai

import AppKit
import os

final class ClipboardManager {

    struct SavedItem {
        let types: [NSPasteboard.PasteboardType]
        let dataByType: [NSPasteboard.PasteboardType: Data]
    }

    func save() -> [SavedItem] {
        let pasteboard = NSPasteboard.general
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
}
