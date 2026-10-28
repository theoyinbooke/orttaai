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
        for speaker in Array(CoachNaturalVoice.voices.keys) + Array(CoachNaturalVoice.presetVoices.keys) {
            XCTAssertTrue(partners.contains(speaker), "\(speaker) isn't a scene partner")
        }
    }

    func testEveryScenePartnerHasANaturalVoice() {
        for scene in CoachScene.all {
            let key = scene.partnerName.lowercased()
            XCTAssertTrue(
                CoachNaturalVoice.voices[key] != nil || CoachNaturalVoice.presetVoices[key] != nil,
                "\(scene.partnerName) would speak in the Mac's voice"
            )
        }
    }

    func testPresetVoicesAreEnglishCatalogueVoices() {
        for voice in CoachNaturalVoice.presetVoices.values {
            XCTAssertTrue(voice.hasPrefix("en_us_") || voice.hasPrefix("en_gb_"), voice)
        }
    }

    func testOnlyPartnersWithAVoiceAndAnInstalledModelSpeakInIt() {
        let voice = CoachNaturalVoice.shared
        // Atlas speaks in a Phonon voice, not a cloned one.
        XCTAssertNil(CoachNaturalVoice.voiceURL(for: "Atlas"))
        if voice.state == .ready {
            XCTAssertTrue(voice.canSpeak(as: "Ola"))
            XCTAssertEqual(voice.canSpeak(as: "Atlas"), CoachNaturalVoice.presetsSupported)
        } else if voice.state == .notInstalled, voice.downloadSize == "about 700 MB" {
            XCTAssertFalse(voice.canSpeak(as: "Ola"))
            XCTAssertFalse(voice.canSpeak(as: "Atlas"))
        }
        XCTAssertFalse(voice.canSpeak(as: "Someone else"))
    }

    func testTheModelLivesInItsOwnFolderUnderTheModelFolder() {
        let base = URL(fileURLWithPath: "/tmp/models", isDirectory: true)
        XCTAssertEqual(CoachNaturalVoice.folder(in: base).path, "/tmp/models/Coach voices")
    }
}
