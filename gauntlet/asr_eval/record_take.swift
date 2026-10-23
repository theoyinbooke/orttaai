// Records one take from the Mac's current input device to a 16 kHz mono
// Float32 WAV, for record_real_corpus.py. AVAudioEngine converts whatever
// format the microphone delivers, and the tap is rebuilt if the device
// changes format mid-take (wireless microphones do), which ffmpeg's
// avfoundation input cannot follow.
//
//   swiftc -O record_take.swift -o record_take
//   record_take OUT.wav      # prints READY, records until a line arrives on stdin

import AVFoundation
import Foundation

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write("usage: record_take OUT.wav\n".data(using: .utf8)!)
    exit(2)
}

let outputURL = URL(fileURLWithPath: CommandLine.arguments[1])
let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
let engine = AVAudioEngine()
let lock = NSLock()
var outputFile: AVAudioFile? = try AVAudioFile(
    forWriting: outputURL,
    settings: targetFormat.settings,
    commonFormat: .pcmFormatFloat32,
    interleaved: false
)

func installTap() {
    let input = engine.inputNode
    let inputFormat = input.outputFormat(forBus: 0)
    guard inputFormat.sampleRate > 0, let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
        FileHandle.standardError.write("record_take: no usable input device\n".data(using: .utf8)!)
        exit(1)
    }
    input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { buffer, _ in
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * targetFormat.sampleRate / inputFormat.sampleRate) + 64
        guard let converted = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }
        var supplied = false
        var error: NSError?
        converter.convert(to: converted, error: &error) { _, status in
            if supplied { status.pointee = .noDataNow; return nil }
            supplied = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, converted.frameLength > 0 else { return }
        lock.lock()
        try? outputFile?.write(from: converted)
        lock.unlock()
    }
}

// A device or format change stops the engine; rebuild the tap for the new format and carry on.
NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { _ in
    engine.inputNode.removeTap(onBus: 0)
    installTap()
    try? engine.start()
    FileHandle.standardError.write("record_take: input changed, recording continues\n".data(using: .utf8)!)
}

installTap()
do {
    try engine.start()
} catch {
    FileHandle.standardError.write("record_take: could not start the microphone: \(error)\n".data(using: .utf8)!)
    exit(1)
}
print("READY")
fflush(stdout)

_ = readLine()
engine.inputNode.removeTap(onBus: 0)
engine.stop()
lock.lock()
outputFile = nil  // closes and finalizes the WAV header
lock.unlock()
