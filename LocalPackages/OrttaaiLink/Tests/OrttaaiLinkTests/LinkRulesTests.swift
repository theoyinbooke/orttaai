// LinkRulesTests.swift
// OrttaaiLinkTests

import Foundation
import Testing
@testable import OrttaaiLink
import OrttaaiSyncCore

enum Sample {
    static let mac = "6f1d1c9e-1b7a-4c55-9c39-0d3c1e2a7b10"
    static let linux = "2f0c8a4e-7d21-4b9a-a3f6-5e8d9c1b0a42"
    static let android = "c47b2e90-5a13-4d6e-9f08-71e3a5d2b6c4"
    static let iphone = "e8d4f1a2-36b9-4c07-b5e1-9a0c2f7d84e3"
    static let now = Date(timeIntervalSince1970: 1_790_000_000)

    static func device(_ id: String, _ kind: DeviceKind) -> LinkedDevice {
        LinkedDevice(id: id, kind: kind, name: kind.displayName, app: kind == .android ? "Orttakey" : "Orttaai",
                     linkedAt: now, viaTailnet: false, tokenHash: "")
    }

    static func dictation(_ syncID: String, origin: String, kind: DeviceKind, writer: String? = nil, counter: Int64 = 1, text: String = "Hello", deleted: Bool = false) throws -> SyncEnvelope {
        SyncEnvelope(
            id: .dictation(syncID: syncID, zone: .dictations(originDeviceID: origin)),
            revision: Revision(counter: counter, modifiedAt: now, writerDeviceID: writer ?? origin),
            isDeleted: deleted,
            deletedAt: deleted ? now : nil,
            payload: deleted ? nil : try PayloadCoder.encode(DictationPayload(createdAt: now, text: text, targetAppName: "Claude Code")),
            origin: DictationOrigin(deviceID: origin, kind: kind),
            createdAt: now
        )
    }

    static func word(_ source: String, writer: String, counter: Int64 = 1) throws -> SyncEnvelope {
        let payload = DictionaryEntryPayload(source: source, target: source, createdAt: now)
        return SyncEnvelope(
            id: .dictionaryEntry(normalizedSource: payload.normalizedSource),
            revision: Revision(counter: counter, modifiedAt: now, writerDeviceID: writer),
            payload: try PayloadCoder.encode(payload)
        )
    }

    static func deviceRecord(_ id: String, _ kind: DeviceKind, writer: String? = nil) throws -> SyncEnvelope {
        let payload = DevicePayload(deviceID: id, kind: kind, name: kind.displayName, app: "Orttaai", firstSeenAt: now, lastSeenAt: now)
        return SyncEnvelope(id: .device(id), revision: Revision(counter: 1, modifiedAt: now, writerDeviceID: writer ?? id), payload: try PayloadCoder.encode(payload))
    }
}

@Suite("What linked devices may read and write")
struct LinkRulesTests {
    let linux = Sample.device(Sample.linux, .linux)
    let android = Sample.device(Sample.android, .android)

    @Test func aDeviceSendsItsOwnDictations() throws {
        #expect(LinkRules.refusal(try Sample.dictation("a", origin: Sample.linux, kind: .linux), from: linux, exists: false) == nil)
        #expect(LinkRules.refusal(try Sample.dictation("b", origin: Sample.android, kind: .android), from: android, exists: false) == nil)
    }

    @Test func aDeviceCantClaimAnotherDevicesDictation() throws {
        // Its own zone, but another kind in the origin.
        #expect(LinkRules.refusal(try Sample.dictation("a", origin: Sample.linux, kind: .windows), from: linux, exists: false) != nil)
        // Another device's zone, a record the Mac doesn't have.
        #expect(LinkRules.refusal(try Sample.dictation("c", origin: Sample.mac, kind: .mac, writer: Sample.linux), from: linux, exists: false) != nil)
    }

    @Test func aPCMayEditOrDeleteAnyDictationAPhoneMayNot() throws {
        let deletion = try Sample.dictation("m", origin: Sample.mac, kind: .mac, writer: Sample.linux, counter: 9, deleted: true)
        #expect(LinkRules.refusal(deletion, from: linux, exists: true) == nil)
        let phoneDeletion = try Sample.dictation("m", origin: Sample.mac, kind: .mac, writer: Sample.android, counter: 9, deleted: true)
        #expect(LinkRules.refusal(phoneDeletion, from: android, exists: true) != nil)
    }

    @Test func revisionsAreWrittenAsTheSender() throws {
        #expect(LinkRules.refusal(try Sample.word("Lagos", writer: Sample.mac), from: linux, exists: false) == "written by another device")
        #expect(LinkRules.refusal(try Sample.word("Lagos", writer: Sample.linux), from: linux, exists: false) == nil)
    }

    @Test func onlyItsOwnDeviceRecord() throws {
        #expect(LinkRules.refusal(try Sample.deviceRecord(Sample.linux, .linux), from: linux, exists: false) == nil)
        #expect(LinkRules.refusal(try Sample.deviceRecord(Sample.mac, .mac, writer: Sample.linux), from: linux, exists: true) != nil)
        // Its own record name, but claiming to be a Mac.
        let payload = DevicePayload(deviceID: Sample.linux, kind: .mac, name: "Mac", app: "Orttaai", firstSeenAt: Sample.now, lastSeenAt: Sample.now)
        let lying = SyncEnvelope(id: .device(Sample.linux), revision: Revision(counter: 1, modifiedAt: Sample.now, writerDeviceID: Sample.linux), payload: try PayloadCoder.encode(payload))
        #expect(LinkRules.refusal(lying, from: linux, exists: false) != nil)
    }

    @Test func macRecordsStayAMacs() {
        let prefs = SyncEnvelope(id: .macPreferences, revision: Revision(counter: 1, modifiedAt: Sample.now, writerDeviceID: Sample.linux),
                                 payload: try? PayloadCoder.encode(MacPreferencesPayload(entries: [:])))
        #expect(LinkRules.refusal(prefs, from: linux, exists: true) == "only a Mac writes this")
        #expect(!LinkRules.reads(.macPreferences, device: linux))
        #expect(!LinkRules.reads(.toneProfile, device: linux))
        #expect(LinkRules.reads(.macSummary(macDeviceID: Sample.mac), device: android))
    }

    @Test func phonesSyncOnlyWordsAndTheirOwnDictations() throws {
        let snippetPayload = SnippetPayload(trigger: "addr", expansion: "12 Marina Road", createdAt: Sample.now)
        let snippet = SyncEnvelope(id: .snippet(normalizedTrigger: "addr"), revision: Revision(counter: 1, modifiedAt: Sample.now, writerDeviceID: Sample.android), payload: try PayloadCoder.encode(snippetPayload))
        #expect(LinkRules.refusal(snippet, from: android, exists: false) != nil)
        #expect(LinkRules.refusal(try Sample.word("Lagos", writer: Sample.android), from: android, exists: false) == nil)

        #expect(!LinkRules.reads(.dictation(syncID: "x", zone: .dictations(originDeviceID: Sample.mac)), device: android))
        #expect(LinkRules.reads(.dictation(syncID: "x", zone: .dictations(originDeviceID: Sample.android)), device: android))
        #expect(LinkRules.reads(.dictation(syncID: "x", zone: .dictations(originDeviceID: Sample.iphone)), device: linux))
        #expect(!LinkRules.reads(.snippet(normalizedTrigger: "addr"), device: android))
        #expect(LinkRules.reads(.snippet(normalizedTrigger: "addr"), device: linux))
    }

    @Test func aBrokenRecordIsRefusedWithItsProblem() throws {
        var envelope = try Sample.dictation("a", origin: Sample.linux, kind: .linux)
        envelope.payload = Data("{}".utf8)
        #expect(LinkRules.refusal(envelope, from: linux, exists: false) == EnvelopeProblem.undecodablePayload.description)
    }
}

@Suite("Linking")
struct LinkingTests {
    @Test func theCodeWorksOnceAndTheSecretToo() async throws {
        let desk = LinkingDesk()
        let session = await desk.open()
        try await desk.redeem(secret: nil, code: session.code)
        await #expect(throws: LinkingRefusal.closed) { try await desk.redeem(secret: nil, code: session.code) }
        let second = await desk.open()
        try await desk.redeem(secret: second.secret, code: nil)
        #expect(await desk.isOpen == false)
    }

    @Test func fiveWrongCodesCloseTheSession() async throws {
        let desk = LinkingDesk()
        let session = await desk.open()
        let wrong = session.code == "000000" ? "111111" : "000000"
        for _ in 1..<LinkingSession.allowedWrongCodes {
            await #expect(throws: LinkingRefusal.wrong) { try await desk.redeem(secret: nil, code: wrong) }
        }
        await #expect(throws: LinkingRefusal.tooManyTries) { try await desk.redeem(secret: nil, code: wrong) }
        await #expect(throws: LinkingRefusal.closed) { try await desk.redeem(secret: nil, code: session.code) }
    }

    @Test func anExpiredSessionIsClosed() async throws {
        let clock = Clock()
        let desk = LinkingDesk(now: { clock.now })
        let session = await desk.open()
        clock.now = clock.now.addingTimeInterval(LinkingSession.lifetime + 1)
        await #expect(throws: LinkingRefusal.closed) { try await desk.redeem(secret: session.secret, code: nil) }
    }

    @Test func linkingAgainReplacesTheKeyAndRemovingRevokesIt() async throws {
        let store = LinkedDeviceStore(directory: nil)
        let info = LinkDeviceInfo(deviceID: Sample.linux, kind: .linux, name: "  ThinkPad  ", app: "Orttaai")
        let first = await store.link(info)
        let second = await store.link(info)
        #expect(await store.device(forToken: first) == nil)
        #expect(await store.device(forToken: second)?.name == "ThinkPad")
        #expect(await store.devices.count == 1)
        await store.remove(Sample.linux)
        #expect(await store.device(forToken: second) == nil)
    }

    @Test func theListSurvivesARelaunch() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "link-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let token = await LinkedDeviceStore(directory: directory).link(LinkDeviceInfo(deviceID: Sample.android, kind: .android, name: "Pixel", app: "Orttakey"))
        let reopened = LinkedDeviceStore(directory: directory)
        #expect(await reopened.device(forToken: token)?.kind == .android)
    }

    @Test func theIdentityIsKeptAndItsFingerprintIsStable() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "link-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = try LinkIdentity.loadOrCreate(in: directory)
        let again = try LinkIdentity.loadOrCreate(in: directory)
        #expect(first.fingerprint == again.fingerprint)
        #expect(first.fingerprint.count == 64)
        // A renewed certificate keeps the key, so devices keep trusting it.
        let renewed = try LinkIdentity.loadOrCreate(in: directory, now: Date().addingTimeInterval(380 * 86_400))
        #expect(renewed.fingerprint == first.fingerprint)
        #expect(renewed.certificateDER != first.certificateDER)
    }
}

final class Clock: @unchecked Sendable {
    var now = Date(timeIntervalSince1970: 1_790_000_000)
}
