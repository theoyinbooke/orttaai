// SlowListen.swift
// Orttaai (ported from Orttakey)
//
// Sound slowed down with its pitch kept, for listening again to a word the
// speech model may have heard too fast ("emailer" written "email").

import AVFoundation

nonisolated enum SlowListen {
    /// 16 kHz mono samples played at `rate` (0.6 = 60% of the speed) through
    /// AVAudioUnitTimePitch, rendered offline: no audio session, no device.
    static func stretched(_ samples: [Float], rate: Float) -> [Float]? {
        guard !samples.isEmpty, let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else { return nil }
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        let pitch = AVAudioUnitTimePitch()
        pitch.rate = rate
        engine.attach(player)
        engine.attach(pitch)
        engine.connect(player, to: pitch, format: format)
        engine.connect(pitch, to: engine.mainMixerNode, format: format)
        do {
            try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4096)
            try engine.start()
        } catch {
            return nil
        }
        defer { engine.stop() }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { pointer in
            if let base = pointer.baseAddress { buffer.floatChannelData?[0].update(from: base, count: samples.count) }
        }
        player.scheduleBuffer(buffer, completionHandler: nil)
        player.play()
        guard let chunk = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: 4096) else { return nil }
        let total = Int(Double(samples.count) / Double(rate)) + 2048
        var out: [Float] = []
        out.reserveCapacity(total)
        while out.count < total {
            guard (try? engine.renderOffline(4096, to: chunk)) == .success, let data = chunk.floatChannelData?[0] else { break }
            out += UnsafeBufferPointer(start: data, count: Int(chunk.frameLength))
        }
        return out
    }
}
