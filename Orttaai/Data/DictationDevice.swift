// DictationDevice.swift
// Orttaai
//
// Which device each dictation was said on, worked out the same way in
// History, Analytics and Performance. Dictations from before device tagging
// carry no device: they are this Mac's, unless the archive has heard from
// another Mac that could have written them.

import Foundation

/// The device groups History and Analytics filter by.
nonisolated enum DictationDeviceFilter: String, CaseIterable, Identifiable {
    case all
    case thisMac
    case iphone
    case ipad
    /// Other Macs, and dictations whose device isn't known.
    case other

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "All"
        case .thisMac: "This Mac"
        case .iphone: "iPhone"
        case .ipad: "iPad"
        case .other: "Other"
        }
    }
}

/// The devices in this archive: their names, and whose the untagged
/// dictations are.
nonisolated struct DictationDevices: Equatable {
    var currentDeviceID: String = DeviceIdentity.currentID
    /// Device records' names, by device ID.
    var names: [String: String] = [:]
    /// Whether a dictation without a device is this Mac's.
    var untaggedAreThisMac = true

    func isThisMac(deviceID: String?, kind: String?) -> Bool {
        guard let deviceID else { return untaggedAreThisMac && kind != "iphone" && kind != "ipad" }
        return deviceID == currentDeviceID
    }

    func isThisMac(_ record: Transcription) -> Bool {
        isThisMac(deviceID: record.sourceDeviceID, kind: record.sourceDeviceKind)
    }

    func filter(deviceID: String?, kind: String?) -> DictationDeviceFilter {
        switch kind {
        case "iphone": .iphone
        case "ipad": .ipad
        default: isThisMac(deviceID: deviceID, kind: kind) ? .thisMac : .other
        }
    }

    func filter(for record: Transcription) -> DictationDeviceFilter {
        filter(deviceID: record.sourceDeviceID, kind: record.sourceDeviceKind)
    }

    /// One key per device, for grouping: untagged dictations share this
    /// Mac's key when they're its own.
    func key(for record: Transcription) -> String {
        isThisMac(record) ? currentDeviceID : (record.sourceDeviceID ?? "unknown")
    }

    /// "mac", "iphone", "ipad" or "unknown", for the device's symbol.
    func kindName(for record: Transcription) -> String? {
        isThisMac(record) ? "mac" : record.sourceDeviceKind
    }

    func name(for record: Transcription) -> String {
        if isThisMac(record) { return "This Mac" }
        if let id = record.sourceDeviceID, let name = names[id] { return name }
        switch record.sourceDeviceKind {
        case "iphone": return "iPhone"
        case "ipad": return "iPad"
        case "mac": return "Another Mac"
        default: return "Unknown device"
        }
    }
}
