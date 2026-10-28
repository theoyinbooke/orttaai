// CoachNaturalVoiceTests.swift
// OrttaaiTests
//
// Scene partners with a voice of their own speak in it once the voice model
// is installed; everyone else, and everyone before then, uses the Mac's own.

import CoachCore
import XCTest
@testable import Orttaai

@MainActor
final class CoachNaturalVoiceTests: XCTestCase {
    func testOlasVoiceShipsInTheApp() throws {
        let url = try XCTUnwrap(CoachNaturalVoice.voiceURL(for: "Ola"))
        let size = try XCTUnwrap(try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int)
        XCTAssertGreaterThan(size, 100_000, "A Pocket TTS voice file")
        XCTAssertEqual(CoachNaturalVoice.voiceURL(for: "ola"), url)
    }

    func testEveryScenePartnerWithAVoiceIsInTheScenes() {
        let partners = Set(CoachScene.all.map { $0.partnerName.lowercased() })
        for speaker in CoachNaturalVoice.voices.keys {
            XCTAssertTrue(partners.contains(speaker), "\(speaker) isn't a scene partner")
        }
    }

    func testOnlyPartnersWithAVoiceAndAnInstalledModelSpeakInIt() {
        let voice = CoachNaturalVoice.shared
        XCTAssertNil(CoachNaturalVoice.voiceURL(for: "Atlas"))
        if voice.state == .ready {
            XCTAssertTrue(voice.canSpeak(as: "Ola"))
        } else {
            XCTAssertFalse(voice.canSpeak(as: "Ola"))
        }
        XCTAssertFalse(voice.canSpeak(as: "Atlas"))
    }

    func testTheModelLivesInItsOwnFolderUnderTheModelFolder() {
        let base = URL(fileURLWithPath: "/tmp/models", isDirectory: true)
        XCTAssertEqual(CoachNaturalVoice.folder(in: base).path, "/tmp/models/Coach voices")
    }
}
