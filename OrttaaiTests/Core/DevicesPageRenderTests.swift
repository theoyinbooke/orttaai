// DevicesPageRenderTests.swift
// OrttaaiTests
//
// Renders Settings › Devices with sample linked devices, for checking the
// layout. Writes PNGs only when ORTTAAI_RENDER_DIR is set.

import OrttaaiLink
import OrttaaiSyncCore
import SwiftUI
import XCTest
@testable import Orttaai

@MainActor
final class DevicesPageRenderTests: XCTestCase {
    func testRenderTheDevicesPage() throws {
        guard let directory = ProcessInfo.processInfo.environment["ORTTAAI_RENDER_DIR"] else {
            throw XCTSkip("Set ORTTAAI_RENDER_DIR to render the Devices page")
        }
        let now = Date()
        func device(_ id: String, _ kind: DeviceKind, _ name: String, app: String, version: String, seen: TimeInterval, tailnet: Bool) throws -> LinkedDevice {
            let json = """
            {"id":"\(id)","kind":"\(kind.rawValue)","name":"\(name)","app":"\(app)","appVersion":"\(version)","linkedAt":"\(ISO8601DateFormatter().string(from: now.addingTimeInterval(-86_400 * 3)))","lastSeen":"\(ISO8601DateFormatter().string(from: now.addingTimeInterval(-seen)))","viaTailnet":\(tailnet),"tokenHash":""}
            """
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(LinkedDevice.self, from: Data(json.utf8))
        }
        let devices = [
            try device("2f0c8a4e-7d21-4b9a-a3f6-5e8d9c1b0a42", .linux, "ThinkPad", app: "Orttaai", version: "0.4.0", seen: 120, tailnet: false),
            try device("9a3e5b71-0c4d-4f28-8e16-b2d7f4a9c053", .windows, "Studio PC", app: "Orttaai", version: "0.4.0", seen: 3_600, tailnet: true),
            try device("c47b2e90-5a13-4d6e-9f08-71e3a5d2b6c4", .android, "Pixel 10 Pro", app: "Orttakey", version: "1.0.0", seen: 40, tailnet: false),
        ]
        LinkController.shared.showPreview(devices: devices, totals: [
            devices[0].id: DeviceTotals(dictations: 128, words: 4_210, recordingMs: 1_920_000),
            devices[1].id: DeviceTotals(dictations: 37, words: 980, recordingMs: 610_000),
            devices[2].id: DeviceTotals(dictations: 12, words: 210, recordingMs: 95_000),
        ], tailscaleName: "mac-studio.tail1b0ba8.ts.net")

        render(DevicesSettingsView().padding(Spacing.xxl).frame(width: 880), named: "devices", in: directory)

        let session = LinkingSession(secret: "x", code: "482916", expires: now.addingTimeInterval(272))
        LinkController.shared.showPreview(devices: [], totals: [:], tailscaleName: "mac-studio.tail1b0ba8.ts.net", session: session,
                                          url: URL(string: "orttaai://link?v=1&id=6f1d1c9e-1b7a-4c55-9c39-0d3c1e2a7b10&n=Mac%20Studio&h=192.168.1.20,Mac-Studio.local&p=47821&fp=\(String(repeating: "ab", count: 32))&ts=mac-studio.tail1b0ba8.ts.net#x"))
        render(LinkDeviceSheet(link: LinkController.shared, onDone: {}), named: "link-sheet", in: directory)
    }

    private func render(_ content: some View, named prefix: String, in directory: String) {
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            NSApp?.appearance = NSAppearance(named: appearance)
            NSAppearance(named: appearance)?.performAsCurrentDrawingAppearance {
                let view = content
                    .background(Color.Orttaai.bgPrimary)
                    .environment(\.colorScheme, name == "dark" ? .dark : .light)
                let renderer = ImageRenderer(content: view)
                renderer.scale = 2
                if let image = renderer.nsImage, let tiff = image.tiffRepresentation,
                   let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                    try? png.write(to: URL(fileURLWithPath: directory).appending(path: "\(prefix)-\(name).png"))
                }
            }
        }
    }
}
