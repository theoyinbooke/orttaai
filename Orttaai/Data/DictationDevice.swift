// DictationDevice.swift
// Orttaai
//
// Which device each dictation was said on, worked out the same way in
// History, Analytics and Performance. Dictations from before device tagging
// carry no device: they are this Mac's, unless the archive has heard from
// another Mac that could have written them.

import Foundation
import OrttaaiSyncCore

/// The device groups History and Analytics filter by.
nonisolated enum DictationDeviceFilter: String, CaseIterable, Identifiable {
    case all
    case thisMac
    case iphone
    case ipad
    /// Linked through Orttaai Link.
    case windows
    case linux
    case android
    /// Other Macs, and dictations whose device isn't known.
    case other

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "All"
        case .thisMac: "This Mac"
        case .iphone: "iPhone"
        case .ipad: "iPad"
        case .windows: "Windows"
        case .linux: "Linux"
        case .android: "Android"
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
        guard let deviceID else {
            // Untagged and said on another kind of device: never this Mac's.
            let saidElsewhere = kind.flatMap(DeviceKind.init(rawValue:)).map { $0 != .mac && $0 != .unknown } ?? false
            return untaggedAreThisMac && !saidElsewhere
        }
        return deviceID == currentDeviceID
    }

    func isThisMac(_ record: Transcription) -> Bool {
        isThisMac(deviceID: record.sourceDeviceID, kind: record.sourceDeviceKind)
    }

    func filter(deviceID: String?, kind: String?) -> DictationDeviceFilter {
        switch kind {
        case "iphone": .iphone
        case "ipad": .ipad
        case "windows": .windows
        case "linux": .linux
        case "android": .android
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
        switch record.sourceDeviceKind.flatMap(DeviceKind.init(rawValue:)) ?? .unknown {
        case .mac: return "Another Mac"
        case let kind: return kind.displayName
        }
    }
}
