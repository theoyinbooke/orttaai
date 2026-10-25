// StressTests.swift
// OrttaaiSyncCoreTests
//
// Two Macs, an iPhone and an iPad make random changes, sync in random
// orders through a network that drops a fifth of everything, and crash now
// and then. When the dust settles, every device must agree with iCloud and
// with what actually happened.

import Foundation
import Testing
@testable import OrttaaiSyncCore

@Suite("Randomized multi-device sync")
struct StressTests {
    static let words = ["Tolu", "Orttaai", "Orttakey", "SwiftUI", "Lagos", "GRDB", "CloudKit"]

    /// 40 seeds by default; ORTTAAI_SYNC_STRESS_SEEDS=500 for a long run.
    static let seeds: [UInt64] = {
        let count = ProcessInfo.processInfo.environment["ORTTAAI_SYNC_STRESS_SEEDS"].flatMap(UInt64.init) ?? 40
        return Array(1...max(1, count))
    }()

    static let steps = Int(ProcessInfo.processInfo.environment["ORTTAAI_SYNC_STRESS_STEPS"] ?? "") ?? 160

    @Test(arguments: StressTests.seeds)
    func everyDeviceConverges(seed: UInt64) async throws {
        var random = SeededRandom(seed: seed)
        let cloud = SimCloud()
        let macA = SimDevice(name: "macA", platform: .mac, kind: .mac)
        let macB = SimDevice(name: "macB", platform: .mac, kind: .mac)
        let phone = SimDevice(name: "phone", platform: .mobile, kind: .iphone)
        let pad = SimDevice(name: "pad", platform: .mobile, kind: .ipad)
        let devices = [macA, macB, phone, pad]
        let macs = [macA, macB]
        for device in devices { try await device.boot() }

        var created: [SyncRecordID: SimDevice] = [:]
        var deleted = Set<SyncRecordID>()

        for _ in 0..<Self.steps {
            let device = devices.randomElement(using: &random)!
            switch Int.random(in: 0..<100, using: &random) {
            case 0..<28:
                let id = device.store.createDictation(text: "Dictation \(Int.random(in: 0..<10_000, using: &random))")
                created[id] = device
                await device.noteLocalChanges([id])
            case 28..<38:
                if let id = device.store.liveDictations().keys.randomElement(using: &random) {
                    device.store.editDictation(id, text: "Edited \(Int.random(in: 0..<10_000, using: &random))")
                    await device.noteLocalChanges([id])
                }
            case 38..<46:
                if let id = device.store.liveDictations().keys.randomElement(using: &random) {
                    device.store.deleteDictation(id)
                    deleted.insert(id)
                    await device.noteLocalChanges([id])
                }
            case 46..<58:
                let word = Self.words.randomElement(using: &random)!
                let target = Bool.random(using: &random) ? word : word.uppercased()
                let id = device.store.upsertWord(source: word, target: target)
                await device.noteLocalChanges([id])
            case 58..<63:
                let word = Self.words.randomElement(using: &random)!
                device.store.deleteWord(source: word)
                await device.noteLocalChanges([.dictionaryEntry(normalizedSource: SyncNormalization.normalizedKey(word))])
            case 63..<67:
                try await device.crashAndRelaunch(losePending: Bool.random(using: &random))
            default:
                await device.sync(with: cloud, random: &random, failureRate: 0.2)
            }
        }

        // Network back to normal; let everything settle.
        for _ in 0..<12 {
            for device in devices.shuffled(using: &random) {
                await device.sync(with: cloud, random: &random)
            }
        }

        // Nothing is owed to iCloud any more.
        for device in devices {
            let owed = try device.store.outboxEntries()
            #expect(owed.isEmpty, "\(device.name) still owes \(owed.count) changes (seed \(seed))")
            #expect(device.store.quarantined.isEmpty)
            #expect(device.store.failedSends.isEmpty)
        }

        // The run did real work: dictations from phones and Macs went through.
        #expect(created.count > 20)
        #expect(cloud.saveCount > created.count)
        #expect(created.values.contains { $0.platform == .mobile })

        // Every Mac holds every dictation that wasn't deleted anywhere.
        let expectedLive = Set(created.keys).subtracting(deleted)
        for mac in macs {
            #expect(Set(mac.store.liveDictations().keys) == expectedLive, "\(mac.name) differs (seed \(seed))")
        }
        #expect(macA.store.liveDictations() == macB.store.liveDictations())

        // Each phone holds exactly its own, with the same text as the Macs.
        for mobile in [phone, pad] {
            let own = Set(created.filter { $0.value === mobile }.keys).subtracting(deleted)
            let live = mobile.store.liveDictations()
            #expect(Set(live.keys) == own, "\(mobile.name) differs (seed \(seed))")
            #expect(mobile.store.rows.keys.allSatisfy { $0.zone == .library || $0.zone == mobile.store.ownZone })
            for (id, text) in live { #expect(macA.store.liveDictations()[id] == text) }
        }

        // Nothing deleted is alive anywhere, iCloud included.
        for id in deleted {
            #expect(cloud.record(id)?.isDeleted == true, "\(id) alive in iCloud (seed \(seed))")
            for device in devices { #expect(device.store.liveDictations()[id] == nil) }
        }

        // One dictionary everywhere.
        let dictionary = macA.store.dictionary()
        for device in devices {
            #expect(device.store.dictionary() == dictionary, "\(device.name) dictionary differs (seed \(seed))")
        }
    }
}
