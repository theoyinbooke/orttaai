// Linking.swift
// OrttaaiLink
//
// Linking a device (docs/orttaai-link-protocol.md §4): a short-lived session
// with a secret for the QR code and a 6-digit code to type, and the list of
// linked devices with a key each. From My Local AI Link's pairing.

import Crypto
import Foundation
import OrttaaiSyncCore

/// An open invitation to link: a secret for the QR code and a 6-digit code.
/// Both are single use and expire with the session.
public struct LinkingSession: Sendable, Equatable {
    public var secret: String
    public var code: String
    public var expires: Date
    var wrongCodes = 0

    public static let lifetime: TimeInterval = 5 * 60
    public static let allowedWrongCodes = 5
}

public enum LinkingRefusal: Error, Equatable, Sendable {
    /// No Link window open (or it expired).
    case closed
    /// The secret or code didn't match.
    case wrong
    /// Too many wrong codes; the session closed.
    case tooManyTries
}

/// Opens and redeems linking sessions, one at a time.
public actor LinkingDesk {
    public private(set) var session: LinkingSession?
    private let now: @Sendable () -> Date

    public init(now: @escaping @Sendable () -> Date = { .now }) {
        self.now = now
    }

    @discardableResult
    public func open() -> LinkingSession {
        let opened = LinkingSession(
            secret: Self.randomToken(),
            code: String(format: "%06d", Int.random(in: 0...999_999)),
            expires: now().addingTimeInterval(LinkingSession.lifetime)
        )
        session = opened
        return opened
    }

    public func close() { session = nil }

    public var isOpen: Bool {
        guard let session else { return false }
        return session.expires > now()
    }

    /// Checks a secret (from the QR code) or a code (typed); on success the
    /// session closes.
    public func redeem(secret: String?, code: String?) throws(LinkingRefusal) {
        guard var current = session, current.expires > now() else {
            session = nil
            throw .closed
        }
        if let secret, Self.constantTimeEqual(secret, current.secret) {
            session = nil
            return
        }
        if let code {
            if Self.constantTimeEqual(code.filter(\.isNumber), current.code) {
                session = nil
                return
            }
            current.wrongCodes += 1
            if current.wrongCodes >= LinkingSession.allowedWrongCodes {
                session = nil
                throw .tooManyTries
            }
            session = current
        }
        throw .wrong
    }

    /// 32 random bytes, base64url without padding.
    public static func randomToken() -> String {
        var generator = SystemRandomNumberGenerator()
        let bytes = (0..<32).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func constantTimeEqual(_ a: String, _ b: String) -> Bool {
        let left = Array(a.utf8), right = Array(b.utf8)
        guard left.count == right.count else { return false }
        return zip(left, right).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
}

/// A device linked to this Mac.
public struct LinkedDevice: Codable, Sendable, Identifiable, Hashable {
    /// The device's own sync ID, so linking again replaces its key.
    public var id: String
    public var kind: DeviceKind
    public var name: String
    public var model: String?
    public var app: String
    public var appVersion: String?
    public var osVersion: String?
    public var linkedAt: Date
    /// The last request of any kind.
    public var lastSeen: Date?
    /// The last time it sent changes, and the last time it caught up.
    public var lastPushAt: Date?
    public var lastPullAt: Date?
    /// Its last request came over Tailscale rather than the home network.
    public var viaTailnet: Bool
    /// SHA-256 (hex) of its key; the key itself is never stored.
    var tokenHash: String

    public var syncPlatform: SyncPlatform { kind.syncPlatform }
    public var dictationZone: SyncZone { .dictations(originDeviceID: id) }
}

/// What a device does, for its row on the Devices page.
public enum LinkActivity: Sendable {
    case push
    case pull
    case other
}

/// The linked devices, kept as JSON beside Link's identity.
public actor LinkedDeviceStore {
    public private(set) var devices: [LinkedDevice] = []
    private let fileURL: URL?
    private var changeHandlers: [@Sendable ([LinkedDevice]) -> Void] = []
    private var lastSaved: Date = .distantPast

    /// `directory` nil keeps them in memory (tests).
    public init(directory: URL?) {
        fileURL = directory?.appending(path: "linked-devices.json")
        if let fileURL, let data = try? Data(contentsOf: fileURL) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            devices = (try? decoder.decode([LinkedDevice].self, from: data)) ?? []
        }
    }

    public func onChange(_ handler: @escaping @Sendable ([LinkedDevice]) -> Void) {
        changeHandlers.append(handler)
        handler(devices)
    }

    /// Adds (or replaces) a device and returns its new key.
    public func link(_ info: LinkDeviceInfo, now: Date = .now) -> String {
        let token = LinkingDesk.randomToken()
        devices.removeAll { $0.id == info.deviceID }
        devices.append(LinkedDevice(
            id: info.deviceID, kind: info.kind, name: Self.clean(info.name, fallback: info.kind.displayName),
            model: info.model.map { Self.clean($0, fallback: "") }, app: Self.clean(info.app, fallback: "Orttaai"),
            appVersion: info.appVersion, osVersion: info.osVersion,
            linkedAt: now, lastSeen: now, viaTailnet: false, tokenHash: Self.hash(token)
        ))
        changed()
        return token
    }

    public func remove(_ deviceID: String) {
        devices.removeAll { $0.id == deviceID }
        changed()
    }

    public func rename(_ deviceID: String, to name: String) {
        guard let index = devices.firstIndex(where: { $0.id == deviceID }) else { return }
        devices[index].name = Self.clean(name, fallback: devices[index].name)
        changed()
    }

    /// The device a key belongs to.
    public func device(forToken token: String) -> LinkedDevice? {
        let hash = Self.hash(token)
        return devices.first { LinkingDesk.constantTimeEqual($0.tokenHash, hash) }
    }

    /// Notes what a device just did. Written at most once a minute unless
    /// something the page shows changed.
    public func note(_ activity: LinkActivity, by deviceID: String, viaTailnet: Bool, now: Date = .now) {
        guard let index = devices.firstIndex(where: { $0.id == deviceID }) else { return }
        let routeChanged = devices[index].viaTailnet != viaTailnet
        devices[index].lastSeen = now
        devices[index].viaTailnet = viaTailnet
        switch activity {
        case .push: devices[index].lastPushAt = now
        case .pull: devices[index].lastPullAt = now
        case .other: break
        }
        if routeChanged || activity == .push || now.timeIntervalSince(lastSaved) > 60 { changed() }
    }

    static func hash(_ token: String) -> String {
        SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func clean(_ text: String, fallback: String) -> String {
        let trimmed = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
        return trimmed.isEmpty ? fallback : trimmed
    }

    private func changed() {
        if let fileURL {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            if let data = try? encoder.encode(devices) {
                try? data.write(to: fileURL, options: [.atomic])
                try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
            }
        }
        lastSaved = .now
        let snapshot = devices
        for handler in changeHandlers { handler(snapshot) }
    }
}
