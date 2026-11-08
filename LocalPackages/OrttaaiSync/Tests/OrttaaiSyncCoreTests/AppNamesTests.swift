// AppNamesTests.swift
// OrttaaiSyncCoreTests

import Foundation
import Testing
@testable import OrttaaiSyncCore

@Suite("One name per app across devices")
struct AppNamesTests {
    struct Sample: Decodable {
        var raw: String?
        var display: String
    }

    @Test func everySampleGetsItsName() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Fixtures/app-names.json")
        let samples = try JSONDecoder().decode([Sample].self, from: Data(contentsOf: url))
        #expect(samples.count > 20)
        for sample in samples {
            #expect(AppNames.display(sample.raw) == sample.display, "\(sample.raw ?? "nil")")
        }
    }

    @Test func theMacsNameAndThePCsProgramAreOneApp() {
        #expect(AppNames.display("Google Chrome") == AppNames.display("chrome"))
        #expect(AppNames.display("Obsidian") == AppNames.display("obsidian"))
    }
}
