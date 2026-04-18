// AudioCaptureService.swift
// Orttaai

import AVFoundation
import CoreAudio
import CoreMedia
import os

protocol AudioCapturing: AnyObject {
    var audioLevel: Float { get }
    var activeInputDeviceID: AudioDeviceID? { get }
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
    private enum CaptureBackend {
        case idle
        case audioEngine
        case captureSession
    }

    private final class CaptureSessionOutputDelegate: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
        weak var owner: AudioCaptureService?
        let sessionID: UUID

        init(owner: AudioCaptureService, sessionID: UUID) {
            self.owner = owner
            self.sessionID = sessionID
        }

        func captureOutput(
            _ output: AVCaptureOutput,
            didOutput sampleBuffer: CMSampleBuffer,
            from connection: AVCaptureConnection
        ) {
            owner?.handleCaptureSessionSampleBuffer(sampleBuffer, sessionID: sessionID)
        }
    }

    private static let targetSampleRate = 16_000
    private static let maxSupportedRecordingDurationSeconds = 120
    private static let startupRetryDelays: [TimeInterval] = [0.0, 0.2, 0.5]
    private static let postWakeStartupRetryDelays: [TimeInterval] = [0.0, 0.25, 0.6, 1.0]
    private static let callbackHandshakeTimeout: TimeInterval = 0.55

    private(set) var audioLevel: Float = 0
    private(set) var activeInputDeviceID: AudioDeviceID?

    private var engine = AVAudioEngine()
    private struct ConverterState {
        var converter: AVAudioConverter?
        var sourceSampleRate: Double = 0
        var sourceChannelCount: AVAudioChannelCount = 0

        nonisolated mutating func converter(for sourceFormat: AVAudioFormat) -> AVAudioConverter? {
            let needsRefresh =
                converter == nil ||
                sourceSampleRate != sourceFormat.sampleRate ||
                sourceChannelCount != sourceFormat.channelCount

            if needsRefresh {
                converter = AVAudioConverter(from: sourceFormat, to: AudioCaptureService.whisperFormat)
                sourceSampleRate = sourceFormat.sampleRate
                sourceChannelCount = sourceFormat.channelCount
            }

            return converter
        }

        nonisolated mutating func reset() {
            converter = nil
            sourceSampleRate = 0
            sourceChannelCount = 0
        }
    }

    private let converterState = OSAllocatedUnfairLock(initialState: ConverterState())
    private let sampleQueue = DispatchQueue(label: "com.orttaai.samples")
    private var _samples: [Float] = []
    private let _currentLevel = OSAllocatedUnfairLock(initialState: Float(0))
    private let tapCallbackCount = OSAllocatedUnfairLock(initialState: UInt64(0))
    private let tapOutputFrameCount = OSAllocatedUnfairLock(initialState: UInt64(0))
    private let captureSessionID = OSAllocatedUnfairLock(initialState: UUID())
    private var levelTimer: DispatchSourceTimer?
    private let captureBufferSize: AVAudioFrameCount = 1024
    private let reservedSampleCapacity = AudioCaptureService.targetSampleRate * AudioCaptureService.maxSupportedRecordingDurationSeconds
    private var audioSystemMayBeStale = false
    private var tapInstalled = false
    private var captureBackend: CaptureBackend = .idle
    private var captureSession: AVCaptureSession?
    private var captureSessionDelegate: CaptureSessionOutputDelegate?
    private let captureOutputQueue = DispatchQueue(label: "com.orttaai.capture-session-output")

    /// Target format for WhisperKit: 16kHz mono Float32
    nonisolated private static let whisperFormat = AVAudioFormat(
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
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .denied, .restricted:
            throw OrttaaiError.microphoneAccessDenied
        default:
            break
        }

        let isPostWake = audioSystemMayBeStale
        audioSystemMayBeStale = false

        let retryDelays = isPostWake ? Self.postWakeStartupRetryDelays : Self.startupRetryDelays
        var lastError: Error = OrttaaiError.noAudioInput
        var attemptDeviceID = deviceID

        for (attemptIndex, delay) in retryDelays.enumerated() {
            if delay > 0 {
                Thread.sleep(forTimeInterval: delay)
            }

            do {
                try configureAndStartCapture(deviceID: attemptDeviceID)
                if attemptIndex > 0 {
                    Logger.audio.info("Audio capture recovered on retry attempt \(attemptIndex + 1)")
                }
                return
            } catch {
                lastError = error
                let mode = isPostWake ? "post-wake" : "normal"
                Logger.audio.warning(
                    "Audio start attempt \(attemptIndex + 1) (\(mode)) failed: \(error.localizedDescription)"
                )
                if attemptDeviceID != nil, deviceID == nil {
                    Logger.audio.warning("Preferred input failed startup handshake; retrying with system default")
                    attemptDeviceID = nil
                }
            }
        }

        throw lastError
    }

    private func configureAndStartCapture(deviceID: AudioDeviceID? = nil) throws {
        if let requestedDeviceID = deviceID, requestedDeviceID != 0 {
            guard Self.isInputDeviceAvailable(requestedDeviceID) else {
                Logger.audio.warning("Preferred input device \(requestedDeviceID) is unavailable")
                throw OrttaaiError.noAudioInput
            }

            do {
                try configureAndStartCaptureSession(deviceID: requestedDeviceID)
                return
            } catch {
                Logger.audio.warning(
                    "Capture-session path failed for device \(requestedDeviceID): \(error.localizedDescription). Falling back to AVAudioEngine."
                )
                try configureAndStartAudioEngine(deviceID: requestedDeviceID)
                return
            }
        }

        try configureAndStartAudioEngine(deviceID: nil)
    }

    private func configureAndStartAudioEngine(deviceID: AudioDeviceID? = nil) throws {
        teardownEngineState(clearSamples: true)
        engine = AVAudioEngine()
        captureBackend = .audioEngine

        let requestedDeviceID = deviceID ?? 0
        let defaultDeviceID = Self.defaultInputDeviceID()
        var activeDeviceID = defaultDeviceID

        if requestedDeviceID != 0 {
            guard Self.isInputDeviceAvailable(requestedDeviceID) else {
                Logger.audio.warning("Preferred input device \(requestedDeviceID) is unavailable")
                throw OrttaaiError.noAudioInput
            }
            guard bindInputDevice(requestedDeviceID) else {
                Logger.audio.warning("Could not activate preferred input device \(requestedDeviceID)")
                throw OrttaaiError.noAudioInput
            }
            activeDeviceID = requestedDeviceID
        }

        let inputNode = engine.inputNode
        let hwFormat = inputNode.outputFormat(forBus: 0)

        guard Self.isValidHardwareFormat(hwFormat) else {
            Logger.audio.error(
                "Invalid hardware format for input device \(activeDeviceID): \(hwFormat.channelCount) ch @ \(hwFormat.sampleRate) Hz"
            )
            throw OrttaaiError.noAudioInput
        }

        let activeDeviceName = Self.deviceName(for: activeDeviceID)
        activeInputDeviceID = activeDeviceID == 0 ? nil : activeDeviceID
        Logger.audio.info(
            "Hardware format: \(hwFormat.channelCount) ch, \(hwFormat.sampleRate) Hz, device: \(activeDeviceName)"
        )

        converterState.withLock { state in
            state.reset()
        }

        let sessionID = UUID()
        captureSessionID.withLock { current in
            current = sessionID
        }
        let initialCallbackCount = tapCallbackCount.withLock { $0 }
        let initialOutputFrameCount = tapOutputFrameCount.withLock { $0 }

        // Install tap using current hardware stream format.
        inputNode.installTap(onBus: 0, bufferSize: captureBufferSize, format: nil) { [weak self] buffer, _ in
            guard let self = self else { return }
            self.consumeCapturedBuffer(buffer, sessionID: sessionID)
        }
        tapInstalled = true

        do {
            engine.prepare()
            try engine.start()
        } catch {
            teardownEngineState(clearSamples: true)
            throw error
        }

        guard waitForInitialTapFrames(
            after: initialOutputFrameCount,
            timeout: Self.callbackHandshakeTimeout
        ) else {
            let callbackDelta = tapCallbackCount.withLock { current in
                current >= initialCallbackCount ? current - initialCallbackCount : 0
            }
            Logger.audio.warning(
                "Audio engine started but produced no converted frames (tap callbacks: \(callbackDelta))"
            )
            teardownEngineState(clearSamples: true)
            throw OrttaaiError.noAudioInput
        }

        startLevelTimer()

        Logger.audio.info("Audio capture started at hardware rate \(hwFormat.sampleRate) Hz, converting to 16 kHz")
    }

    private func configureAndStartCaptureSession(deviceID: AudioDeviceID) throws {
        teardownEngineState(clearSamples: true)
        captureBackend = .captureSession

        let deviceName = Self.deviceName(for: deviceID)
        guard let inputDevice = Self.captureDevice(for: deviceID) else {
            Logger.audio.error("No AVCaptureDevice matched selected input \(deviceID) (\(deviceName))")
            throw OrttaaiError.noAudioInput
        }

        let session = AVCaptureSession()
        session.beginConfiguration()

        let input = try AVCaptureDeviceInput(device: inputDevice)
        guard session.canAddInput(input) else {
            session.commitConfiguration()
            Logger.audio.error("Cannot add AVCapture input for device \(inputDevice.localizedName)")
            throw OrttaaiError.noAudioInput
        }
        session.addInput(input)

        let output = AVCaptureAudioDataOutput()
        output.audioSettings = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]

        guard session.canAddOutput(output) else {
            session.commitConfiguration()
            Logger.audio.error("Cannot add AVCapture audio output for device \(inputDevice.localizedName)")
            throw OrttaaiError.noAudioInput
        }
        session.addOutput(output)

        let sessionID = UUID()
        captureSessionID.withLock { current in
            current = sessionID
        }
        tapCallbackCount.withLock { $0 = 0 }
        tapOutputFrameCount.withLock { $0 = 0 }
        converterState.withLock { state in
            state.reset()
        }

        let delegate = CaptureSessionOutputDelegate(owner: self, sessionID: sessionID)
        output.setSampleBufferDelegate(delegate, queue: captureOutputQueue)

        session.commitConfiguration()

        captureSessionDelegate = delegate
        captureSession = session
        activeInputDeviceID = deviceID

        let initialOutputFrameCount = tapOutputFrameCount.withLock { $0 }
        session.startRunning()
        guard session.isRunning else {
            teardownEngineState(clearSamples: true)
            throw OrttaaiError.noAudioInput
        }

        guard waitForInitialTapFrames(
            after: initialOutputFrameCount,
            timeout: Self.callbackHandshakeTimeout
        ) else {
            Logger.audio.warning(
                "Capture session started for \(inputDevice.localizedName) but produced no converted frames"
            )
            teardownEngineState(clearSamples: true)
            throw OrttaaiError.noAudioInput
        }

        startLevelTimer()
        Logger.audio.info("Audio capture started via AVCaptureSession using device \(inputDevice.localizedName)")
    }

    func stopCapture() -> [Float] {
        teardownEngineState(clearSamples: false)

        let capturedSamples = sampleQueue.sync {
            let samples = _samples
            _samples.removeAll(keepingCapacity: true)
            return samples
        }

        _currentLevel.withLock { $0 = 0 }
        audioLevel = 0
        activeInputDeviceID = nil

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

    private func bindInputDevice(_ deviceID: AudioDeviceID) -> Bool {
        guard let audioUnit = engine.inputNode.audioUnit else { return false }

        func setCurrentDevice(_ id: AudioDeviceID) -> OSStatus {
            var mutableID = id
            return AudioUnitSetProperty(
                audioUnit,
                kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global,
                0,
                &mutableID,
                UInt32(MemoryLayout<AudioDeviceID>.size)
            )
        }

        func readCurrentDeviceID() -> AudioDeviceID? {
            var currentID: AudioDeviceID = 0
            var dataSize = UInt32(MemoryLayout<AudioDeviceID>.size)
            let status = AudioUnitGetProperty(
                audioUnit,
                kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global,
                0,
                &currentID,
                &dataSize
            )
            return status == noErr ? currentID : nil
        }

        let status = setCurrentDevice(deviceID)
        guard status == noErr else {
            Logger.audio.error("Failed to bind input device \(deviceID): \(status)")
            return false
        }

        if readCurrentDeviceID() == deviceID {
            return true
        }

        // When Core Audio gets into a stale state, bouncing through the system
        // default device can force a clean rebind without app/system restart.
        let fallbackDeviceID = Self.defaultInputDeviceID()
        if fallbackDeviceID != 0, fallbackDeviceID != deviceID {
            _ = setCurrentDevice(fallbackDeviceID)
            _ = setCurrentDevice(deviceID)
        }

        if readCurrentDeviceID() != deviceID {
            let activeDevice = readCurrentDeviceID() ?? 0
            Logger.audio.error(
                "Failed to verify requested input device \(deviceID); active device is \(activeDevice)"
            )
            return false
        }

        return true
    }

    private func teardownEngineState(clearSamples: Bool) {
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        engine.stop()
        if let captureSession {
            captureSession.stopRunning()
            self.captureSession = nil
        }
        captureSessionDelegate = nil
        captureBackend = .idle

        converterState.withLock { state in
            state.reset()
        }
        captureSessionID.withLock { current in
            current = UUID()
        }
        tapCallbackCount.withLock { $0 = 0 }
        tapOutputFrameCount.withLock { $0 = 0 }

        levelTimer?.cancel()
        levelTimer = nil

        _currentLevel.withLock { $0 = 0 }
        audioLevel = 0
        activeInputDeviceID = nil

        if clearSamples {
            sampleQueue.sync {
                _samples.removeAll(keepingCapacity: true)
                _samples.reserveCapacity(reservedSampleCapacity)
            }
        }
    }

    private func waitForInitialTapFrames(after count: UInt64, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let currentCount = tapOutputFrameCount.withLock { $0 }
            if currentCount > count {
                return true
            }
            Thread.sleep(forTimeInterval: 0.03)
        }
        return tapOutputFrameCount.withLock { $0 > count }
    }

    private func startLevelTimer() {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: 1.0 / 30.0)
        timer.setEventHandler { [weak self] in
            guard let self = self else { return }
            self.audioLevel = self._currentLevel.withLock { $0 }
        }
        timer.resume()
        levelTimer = timer
    }

    private static func isValidHardwareFormat(_ format: AVAudioFormat) -> Bool {
        format.sampleRate > 0 && format.channelCount > 0
    }

    private func handleCaptureSessionSampleBuffer(_ sampleBuffer: CMSampleBuffer, sessionID: UUID) {
        guard captureSessionID.withLock({ current in current == sessionID }) else { return }
        guard let sourceBuffer = Self.pcmBuffer(from: sampleBuffer) else { return }
        consumeCapturedBuffer(sourceBuffer, sessionID: sessionID)
    }

    private func consumeCapturedBuffer(_ buffer: AVAudioPCMBuffer, sessionID: UUID) {
        guard captureSessionID.withLock({ current in current == sessionID }) else { return }
        guard Self.isValidHardwareFormat(buffer.format) else { return }

        tapCallbackCount.withLock { count in
            count += 1
        }
        guard let converter = converterState.withLock({ state in
            state.converter(for: buffer.format)
        }) else { return }

        // Calculate output frame count with +1 margin for resampler rounding.
        let ratio = Self.whisperFormat.sampleRate / buffer.format.sampleRate
        let outputFrameCount = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1
        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: Self.whisperFormat,
            frameCapacity: outputFrameCount
        ) else { return }

        // Convert source audio -> 16kHz mono Float32.
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
              let channelData = outputBuffer.floatChannelData?[0]
        else { return }

        let frameLength = Int(outputBuffer.frameLength)
        if frameLength > 0 {
            tapOutputFrameCount.withLock { count in
                count += UInt64(frameLength)
            }
        }
        let samples = Array(UnsafeBufferPointer(start: channelData, count: frameLength))
        sampleQueue.async {
            self._samples.append(contentsOf: samples)
        }

        // Calculate RMS level from converted mono signal.
        var sum: Float = 0
        for i in 0..<frameLength {
            sum += channelData[i] * channelData[i]
        }
        let rms = sqrt(sum / Float(max(frameLength, 1)))
        let normalizedLevel = min(rms * 5.0, 1.0)
        _currentLevel.withLock { $0 = normalizedLevel }
    }

    private static func isInputDeviceAvailable(_ deviceID: AudioDeviceID) -> Bool {
        guard deviceID != 0 else { return false }

        var streamAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var streamDataSize: UInt32 = 0
        let streamStatus = AudioObjectGetPropertyDataSize(
            deviceID,
            &streamAddress,
            0,
            nil,
            &streamDataSize
        )
        guard streamStatus == noErr, streamDataSize > 0 else { return false }

        var aliveAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsAlive,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var alive: UInt32 = 1
        var aliveDataSize = UInt32(MemoryLayout<UInt32>.size)
        let aliveStatus = AudioObjectGetPropertyData(
            deviceID,
            &aliveAddress,
            0,
            nil,
            &aliveDataSize,
            &alive
        )
        guard aliveStatus == noErr else { return true }
        return alive != 0
    }

    private static func pcmBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let sourceASBDPointer = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)
        else {
            return nil
        }

        var sourceASBD = sourceASBDPointer.pointee
        guard let sourceFormat = AVAudioFormat(streamDescription: &sourceASBD) else {
            return nil
        }

        let frameCount = AVAudioFrameCount(max(0, CMSampleBufferGetNumSamples(sampleBuffer)))
        guard frameCount > 0,
              let sourceBuffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: frameCount)
        else {
            return nil
        }
        sourceBuffer.frameLength = frameCount

        let copyStatus = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer,
            at: 0,
            frameCount: Int32(frameCount),
            into: sourceBuffer.mutableAudioBufferList
        )
        guard copyStatus == noErr else { return nil }

        return sourceBuffer
    }

    private static func captureDevice(for deviceID: AudioDeviceID) -> AVCaptureDevice? {
        let discoverySession = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external],
            mediaType: .audio,
            position: .unspecified
        )
        let devices = discoverySession.devices
        guard !devices.isEmpty else { return nil }

        if let preferredUID = deviceUID(for: deviceID),
           let uidMatch = devices.first(where: { $0.uniqueID == preferredUID }) {
            return uidMatch
        }

        let preferredName = deviceName(for: deviceID).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !preferredName.isEmpty else { return nil }

        if let exact = devices.first(where: {
            $0.localizedName.caseInsensitiveCompare(preferredName) == .orderedSame
        }) {
            return exact
        }

        let lowerName = preferredName.lowercased()
        return devices.first(where: { device in
            let candidate = device.localizedName.lowercased()
            return candidate.contains(lowerName) || lowerName.contains(candidate)
        })
    }

    private static func deviceName(for deviceID: AudioDeviceID) -> String {
        guard deviceID != 0 else { return "Unknown" }

        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceNameCFString,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var unmanagedName: Unmanaged<CFString>?
        var dataSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(
            deviceID,
            &propertyAddress,
            0,
            nil,
            &dataSize,
            &unmanagedName
        )
        guard status == noErr else { return "Unknown" }
        return unmanagedName?.takeRetainedValue() as String? ?? "Unknown"
    }

    private static func deviceUID(for deviceID: AudioDeviceID) -> String? {
        guard deviceID != 0 else { return nil }

        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var unmanagedUID: Unmanaged<CFString>?
        var dataSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(
            deviceID,
            &propertyAddress,
            0,
            nil,
            &dataSize,
            &unmanagedUID
        )
        guard status == noErr else { return nil }
        return unmanagedUID?.takeRetainedValue() as String?
    }
}
