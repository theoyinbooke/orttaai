// SoundAnchorOwnVoiceTests.swift
// OrttaaiTests
//
// The sound anchors on the owner's own voice, through the Mac's real Express
// path. Opt-in (ORTTAAI_SOUND_OWN=1): it needs the models and recordings on
// the external drive.
//   ORTTAAI_SOUND_OWN_RECORDINGS  folder with manifest.json and the 16 wav
//                                 files (Orttakey's record_own_voice.py)
//   ORTTAAI_SOUND_MODEL_ROOT      folder holding FluidVoice-Labs/fluid-speech-
//                                 mini-coreml and FluidInference/parakeet-ctc-
//                                 110m-coreml
//   ORTTAAI_SOUND_REAL_CORPUS     optional: the 50 real-voice clips, which must
//                                 not change with the anchor on

import AVFoundation
import XCTest
@testable import Orttaai

@available(macOS 15, *)
final class SoundAnchorOwnVoiceTests: XCTestCase {
    private struct Item: Decodable {
        let id: String
        let said: String
        let reference: String
    }

    private struct Manifest: Decodable {
        let items: [Item]
    }

    func testYourVoiceEimailarAndEmail() async throws {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["ORTTAAI_SOUND_OWN"] == "1", "opt-in: ORTTAAI_SOUND_OWN=1")
        let recordings = URL(fileURLWithPath: env["ORTTAAI_SOUND_OWN_RECORDINGS"] ?? "/Volumes/MyExtSSD/Developer/OwnVoice/orttakey-sound")
        let root = URL(fileURLWithPath: env["ORTTAAI_SOUND_MODEL_ROOT"] ?? "/Volumes/MyExtSSD/Huggingface/models")
        let transcriber = try await ExpressTranscriber.load(
            from: root.appendingPathComponent("FluidVoice-Labs/fluid-speech-mini-coreml"),
            wordBoostFolder: root.appendingPathComponent("FluidInference/parakeet-ctc-110m-coreml")
        )
        let terms = [WordBoostTerm(text: "Eimailar", aliases: [])]
        _ = await transcriber.setWordBoost(terms)
        let items = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: recordings.appendingPathComponent("manifest.json"))).items
        let store = SoundAnchorStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json"))
        var book = SoundAnchorBook()
        var fixed: String?
        var taught = Set<String>()
        var report: [String] = []
        let guesses = SoundAnchorGuesses.anchors(for: ["Eimailar"])
        report.append("guesses: \(guesses.map { "\($0.heard)->\($0.term) \($0.sounds)" }), lexicon \(EnglishLexicon.isAvailable)")

        for stage in ["before any fix", "after one fix", "after one fix and 3 kept emails"] {
            if stage == "after one fix and 3 kept emails" {
                for id in ["word-01", "word-02", "word-03"] {
                    await transcriber.setSoundAnchors(book.adding(SoundAnchorBook(SoundAnchorGuesses.anchors(for: ["Eimailar"]))))
                    _ = try await transcriber.transcribe(try Self.samples(recordings.appendingPathComponent(id + ".wav")))
                    for decision in await transcriber.soundDecisions() where !decision.applied {
                        book.learnNotSaid(heard: decision.heard, term: decision.term, margin: decision.margin)
                    }
                    taught.insert(id)
                }
            }
            await transcriber.setSoundAnchors(book.adding(SoundAnchorBook(SoundAnchorGuesses.anchors(for: ["Eimailar"]))))
            report.append("state \(await transcriber.soundState())")
            var right = 0, said = 0, changed = 0, plain = 0
            var firstWrong: (Item, [Float], String)?
            for item in items where item.id != fixed && !taught.contains(item.id) {
                let samples = try Self.samples(recordings.appendingPathComponent(item.id + ".wav"))
                let text = try await transcriber.transcribe(samples)
                let shown = text.contains("Eimailar")
                let scores = await transcriber.soundDecisions().map { "\($0.heard)\($0.applied ? "+" : " kept ")\($0.margin)" }
                report.append("  \(stage) \(item.id) [\(item.said)] «\(text)» \(scores)")
                if item.said == "term" {
                    said += 1
                    if shown { right += 1 } else if firstWrong == nil { firstWrong = (item, samples, text) }
                } else {
                    plain += 1
                    if shown { changed += 1 }
                }
            }
            report.append("\(stage): Eimailar shown \(right)/\(said), plain email changed \(changed)/\(plain)")
            XCTAssertEqual(changed, 0, "plain email must stay email (\(stage))")
            if stage == "before any fix", let (item, samples, text) = firstWrong,
               let heard = text.split(separator: " ").map(String.init).first(where: { SoundContrast.key($0).joined().hasPrefix("email") }),
               let learned = try await transcriber.learnSound(from: samples, heard: heard, term: "Eimailar", occurrence: 0) {
                book.learnSaid(heard: heard, term: "Eimailar", sounds: learned.sounds, margin: learned.margin)
                store.update { $0 = book }
                fixed = item.id
            }
        }

        if let corpus = env["ORTTAAI_SOUND_REAL_CORPUS"], env["ORTTAAI_SOUND_SKIP_CORPUS"] != "1" {
            let folder = URL(fileURLWithPath: corpus)
            var changedClips = 0
            let files = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasSuffix(".wav") }
            for name in files {
                let samples = try Self.samples(folder.appendingPathComponent(name))
                await transcriber.setSoundAnchors(SoundAnchorBook())
                let plainText = try await transcriber.transcribe(samples)
                await transcriber.setSoundAnchors(book.adding(SoundAnchorBook(SoundAnchorGuesses.anchors(for: ["Eimailar"]))))
                let anchoredText = try await transcriber.transcribe(samples)
                if anchoredText != plainText {
                    changedClips += 1
                    let scores = await transcriber.soundDecisions().map { "\($0.heard)\($0.applied ? "+" : " kept ")\($0.margin)" }
                    report.append("  corpus \(name): «\(plainText)» → «\(anchoredText)» \(scores)")
                }
            }
            report.append("real-voice corpus: \(changedClips) of \(files.count) transcripts changed by the anchor")
            XCTAssertEqual(changedClips, 0, report.joined(separator: "\n"))
        }
        let text = "SOUND OWN VOICE\n" + report.joined(separator: "\n")
        if let path = env["ORTTAAI_SOUND_REPORT"] { try? text.write(toFile: path, atomically: true, encoding: .utf8) }
        print(text)
    }

    private static func samples(_ file: URL) throws -> [Float] {
        let audio = try AVAudioFile(forReading: file, commonFormat: .pcmFormatFloat32, interleaved: false)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: audio.processingFormat, frameCapacity: AVAudioFrameCount(audio.length)) else { return [] }
        try audio.read(into: buffer)
        guard let channel = buffer.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
    }
}
