// Extensions.swift
// Uttrai

import AppKit

extension NSWorkspace {
    var frontmostAppName: String {
        frontmostApplication?.localizedName ?? "Unknown App"
    }
}

extension Bundle {
    var isHomebrewInstall: Bool {
        url(forResource: ".homebrew-installed", withExtension: nil) != nil
    }
}
