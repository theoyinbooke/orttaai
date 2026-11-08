// LinkAPI.swift
// OrttaaiLink
//
// The JSON bodies of docs/orttaai-link-protocol.md. Linked devices write the
// same shapes in Rust and Kotlin.

import Foundation
import OrttaaiSyncCore

public enum LinkProtocol {
    public static let version = 1
    public static let defaultPort = 47821
    public static let bonjourType = "_orttaai._tcp"
    /// Records per push and per page of changes.
    public static let maximumBatch = 500
    /// The longest a request for changes is held open, in seconds.
    public static let maximumWait = 25
    /// The biggest request body accepted.
    public static let maximumBodyBytes = 8 * 1024 * 1024
}

/// A device introducing itself while linking.
public struct LinkDeviceInfo: Codable, Sendable, Hashable {
    public var deviceID: String
    public var kind: DeviceKind
    public var name: String
    public var model: String?
    public var app: String
    public var appVersion: String?
    public var osVersion: String?

    public init(deviceID: String, kind: DeviceKind, name: String, model: String? = nil, app: String, appVersion: String? = nil, osVersion: String? = nil) {
        self.deviceID = deviceID
        self.kind = kind
        self.name = name
        self.model = model
        self.app = app
        self.appVersion = appVersion
        self.osVersion = osVersion
    }
}

public struct PairRequest: Codable, Sendable {
    public var secret: String?
    public var code: String?
    public var device: LinkDeviceInfo

    public init(secret: String? = nil, code: String? = nil, device: LinkDeviceInfo) {
        self.secret = secret
        self.code = code
        self.device = device
    }
}

public struct PairResponse: Codable, Sendable, Equatable {
    public var token: String
    public var macDeviceID: String
    public var name: String
    public var tailscaleName: String?
    public var `protocol`: Int
}

public struct PushRequest: Codable, Sendable {
    public var records: [LinkRecord]

    public init(records: [LinkRecord]) {
        self.records = records
    }
}

public struct PushResponse: Codable, Sendable, Equatable {
    public struct Accepted: Codable, Sendable, Equatable {
        public var recordName: String
        public var revision: LinkRecord.WireRevision
    }

    public struct Rejected: Codable, Sendable, Equatable {
        public var recordName: String
        public var problem: String
    }

    public var accepted: [Accepted]
    /// The Mac already had a newer version: here it is.
    public var newer: [LinkRecord]
    public var rejected: [Rejected]

    public init(accepted: [Accepted] = [], newer: [LinkRecord] = [], rejected: [Rejected] = []) {
        self.accepted = accepted
        self.newer = newer
        self.rejected = rejected
    }
}

public struct ChangesResponse: Codable, Sendable, Equatable {
    public var records: [LinkRecord]
    public var cursor: String
    public var more: Bool
}

/// How the Mac's iCloud sync stands, for the device's Devices page.
public struct ICloudStatus: Codable, Sendable, Equatable {
    public enum State: String, Codable, Sendable {
        case syncing
        case paused
        case signedOut
        case off
    }

    public var state: State
    /// Milliseconds since 1970.
    public var lastSentAt: Int64?

    public init(state: State, lastSentAt: Date? = nil) {
        self.state = state
        self.lastSentAt = lastSentAt.map { Int64(($0.timeIntervalSince1970 * 1000).rounded()) }
    }
}

public struct StatusResponse: Codable, Sendable, Equatable {
    public var name: String
    public var macDeviceID: String
    public var version: String
    public var `protocol`: Int
    public var iCloud: ICloudStatus
    public var tailscaleName: String?
}

public struct LinkErrorBody: Codable, Sendable, Equatable {
    public struct Detail: Codable, Sendable, Equatable {
        public var code: String
        public var message: String
    }

    public var error: Detail
}
