// Extensions.swift
// Orttaai

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

    /// The version people see, such as 1.12.0.
    var shortVersion: String {
        infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }
}
