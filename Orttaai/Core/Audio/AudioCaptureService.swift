// AudioCaptureService.swift
// Orttaai

import AVFoundation
import CoreAudio
import os

protocol AudioCapturing: AnyObject {
    var audioLevel: Float { get }
    func startCapture(deviceID: AudioDeviceID?) throws
    func stopCapture() -> [Float]
    func currentSamplesSnapshot() -> [Float]
}

extension AudioCapturing {
    func startCapture() throws {
        try startCapture(deviceID: nil)
    }
}

@Observable
final class AudioCaptureService: AudioCapturing {
    private static let targetSampleRate = 16_000
    private static let maxSupportedRecordingDurationSeconds = 120

    private(set) var audioLevel: Float = 0

    private var engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private let sampleQueue = DispatchQueue(label: "com.orttaai.samples")
    private var _samples: [Float] = []
    private let _currentLevel = OSAllocatedUnfairLock(initialState: Float(0))
    private var levelTimer: DispatchSourceTimer?
    private let captureBufferSize: AVAudioFrameCount = 1024
    private let reservedSampleCapacity = AudioCaptureService.targetSampleRate * AudioCaptureService.maxSupportedRecordingDurationSeconds
    private var audioSystemMayBeStale = false

    /// Target format for WhisperKit: 16kHz mono Float32
    private static let whisperFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: Double(targetSampleRate),
        channels: 1,
        interleaved: false
    )!

    /// Called by AppDelegate when the system wakes from sleep so the next
    /// capture attempt knows Core Audio may need extra time to re-initialize.
    func markAudioSystemStale() {
        audioSystemMayBeStale = true
        Logger.audio.info("Audio subsystem marked for revalidation (system wake)")
    }

    func startCapture(deviceID: AudioDeviceID? = nil) throws {
        let isPostWake = audioSystemMayBeStale
        audioSystemMayBeStale = false

        do {
            try configureAndStartEngine(deviceID: deviceID)
        } catch {
            guard isPostWake else { throw error }
            // After system wake, Core Audio may need time to re-initialize.
            // Wait briefly and retry once before surfacing the error.
            Logger.audio.warning("Audio start failed post-wake, retrying after delay: \(error.localizedDescription)")
            Thread.sleep(forTimeInterval: 0.5)
            try configureAndStartEngine(deviceID: deviceID)
            Logger.audio.info("Post-wake audio retry succeeded")
        }
    }

    private func configureAndStartEngine(deviceID: AudioDeviceID? = nil) throws {
        // Recreate engine each session to avoid stale state after previous stops/crashes
        engine = AVAudioEngine()
        sampleQueue.sync {
            _samples.removeAll(keepingCapacity: true)
            _samples.reserveCapacity(reservedSampleCapacity)
        }

        let resolvedDeviceID = deviceID ?? Self.defaultInputDeviceID()
        if resolvedDeviceID != 0 {
            let audioUnit = engine.inputNode.audioUnit!
            var id = resolvedDeviceID
            let status = AudioUnitSetProperty(
                audioUnit,
                kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global,
                0,
                &id,
                UInt32(MemoryLayout<AudioDeviceID>.size)
            )
            guard status == noErr else {
                Logger.audio.error("Failed to bind input device \(resolvedDeviceID): \(status)")
                throw OrttaaiError.noAudioInput
            }
        }

        let inputNode = engine.inputNode
        let hwFormat = inputNode.outputFormat(forBus: 0)

        // Validate that we have a real audio device
        guard hwFormat.sampleRate > 0 else {
            throw OrttaaiError.noAudioInput
        }

        let activeDeviceName = Self.deviceName(for: resolvedDeviceID)
        Logger.audio.info(
            "Hardware format: \(hwFormat.channelCount) ch, \(hwFormat.sampleRate) Hz, device: \(activeDeviceName)"
        )

        // Create converter from hardware format → 16kHz mono
        guard let conv = AVAudioConverter(from: hwFormat, to: Self.whisperFormat) else {
            throw OrttaaiError.noAudioInput
        }
        converter = conv

        // Install tap at HARDWARE format — AVAudioEngine input taps do not support format conversion
        inputNode.installTap(onBus: 0, bufferSize: captureBufferSize, format: hwFormat) { [weak self] buffer, _ in
            guard let self = self, let converter = self.converter else { return }

            // Reset converter state so residual samples from the previous callback
            // don't corrupt this block (critical for sample-rate conversion)
            converter.reset()

            // Calculate output frame count with +1 margin for resampler rounding
            let ratio = Self.whisperFormat.sampleRate / buffer.format.sampleRate
            let outputFrameCount = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1
            guard let outputBuffer = AVAudioPCMBuffer(
                pcmFormat: Self.whisperFormat,
                frameCapacity: outputFrameCount
            ) else { return }

            // Convert hardware audio → 16kHz mono
            var error: NSError?
            var hasData = true
            let status = converter.convert(to: outputBuffer, error: &error) { _, outStatus in
                if hasData {
                    hasData = false
                    outStatus.pointee = .haveData
                    return buffer
                }
                outStatus.pointee = .noDataNow
                return nil
            }

            guard status != .error, error == nil,
                  let channelData = outputBuffer.floatChannelData?[0] else { return }

            let frameLength = Int(outputBuffer.frameLength)
            let samples = Array(UnsafeBufferPointer(start: channelData, count: frameLength))

            self.sampleQueue.async {
                self._samples.append(contentsOf: samples)
            }

            // Calculate RMS level from converted mono signal
            var sum: Float = 0
            for i in 0..<frameLength {
                sum += channelData[i] * channelData[i]
            }
            let rms = sqrt(sum / Float(max(frameLength, 1)))
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

        Logger.audio.info("Audio capture started at hardware rate \(hwFormat.sampleRate) Hz, converting to 16 kHz")
    }

    func stopCapture() -> [Float] {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()

        converter?.reset()
        converter = nil

        levelTimer?.cancel()
        levelTimer = nil

        let capturedSamples = sampleQueue.sync {
            let samples = _samples
            _samples.removeAll(keepingCapacity: true)
            return samples
        }

        _currentLevel.withLock { $0 = 0 }
        audioLevel = 0

        Logger.audio.info("Audio capture stopped, \(capturedSamples.count) samples collected")
        return capturedSamples
    }

    func currentSamplesSnapshot() -> [Float] {
        sampleQueue.sync { _samples }
    }

    private static func defaultInputDeviceID() -> AudioDeviceID {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID: AudioDeviceID = 0
        var dataSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &dataSize,
            &deviceID
        )
        return status == noErr ? deviceID : 0
    }

    private static func deviceName(for deviceID: AudioDeviceID) -> String {
        guard deviceID != 0 else { return "Unknown" }

        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceNameCFString,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var name: CFString = "" as CFString
        var dataSize = UInt32(MemoryLayout<CFString>.size)
        let status = AudioObjectGetPropertyData(
            deviceID,
            &propertyAddress,
            0,
            nil,
            &dataSize,
            &name
        )
        return status == noErr ? name as String : "Unknown"
    }
}
