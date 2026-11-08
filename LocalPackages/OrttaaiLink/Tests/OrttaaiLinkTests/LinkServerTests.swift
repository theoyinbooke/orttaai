// LinkServerTests.swift
// OrttaaiLinkTests
//
// The service end to end through its routes, against an archive kept in
// memory that applies the same conflict policy as the Mac's.

import Foundation
import Hummingbird
import HummingbirdTesting
import NIOCore
import Testing
@testable import OrttaaiLink
import OrttaaiSyncCore

/// An archive in memory: records by name, each change numbered.
actor MemoryHost: LinkHost {
    private(set) var records: [String: (envelope: SyncEnvelope, seq: Int64)] = [:]
    private(set) var queuedForICloud: [String: Revision] = [:]
    private var seq: Int64 = 0

    func put(_ envelope: SyncEnvelope) {
        seq += 1
        records[envelope.id.recordName] = (envelope, seq)
    }

    func existingRecordNames(_ names: [String]) -> Set<String> {
        Set(names.filter { records[$0] != nil })
    }

    func apply(_ envelopes: [SyncEnvelope], from device: LinkedDevice) -> LinkPushOutcome {
        var outcome = LinkPushOutcome()
        for envelope in envelopes {
            let local = records[envelope.id.recordName].map { LocalRecordState(revision: $0.envelope.revision, isDeleted: $0.envelope.isDeleted, generation: $0.envelope.generation) }
            switch ConflictPolicy.decide(local: local, remote: envelope) {
            case .acceptRemote:
                put(envelope)
                queuedForICloud[envelope.id.recordName] = envelope.revision
                outcome.accepted[envelope.id] = envelope.revision
            case .keepLocal:
                if let mine = records[envelope.id.recordName]?.envelope { outcome.newer.append(mine) }
            case .alreadyCurrent:
                outcome.accepted[envelope.id] = envelope.revision
            }
        }
        return outcome
    }

    func changes(after cursor: Int64, limit: Int, for device: LinkedDevice) -> LinkChangePage {
        let after = records.values.filter { $0.seq > cursor }.sorted { $0.seq < $1.seq }
        let page = after.prefix(limit)
        return LinkChangePage(records: page.map(\.envelope), cursor: page.last?.seq ?? cursor, more: after.count > limit)
    }

    func iCloudStatus() -> ICloudStatus { ICloudStatus(state: .syncing, lastSentAt: Sample.now) }
}

@Suite("Orttaai Link service")
struct LinkServerTests {
    let host = MemoryHost()

    func makeServer() throws -> LinkServer {
        LinkServer(macDeviceID: Sample.mac, name: "Mac Studio", appVersion: "1.20.0", identity: try .ephemeral(),
                   devices: LinkedDeviceStore(directory: nil), host: host)
    }

    static func body(_ value: some Encodable) throws -> ByteBuffer { ByteBuffer(data: try LinkWire.encode(value)) }
    static func decode<T: Decodable>(_ type: T.Type, _ buffer: ByteBuffer) throws -> T { try JSONDecoder().decode(type, from: Data(buffer: buffer)) }

    /// Opens a linking session and links a device with the code.
    func link(_ server: LinkServer, _ client: some TestClientProtocol, id: String, kind: DeviceKind) async throws -> String {
        let session = await server.desk.open()
        let ask = PairRequest(code: session.code, device: LinkDeviceInfo(deviceID: id, kind: kind, name: kind.displayName, app: "Orttaai"))
        return try await client.execute(uri: "/link/v1/pair", method: .post, body: try Self.body(ask)) { response in
            #expect(response.status == .ok)
            let answer = try Self.decode(PairResponse.self, response.body)
            #expect(answer.macDeviceID == Sample.mac)
            #expect(answer.protocol == LinkProtocol.version)
            return answer.token
        }
    }

    @Test func linkSendAndCatchUp() async throws {
        let server = try makeServer()
        await host.put(try Sample.word("Lagos", writer: Sample.iphone))
        await host.put(try Sample.dictation("mac-1", origin: Sample.mac, kind: .mac))
        let app = Application(router: server.makeRouter())
        try await app.test(.router) { client in
            let token = try await link(server, client, id: Sample.linux, kind: .linux)
            let auth: HTTPFields = [.authorization: "Bearer \(token)"]

            // Send a dictation said on Linux.
            let mine = try Sample.dictation("linux-1", origin: Sample.linux, kind: .linux, text: "Ship it on Friday")
            try await client.execute(uri: "/sync/v1/push", method: .post, headers: auth, body: try Self.body(PushRequest(records: [LinkRecord(mine)]))) { response in
                #expect(response.status == .ok)
                let answer = try Self.decode(PushResponse.self, response.body)
                #expect(answer.accepted.map(\.recordName) == [mine.id.recordName])
                #expect(answer.rejected.isEmpty)
            }
            #expect(await host.queuedForICloud[mine.id.recordName] == mine.revision)

            // Catch up from the start: everything a PC reads, its own included.
            try await client.execute(uri: "/sync/v1/changes?since=", method: .get, headers: auth) { response in
                let answer = try Self.decode(ChangesResponse.self, response.body)
                #expect(Set(answer.records.map(\.recordName)) == ["dict." + SyncNormalization.digest("lagos"), "dictation.mac-1", "dictation.linux-1"])
                #expect(answer.more == false)
                #expect(answer.cursor == "3")
                #expect(try answer.records.first { $0.recordName == "dictation.linux-1" }?.envelope() == mine)
            }
        }
        let device = await server.devices.devices.first
        #expect(device?.lastPushAt != nil)
        #expect(device?.lastPullAt != nil)
    }

    @Test func aPhoneGetsWordsAndItsOwnDictationsOnly() async throws {
        let server = try makeServer()
        await host.put(try Sample.word("Lagos", writer: Sample.mac))
        await host.put(try Sample.dictation("mac-1", origin: Sample.mac, kind: .mac))
        await host.put(try Sample.dictation("droid-1", origin: Sample.android, kind: .android))
        let app = Application(router: server.makeRouter())
        try await app.test(.router) { client in
            let token = try await link(server, client, id: Sample.android, kind: .android)
            try await client.execute(uri: "/sync/v1/changes?since=0", method: .get, headers: [.authorization: "Bearer \(token)"]) { response in
                let answer = try Self.decode(ChangesResponse.self, response.body)
                #expect(Set(answer.records.map(\.recordName)) == ["dict." + SyncNormalization.digest("lagos"), "dictation.droid-1"])
                #expect(answer.cursor == "3")
            }
        }
    }

    @Test func anOlderEditGetsTheMacsNewerVersionBack() async throws {
        let server = try makeServer()
        let macVersion = try Sample.word("Lagos", writer: Sample.mac, counter: 10)
        await host.put(macVersion)
        let app = Application(router: server.makeRouter())
        try await app.test(.router) { client in
            let token = try await link(server, client, id: Sample.linux, kind: .linux)
            let stale = try Sample.word("Lagos", writer: Sample.linux, counter: 3)
            try await client.execute(uri: "/sync/v1/push", method: .post, headers: [.authorization: "Bearer \(token)"], body: try Self.body(PushRequest(records: [LinkRecord(stale)]))) { response in
                let answer = try Self.decode(PushResponse.self, response.body)
                #expect(answer.accepted.isEmpty)
                #expect(try answer.newer.map { try $0.envelope() } == [macVersion])
            }
        }
    }

    @Test func refusedRecordsAreNamedAndTheRestGoThrough() async throws {
        let server = try makeServer()
        let app = Application(router: server.makeRouter())
        try await app.test(.router) { client in
            let token = try await link(server, client, id: Sample.android, kind: .android)
            let good = try Sample.word("Ikeja", writer: Sample.android)
            let notMine = try Sample.dictation("mac-9", origin: Sample.mac, kind: .mac, writer: Sample.android)
            try await client.execute(uri: "/sync/v1/push", method: .post, headers: [.authorization: "Bearer \(token)"], body: try Self.body(PushRequest(records: [LinkRecord(good), LinkRecord(notMine)]))) { response in
                let answer = try Self.decode(PushResponse.self, response.body)
                #expect(answer.accepted.map(\.recordName) == [good.id.recordName])
                #expect(answer.rejected.map(\.recordName) == ["dictation.mac-9"])
            }
        }
    }

    @Test func aRecordFromANewerSchemaWaitsForAMacUpdate() async throws {
        let server = try makeServer()
        let app = Application(router: server.makeRouter())
        try await app.test(.router) { client in
            let token = try await link(server, client, id: Sample.linux, kind: .linux)
            var record = LinkRecord(try Sample.dictation("future", origin: Sample.linux, kind: .linux))
            record.schemaVersion = SyncEnvelope.currentSchemaVersion + 1
            try await client.execute(uri: "/sync/v1/push", method: .post, headers: [.authorization: "Bearer \(token)"], body: try Self.body(PushRequest(records: [record]))) { response in
                #expect(response.status == .upgradeRequired)
                let error = try Self.decode(LinkErrorBody.self, response.body).error
                #expect(error.code == "updateMac")
            }
        }
    }

    @Test func aRemovedDeviceIsToldItsUnlinked() async throws {
        let server = try makeServer()
        let app = Application(router: server.makeRouter())
        try await app.test(.router) { client in
            let token = try await link(server, client, id: Sample.linux, kind: .linux)
            await server.devices.remove(Sample.linux)
            try await client.execute(uri: "/link/v1/status", method: .get, headers: [.authorization: "Bearer \(token)"]) { response in
                #expect(response.status == .unauthorized)
                let error = try Self.decode(LinkErrorBody.self, response.body).error
                #expect(error.code == "unlinked")
            }
            try await client.execute(uri: "/link/v1/status", method: .get) { response in
                #expect(response.status == .unauthorized)
            }
        }
    }

    @Test func onlyLinkedDeviceKindsMayLink() async throws {
        let server = try makeServer()
        let app = Application(router: server.makeRouter())
        try await app.test(.router) { client in
            let session = await server.desk.open()
            let ask = PairRequest(code: session.code, device: LinkDeviceInfo(deviceID: Sample.iphone, kind: .iphone, name: "iPhone", app: "Orttakey"))
            try await client.execute(uri: "/link/v1/pair", method: .post, body: try Self.body(ask)) { response in
                #expect(response.status == .badRequest)
                let error = try Self.decode(LinkErrorBody.self, response.body).error
                #expect(error.code == "not_linkable")
            }
            let wrong = PairRequest(code: session.code == "000000" ? "111111" : "000000", device: LinkDeviceInfo(deviceID: Sample.linux, kind: .linux, name: "PC", app: "Orttaai"))
            try await client.execute(uri: "/link/v1/pair", method: .post, body: try Self.body(wrong)) { response in
                #expect(response.status == .unauthorized)
            }
        }
    }

    @Test func statusSaysHowICloudStands() async throws {
        let server = try makeServer()
        await server.setTailscaleName("orttaai-mac-studio.tail1b0ba8.ts.net")
        let app = Application(router: server.makeRouter())
        try await app.test(.router) { client in
            let token = try await link(server, client, id: Sample.windowsLike, kind: .windows)
            try await client.execute(uri: "/link/v1/status", method: .get, headers: [.authorization: "Bearer \(token)"]) { response in
                let answer = try Self.decode(StatusResponse.self, response.body)
                #expect(answer.name == "Mac Studio")
                #expect(answer.iCloud.state == .syncing)
                #expect(answer.tailscaleName == "orttaai-mac-studio.tail1b0ba8.ts.net")
            }
        }
    }

    @Test func aHeldRequestAnswersAsSoonAsSomethingChanges() async throws {
        let server = try makeServer()
        let app = Application(router: server.makeRouter())
        try await app.test(.router) { client in
            let token = try await link(server, client, id: Sample.linux, kind: .linux)
            let host = self.host
            let change = Task {
                try await Task.sleep(for: .milliseconds(600))
                await host.put(try Sample.word("Abuja", writer: Sample.mac))
                await server.notifyChanged()
            }
            let started = ContinuousClock.now
            try await client.execute(uri: "/sync/v1/changes?since=0&wait=10", method: .get, headers: [.authorization: "Bearer \(token)"]) { response in
                let answer = try Self.decode(ChangesResponse.self, response.body)
                #expect(answer.records.map(\.recordName) == ["dict." + SyncNormalization.digest("abuja")])
            }
            #expect(ContinuousClock.now - started < .seconds(5))
            try await change.value
        }
    }

    @Test func tailnetAddressesAreRecognised() {
        #expect(LinkServer.isTailnetHost("orttaai-mac.tail1b0ba8.ts.net:47821"))
        #expect(LinkServer.isTailnetHost("100.101.5.9:47821"))
        #expect(LinkServer.isTailnetHost("[fd7a:115c:a1e0::1]:47821"))
        #expect(!LinkServer.isTailnetHost("192.168.1.20:47821"))
        #expect(!LinkServer.isTailnetHost("mac-studio.local:47821"))
    }

    @Test func theQRCodeCarriesWhatADeviceNeeds() async throws {
        let server = try makeServer()
        // Not serving, so no port yet: no link to show.
        let session = await server.desk.open()
        #expect(await server.linkingURL(for: session, hosts: ["192.168.1.20"]) == nil)
        let record = await server.bonjourRecord(host: "mac-studio.local", addresses: ["192.168.1.20"], linking: true)
        #expect(record["fp"] == server.identity.fingerprint)
        #expect(record["id"] == Sample.mac)
        #expect(record["pair"] == "1")
    }
}

extension Sample {
    static let windowsLike = "9a3e5b71-0c4d-4f28-8e16-b2d7f4a9c053"
}
