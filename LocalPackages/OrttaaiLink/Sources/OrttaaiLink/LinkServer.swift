// LinkServer.swift
// OrttaaiLink
//
// Orttaai Link's HTTPS service (docs/orttaai-link-protocol.md §2, §4, §6).
// It knows nothing about Orttaai's database: the Mac app supplies a
// `LinkHost` that applies what devices send and reads what changed.

import Foundation
import Hummingbird
import HummingbirdTLS
import Logging
import NIOCore
import OrttaaiSyncCore

/// What the server needs from the Mac's archive.
public protocol LinkHost: Sendable {
    /// Which of these record names the Mac already holds.
    func existingRecordNames(_ names: [String]) async throws -> Set<String>
    /// Applies records a device sent, already checked against `LinkRules`,
    /// and queues the ones accepted for iCloud.
    func apply(_ envelopes: [SyncEnvelope], from device: LinkedDevice) async throws -> LinkPushOutcome
    /// Records changed after `cursor` that the device reads, oldest first.
    func changes(after cursor: Int64, limit: Int, for device: LinkedDevice) async throws -> LinkChangePage
    func iCloudStatus() async -> ICloudStatus
}

public struct LinkPushOutcome: Sendable, Equatable {
    /// Saved at the revision the device sent.
    public var accepted: [SyncRecordID: Revision]
    /// The Mac's version was newer; the device should take it.
    public var newer: [SyncEnvelope]

    public init(accepted: [SyncRecordID: Revision] = [:], newer: [SyncEnvelope] = []) {
        self.accepted = accepted
        self.newer = newer
    }
}

public struct LinkChangePage: Sendable, Equatable {
    public var records: [SyncEnvelope]
    /// The last change looked at, readable by the device or not.
    public var cursor: Int64
    /// More changes wait after `cursor`.
    public var more: Bool

    public init(records: [SyncEnvelope], cursor: Int64, more: Bool) {
        self.records = records
        self.cursor = cursor
        self.more = more
    }
}

public actor LinkServer {
    public nonisolated let macDeviceID: String
    public nonisolated let appVersion: String
    public nonisolated let identity: LinkIdentity
    public nonisolated let devices: LinkedDeviceStore
    public nonisolated let desk: LinkingDesk
    private let host: LinkHost

    public private(set) var name: String
    public private(set) var port: Int?
    public private(set) var tailscaleName: String?
    /// Raised by `notifyChanged`, so held requests for changes answer at once.
    private var changeGeneration = 0
    private var serverTask: Task<Void, Error>?
    private var isStarting = false
    private let logger: Logger

    public init(macDeviceID: String, name: String, appVersion: String, identity: LinkIdentity, devices: LinkedDeviceStore, host: LinkHost) {
        self.macDeviceID = macDeviceID
        self.name = name
        self.appVersion = appVersion
        self.identity = identity
        self.devices = devices
        self.desk = LinkingDesk()
        self.host = host
        var logger = Logger(label: "OrttaaiLink")
        logger.logLevel = .notice
        self.logger = logger
    }

    public func rename(_ newName: String) { name = newName }
    public func setTailscaleName(_ value: String?) { tailscaleName = value }

    /// Call after anything in the archive changes.
    public func notifyChanged() { changeGeneration &+= 1 }

    var generation: Int { changeGeneration }

    // MARK: Running

    /// Serves HTTPS on the first free port from `preferredPort`.
    public func start(preferredPort: Int = LinkProtocol.defaultPort) async throws {
        guard serverTask == nil, !isStarting else { return }
        isStarting = true
        defer { isStarting = false }
        var lastError: Error?
        for candidate in preferredPort..<(preferredPort + 20) {
            // Linked devices remember the preferred port. Just after a
            // relaunch the old process may still hold it for a moment.
            let tries = candidate == preferredPort ? 20 : 1
            for attempt in 1...tries {
                do {
                    serverTask = try await serve(on: candidate)
                    port = candidate
                    return
                } catch {
                    lastError = error
                    if attempt < tries { try? await Task.sleep(for: .milliseconds(250)) }
                }
            }
        }
        throw lastError ?? CancellationError()
    }

    public func stop() {
        serverTask?.cancel()
        serverTask = nil
        port = nil
    }

    private func serve(on port: Int) async throws -> Task<Void, Error> {
        let (events, continuation) = AsyncStream<Error?>.makeStream()
        let app = Application(
            router: makeRouter(),
            server: try .tls(.http1(), tlsConfiguration: identity.tlsConfiguration()),
            configuration: .init(address: .hostname("::", port: port), serverName: "OrttaaiLink/\(LinkProtocol.version)", reuseAddress: false),
            onServerRunning: { _ in continuation.yield(nil) },
            logger: logger
        )
        let task = Task {
            defer { continuation.finish() }
            do {
                try await app.run()
            } catch {
                continuation.yield(error)
                throw error
            }
        }
        for await event in events {
            if let event { throw event }
            return task
        }
        throw CancellationError()
    }

    // MARK: Routes

    public nonisolated func makeRouter() -> Router<BasicRequestContext> {
        let router = Router()
        router.post("link/v1/pair") { request, _ in try await self.pair(request) }
        router.get("link/v1/status") { request, _ in
            try await self.authorized(request, .other) { _, _ in try await self.status() }
        }
        router.post("sync/v1/push") { request, _ in
            try await self.authorized(request, .push) { request, device in try await self.push(request, from: device) }
        }
        router.get("sync/v1/changes") { request, _ in
            try await self.authorized(request, .pull) { request, device in try await self.changes(request, for: device) }
        }
        return router
    }

    private nonisolated func authorized(_ request: Request, _ activity: LinkActivity, _ handler: (Request, LinkedDevice) async throws -> Response) async throws -> Response {
        guard let header = request.headers[.authorization], header.lowercased().hasPrefix("bearer ") else {
            return Self.error(.unauthorized, code: "needs_key", "Link this device to the Mac first.")
        }
        let token = String(header.dropFirst("bearer ".count)).trimmingCharacters(in: .whitespaces)
        guard let device = await devices.device(forToken: token) else {
            return Self.error(.unauthorized, code: "unlinked", "This device was removed on the Mac. Link it again.")
        }
        let response = try await handler(request, device)
        if response.status.code < 400 {
            await devices.note(activity, by: device.id, viaTailnet: Self.isTailnetHost(request.head.authority))
        }
        return response
    }

    private func pair(_ request: Request) async throws -> Response {
        var request = request
        let body = try await request.collectBody(upTo: 16 * 1024)
        guard let ask = try? JSONDecoder().decode(PairRequest.self, from: Data(buffer: body)),
              ask.secret != nil || ask.code != nil else {
            return Self.error(.badRequest, code: "bad_request", "Send the code shown on the Mac, and this device's details.")
        }
        guard ask.device.kind.linksThroughMac, DeviceID.isValid(ask.device.deviceID) else {
            return Self.error(.badRequest, code: "not_linkable", "Only Orttaai for Windows and Linux and Orttakey for Android link to a Mac.")
        }
        do {
            try await desk.redeem(secret: ask.secret, code: ask.code)
        } catch .closed {
            return Self.error(.gone, code: "closed", "Open Link a device in Orttaai on the Mac first.")
        } catch .tooManyTries {
            return Self.error(.tooManyRequests, code: "too_many_tries", "Too many wrong codes. Open Link a device again for a new one.")
        } catch {
            return Self.error(.unauthorized, code: "wrong", "That code doesn't match the one on the Mac.")
        }
        let token = await devices.link(ask.device)
        logger.notice("Linked a \(ask.device.kind.displayName) device")
        notifyChanged()
        return try Self.json(PairResponse(token: token, macDeviceID: macDeviceID, name: name, tailscaleName: tailscaleName, protocol: LinkProtocol.version))
    }

    private func status() async throws -> Response {
        try Self.json(StatusResponse(
            name: name, macDeviceID: macDeviceID, version: appVersion, protocol: LinkProtocol.version,
            iCloud: await host.iCloudStatus(), tailscaleName: tailscaleName
        ))
    }

    private func push(_ request: Request, from device: LinkedDevice) async throws -> Response {
        var request = request
        let body = try await request.collectBody(upTo: LinkProtocol.maximumBodyBytes)
        guard let ask = try? JSONDecoder().decode(PushRequest.self, from: Data(buffer: body)) else {
            return Self.error(.badRequest, code: "bad_request", "The records couldn't be read.")
        }
        guard ask.records.count <= LinkProtocol.maximumBatch else {
            return Self.error(.contentTooLarge, code: "too_many", "Send at most \(LinkProtocol.maximumBatch) records at a time.")
        }

        var response = PushResponse()
        var envelopes: [SyncEnvelope] = []
        for record in ask.records {
            do {
                envelopes.append(try record.envelope())
            } catch {
                response.rejected.append(.init(recordName: record.recordName, problem: String(describing: error)))
            }
        }
        // A record from a newer schema than this Mac reads: keep it on the
        // device until the Mac is updated, rather than refusing it for good.
        if envelopes.contains(where: { if case .unsupportedSchemaVersion = $0.problem { true } else { false } }) {
            return Self.error(.upgradeRequired, code: "updateMac", "Update Orttaai on the Mac to sync this device.")
        }
        let existing = try await host.existingRecordNames(envelopes.map(\.id.recordName))
        var allowed: [SyncEnvelope] = []
        for envelope in envelopes {
            if let refusal = LinkRules.refusal(envelope, from: device, exists: existing.contains(envelope.id.recordName)) {
                response.rejected.append(.init(recordName: envelope.id.recordName, problem: refusal))
            } else {
                allowed.append(envelope)
            }
        }
        if !allowed.isEmpty {
            let outcome = try await host.apply(allowed, from: device)
            for (id, revision) in outcome.accepted.sorted(by: { $0.key.recordName < $1.key.recordName }) {
                response.accepted.append(.init(recordName: id.recordName, revision: LinkRecord.WireRevision(revision)))
            }
            response.newer = outcome.newer.map(LinkRecord.init)
            if !outcome.accepted.isEmpty { notifyChanged() }
        }
        return try Self.json(response)
    }

    private func changes(_ request: Request, for device: LinkedDevice) async throws -> Response {
        let query = request.uri.queryParameters
        let cursor = query.get("since").flatMap { Int64($0) } ?? 0
        let limit = min(max(query.get("limit").flatMap { Int($0) } ?? LinkProtocol.maximumBatch, 1), LinkProtocol.maximumBatch)
        let wait = min(max(query.get("wait").flatMap { Int($0) } ?? 0, 0), LinkProtocol.maximumWait)

        var page = try await readablePage(after: cursor, limit: limit, for: device)
        if page.records.isEmpty, page.cursor == cursor, !page.more, wait > 0 {
            // Nothing new: hold the request until something changes, checking
            // the archive itself every few seconds in case a change came by a
            // path that didn't say so.
            let deadline = ContinuousClock.now + .seconds(wait)
            var seen = generation
            var lastRead = ContinuousClock.now
            while ContinuousClock.now < deadline, !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard generation != seen || ContinuousClock.now - lastRead > .seconds(5) else { continue }
                seen = generation
                lastRead = ContinuousClock.now
                page = try await readablePage(after: cursor, limit: limit, for: device)
                if page.cursor != cursor || page.more { break }
            }
        }
        return try Self.json(ChangesResponse(records: page.records.map(LinkRecord.init), cursor: String(page.cursor), more: page.more))
    }

    private func readablePage(after cursor: Int64, limit: Int, for device: LinkedDevice) async throws -> LinkChangePage {
        var page = try await host.changes(after: cursor, limit: limit, for: device)
        page.records = page.records.filter { LinkRules.reads($0.id, device: device) }
        return page
    }

    // MARK: Helpers

    /// A device away from home asks for the Mac's tailnet name (or a
    /// 100.64/10 address); at home a Wi-Fi address or the .local name.
    nonisolated static func isTailnetHost(_ authority: String?) -> Bool {
        guard let authority else { return false }
        var host = authority.lowercased()
        if host.hasPrefix("["), let end = host.firstIndex(of: "]") {
            host = String(host[host.index(after: host.startIndex)..<end])
        } else if let colon = host.lastIndex(of: ":"), host.filter({ $0 == ":" }).count == 1 {
            host = String(host[..<colon])
        }
        if host.hasSuffix(".ts.net") { return true }
        if host.hasPrefix("fd7a:115c:a1e0:") { return true }
        let parts = host.split(separator: ".").compactMap { Int($0) }
        return parts.count == 4 && parts[0] == 100 && (64...127).contains(parts[1])
    }

    nonisolated static func json(_ value: some Encodable, status: HTTPResponse.Status = .ok) throws -> Response {
        Response(
            status: status,
            headers: [.contentType: "application/json"],
            body: ResponseBody(byteBuffer: ByteBuffer(data: try LinkWire.encode(value)))
        )
    }

    nonisolated static func error(_ status: HTTPResponse.Status, code: String, _ message: String) -> Response {
        (try? json(LinkErrorBody(error: .init(code: code, message: message)), status: status)) ?? Response(status: status)
    }
}

// MARK: - For the Mac's Devices page

public extension LinkServer {
    /// The QR code's text for an open linking session.
    func linkingURL(for session: LinkingSession, hosts: [String]) -> URL? {
        guard let port else { return nil }
        var components = URLComponents()
        components.scheme = "orttaai"
        components.host = "link"
        var items = [
            URLQueryItem(name: "v", value: String(LinkProtocol.version)),
            URLQueryItem(name: "id", value: macDeviceID),
            URLQueryItem(name: "n", value: name),
            URLQueryItem(name: "h", value: hosts.joined(separator: ",")),
            URLQueryItem(name: "p", value: String(port)),
            URLQueryItem(name: "fp", value: identity.fingerprint),
        ]
        if let tailscaleName { items.append(URLQueryItem(name: "ts", value: tailscaleName)) }
        components.queryItems = items
        components.fragment = session.secret
        return components.url
    }

    /// The Bonjour TXT record.
    func bonjourRecord(host: String, addresses: [String], linking: Bool) -> [String: String] {
        var record = ["v": String(LinkProtocol.version), "id": macDeviceID, "fp": identity.fingerprint, "host": host,
                      "ips": addresses.joined(separator: ","), "pair": linking ? "1" : "0"]
        if let port { record["port"] = String(port) }
        return record
    }
}
