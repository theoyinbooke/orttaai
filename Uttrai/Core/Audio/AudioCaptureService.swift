// AudioCaptureService.swift
// Uttrai

import AVFoundation
import os

@Observable
final class AudioCaptureService {
    private(set) var audioLevel: Float = 0

    private var engine = AVAudioEngine()
    private let sampleQueue = DispatchQueue(label: "com.uttrai.samples")
    private var _samples: [Float] = []
    private let _currentLevel = OSAllocatedUnfairLock(initialState: Float(0))
    private var levelTimer: DispatchSourceTimer?

    func startCapture(deviceID: AudioDeviceID? = nil) throws {
        // Set specific audio device if provided
        if let deviceID = deviceID {
            let audioUnit = engine.inputNode.audioUnit!
            var id = deviceID
            AudioUnitSetProperty(
                audioUnit,
                kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global,
                0,
                &id,
                UInt32(MemoryLayout<AudioDeviceID>.size)
            )
        }

        let inputNode = engine.inputNode
        let tapFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16000,
            channels: 1,
            interleaved: false
        )!

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: tapFormat) { [weak self] buffer, _ in
            guard let self = self else { return }
            let channelData = buffer.floatChannelData![0]
            let frameLength = Int(buffer.frameLength)
            let samples = Array(UnsafeBufferPointer(start: channelData, count: frameLength))

            self.sampleQueue.async {
                self._samples.append(contentsOf: samples)
            }

            // Calculate RMS level
            var sum: Float = 0
            for i in 0..<frameLength {
                sum += channelData[i] * channelData[i]
            }
            let rms = sqrt(sum / Float(frameLength))
            let normalizedLevel = min(rms * 5.0, 1.0) // Scale up for visual display

            self._currentLevel.withLock { $0 = normalizedLevel }
        }

        // Start 30fps level timer on main queue
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: 1.0 / 30.0)
        timer.setEventHandler { [weak self] in
            guard let self = self else { return }
            self.audioLevel = self._currentLevel.withLock { $0 }
        }
        timer.resume()
        levelTimer = timer

        engine.prepare()
        try engine.start()

        Logger.audio.info("Audio capture started")
    }

    func stopCapture() -> [Float] {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()

        levelTimer?.cancel()
        levelTimer = nil

        let capturedSamples = sampleQueue.sync {
            let samples = _samples
            _samples.removeAll()
            return samples
        }

        _currentLevel.withLock { $0 = 0 }
        audioLevel = 0

        Logger.audio.info("Audio capture stopped, \(capturedSamples.count) samples collected")
        return capturedSamples
    }
}
