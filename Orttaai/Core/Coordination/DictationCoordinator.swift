// DictationCoordinator.swift
// Orttaai

import Foundation
import AppKit
import CoreAudio
import os

@Observable
final class DictationCoordinator {
    enum State: Equatable {
        case idle
        case recording(startTime: Date)
        case processing(estimatedDuration: TimeInterval?)
        case injecting
        case error(message: String)

        static func == (lhs: State, rhs: State) -> Bool {
            switch (lhs, rhs) {
            case (.idle, .idle), (.injecting, .injecting):
                return true
            case (.recording(let a), .recording(let b)):
                return a == b
            case (.processing(let a), .processing(let b)):
                return a == b
            case (.error(let a), .error(let b)):
                return a == b
            default:
                return false
            }
        }
    }

    /// How the active recording is being driven. Push-to-talk is the classic
    /// hold-the-hotkey mode; hands-free keeps recording after the key is
    /// released (started by a tap) and stops on tap, stop button, sustained
    /// silence, or its own duration cap.
    enum RecordingMode: Equatable {
        case pushToTalk
        case handsFree
    }

    /// What the active session is for. A dictation session injects the
    /// transcript; an edit session treats the transcript as an instruction to
    /// apply to the selection captured when the session started.
    enum SessionKind: Equatable {
        case dictation
        case edit
    }

    var onStateChange: ((State, State?) -> Void)?

    static func resolvedInputDeviceID(from selectedAudioDeviceID: String?) -> AudioDeviceID? {
        guard let selectedAudioDeviceID else { return nil }
        let trimmed = selectedAudioDeviceID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let rawID = UInt32(trimmed), rawID != 0 else { return nil }
        return AudioDeviceID(rawID)
    }

    private(set) var state: State = .idle {
        didSet {
            guard state != oldValue else { return }
            onStateChange?(state, oldValue)
        }
    }
    private(set) var countdownSeconds: Int?
    /// Mode of the recording in progress. Only meaningful while `state` is
    /// `.recording`; reset to `.pushToTalk` whenever a new recording starts.
    private(set) var recordingMode: RecordingMode = .pushToTalk
    /// In-progress transcript assembled from the live session's clip commits
    /// and speculative tail decodes, for display while recording. Nil when no
    /// partial text is available (UI falls back to waveform-only). Kept up to
    /// date even while streaming into the field, so a mid-session fallback
    /// can show the full transcript accumulated so far.
    private(set) var liveTranscript: LiveTranscript?
    /// In-field streaming session for the recording in progress. Created only
    /// for dictation sessions when the setting is on; nil for edit sessions.
    private(set) var streamingSession: InFieldStreamingSession?
    /// True while committed words are being typed into the target field. The
    /// pill shows its compact waveform layout in this mode; any fallback
    /// flips this off and the pill transcript takes over.
    var isStreamingToField: Bool {
        streamingSession?.isStreaming ?? false
    }
    /// Kind of the session in progress. Only meaningful while a session is
    /// active (recording/processing/injecting); reset to `.dictation` when the
    /// session ends.
    private(set) var sessionKind: SessionKind = .dictation
    /// Selection captured at edit-session start; the edit result replaces it.
    private var editSelection: CapturedSelection?
    /// True while the edit shortcut's selection capture is in flight (before
    /// recording starts) so no other session can slip in underneath it.
    private(set) var isCapturingEditSelection = false

    private let audioService: any AudioCapturing
    private let transcriptionService: any Transcribing
    private let textProcessor: TextProcessor
    private let injectionService: any TextInjecting
    private let historyStore: any TranscriptionHistoryStoring
    private let settings: AppSettings
    /// Injectable clock for the tap/hold gesture logic so disambiguation is
    /// deterministic under test. Recording timing itself still uses `Date()`.
    private let now: () -> Date
    private var hotkeyGesture = HotkeyGestureInterpreter()
    /// Separate interpreter for the edit-command shortcut so its tap/hold
    /// state never crosses with the push-to-talk key's.
    private var editHotkeyGesture = HotkeyGestureInterpreter()
    /// Edit-key release that arrived while selection capture was still in
    /// flight; applied as soon as the edit recording starts.
    private var pendingEditGestureAction: HotkeyGestureInterpreter.ReleaseAction?
    private let selectionCapture: any SelectionCapturing
    private let editProcessor: any EditCommandProcessing
    /// Builds the in-field streaming session for a dictation recording.
    /// Injectable so tests can supply sessions backed by mock AX/keystroke
    /// seams; production uses the live seams.
    private let makeStreamingSession: (NSRunningApplication?) -> InFieldStreamingSession

    /// Push-to-talk is bounded by the user-set max duration; hands-free gets
    /// its own, much more generous cap.
    private var maxDuration: TimeInterval {
        switch recordingMode {
        case .pushToTalk:
            return TimeInterval(settings.maxRecordingDuration)
        case .handsFree:
            return TimeInterval(settings.handsFreeMaxRecordingDuration)
        }
    }
    /// The countdown (and its red warning treatment in the UI) covers the final
    /// 20 seconds of the recording window.
    static let countdownWarningWindowSeconds: TimeInterval = 20
    private var countdownStart: TimeInterval {
        max(0, maxDuration - Self.countdownWarningWindowSeconds)
    }
    private let minDuration: TimeInterval = 0.5
    private let liveDecodePollIntervalNs: UInt64 = 250_000_000

    private var capTimerTask: Task<Void, Never>?
    private var liveDecodeTask: Task<Void, Never>?
    private var processingTask: Task<Void, Never>?
    private var audioHealthTask: Task<Void, Never>?
    private var targetApp: NSRunningApplication?
    /// Single FIFO pipeline for live transcript events: the transcription
    /// actor yields into the stream (ordered), one MainActor task consumes.
    private var liveEventTask: Task<Void, Never>?
    private var liveEventContinuation: AsyncStream<LiveTranscriptEvent>.Continuation?

    /// History persistence policy: bounded retries, then a loud failure.
    static let historySaveAttempts = 3
    static let historySaveRetryDelayNs: UInt64 = 250_000_000 // 250ms

    init(
        audioService: any AudioCapturing,
        transcriptionService: any Transcribing,
        textProcessor: TextProcessor,
        injectionService: any TextInjecting,
        databaseManager: any TranscriptionHistoryStoring,
        settings: AppSettings,
        selectionCapture: (any SelectionCapturing)? = nil,
        editProcessor: (any EditCommandProcessing)? = nil,
        streamingSessionFactory: ((NSRunningApplication?) -> InFieldStreamingSession)? = nil,
        now: @escaping () -> Date = Date.init
    ) {
        self.audioService = audioService
        self.transcriptionService = transcriptionService
        self.textProcessor = textProcessor
        self.injectionService = injectionService
        self.historyStore = databaseManager
        self.settings = settings
        self.selectionCapture = selectionCapture ?? SelectionCaptureService()
        self.editProcessor = editProcessor ?? EditCommandProcessor(settings: settings)
        self.makeStreamingSession = streamingSessionFactory ?? { targetApp in
            InFieldStreamingSession(targetApp: targetApp)
        }
        self.now = now
    }

    var audioLevel: Float {
        audioService.audioLevel
    }

    var targetAppName: String? {
        guard let targetApp else { return nil }
        let name = targetApp.localizedName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return name.isEmpty ? nil : name
    }

    var recordingElapsedSeconds: Int? {
        guard case .recording(let startTime) = state else { return nil }
        return max(0, Int(Date().timeIntervalSince(startTime)))
    }

    /// True only while a hands-free recording is in progress.
    var isHandsFreeRecording: Bool {
        guard case .recording = state else { return false }
        return recordingMode == .handsFree
    }

    /// True while the active session is a voice edit command (recording the
    /// instruction, processing it, or injecting the result).
    var isEditSession: Bool {
        sessionKind == .edit
    }

    // MARK: - Hotkey gestures (tap vs hold)

    /// Key-down on the push-to-talk hotkey. Recording starts immediately on
    /// key-down in idle — tap/hold disambiguation never delays capture. While
    /// a hands-free recording is active, a key-down stops it (second tap).
    /// In processing/injecting/error the event is ignored.
    func handleHotkeyDown() {
        switch state {
        case .idle:
            hotkeyGesture.recordPress(at: now().timeIntervalSinceReferenceDate)
            startRecording()
            if case .recording = state {
                // Press armed; the matching key-up classifies tap vs hold.
            } else {
                // Recording failed to start — nothing for key-up to classify.
                hotkeyGesture.reset()
            }

        case .recording:
            if recordingMode == .handsFree, sessionKind == .dictation {
                // Second tap ends the hands-free session. The key-up that
                // follows finds no recorded press and is ignored.
                hotkeyGesture.reset()
                Logger.dictation.info("Hands-free recording stopped by hotkey tap")
                stopRecording()
            }
            // Push-to-talk key repeats are filtered by the caller; a stray
            // key-down while already recording push-to-talk is a no-op, and
            // the dictation key never disturbs an active edit session.

        case .processing, .injecting, .error:
            hotkeyGesture.reset()
            Logger.dictation.info("Ignoring hotkey down — busy (state: \(String(describing: self.state)))")
        }
    }

    /// Key-up on the push-to-talk hotkey. A quick release (tap) promotes the
    /// already-running recording to hands-free; a hold release stops it.
    func handleHotkeyUp() {
        let action = hotkeyGesture.evaluateRelease(
            at: now().timeIntervalSinceReferenceDate,
            handsFreeEnabled: settings.handsFreeModeEnabled
        )

        guard case .recording = state, recordingMode == .pushToTalk, sessionKind == .dictation else {
            // Recording already ended (error, cap, stop button), the key-up
            // belongs to a hands-free stop tap, or an edit session owns the
            // recording — nothing to do.
            return
        }

        applyGestureAction(action)
    }

    private func applyGestureAction(_ action: HotkeyGestureInterpreter.ReleaseAction) {
        switch action {
        case .promoteToHandsFree:
            promoteToHandsFree()
        case .stopRecording:
            stopRecording()
        case .ignore:
            break
        }
    }

    // MARK: - Edit-command hotkey (tap vs hold, mirrors push-to-talk)

    /// Key-down on the edit-command shortcut. In idle it captures the current
    /// selection and starts recording the spoken instruction; while a
    /// hands-free edit recording is active it stops it (second tap). Dictation
    /// sessions are never disturbed, and edit sessions never start while a
    /// dictation is recording or processing.
    func handleEditHotkeyDown() {
        guard settings.editCommandsEnabled else { return }

        switch state {
        case .idle:
            guard !isCapturingEditSelection else { return }
            editHotkeyGesture.recordPress(at: now().timeIntervalSinceReferenceDate)
            pendingEditGestureAction = nil
            startEditCommand()

        case .recording:
            if sessionKind == .edit, recordingMode == .handsFree {
                editHotkeyGesture.reset()
                Logger.dictation.info("Hands-free edit recording stopped by hotkey tap")
                stopRecording()
            }
            // A dictation recording owns the pipeline — the edit key is inert.

        case .processing, .injecting, .error:
            editHotkeyGesture.reset()
            Logger.dictation.info("Ignoring edit hotkey down — busy (state: \(String(describing: self.state)))")
        }
    }

    /// Key-up on the edit-command shortcut. Same tap/hold semantics as
    /// push-to-talk: tap promotes the instruction recording to hands-free,
    /// hold release stops it. A release that lands while selection capture is
    /// still in flight is deferred and applied once recording starts.
    func handleEditHotkeyUp() {
        let action = editHotkeyGesture.evaluateRelease(
            at: now().timeIntervalSinceReferenceDate,
            handsFreeEnabled: settings.handsFreeModeEnabled
        )

        if isCapturingEditSelection {
            pendingEditGestureAction = action
            return
        }

        guard case .recording = state, sessionKind == .edit, recordingMode == .pushToTalk else {
            return
        }

        applyGestureAction(action)
    }

    /// Captures the current selection in the frontmost app and, when one
    /// exists, starts recording the spoken edit instruction. No selection
    /// means a clear pill error and no recording.
    func startEditCommand() {
        guard settings.editCommandsEnabled else {
            Logger.dictation.info("Ignoring startEditCommand — edit commands disabled")
            return
        }
        guard case .idle = state, !isCapturingEditSelection else {
            Logger.dictation.info("Ignoring startEditCommand — busy (state: \(String(describing: self.state)))")
            return
        }

        isCapturingEditSelection = true
        // Capture the target app NOW, matching how dictation targets the app
        // that was focused when the user acted.
        let frontmostApp = NSWorkspace.shared.frontmostApplication

        Task { @MainActor [weak self] in
            guard let self else { return }
            let captureResult = await self.selectionCapture.captureSelection(
                processIdentifier: frontmostApp?.processIdentifier
            )
            self.isCapturingEditSelection = false

            guard case .idle = self.state else {
                self.pendingEditGestureAction = nil
                return
            }

            if case .blockedSecureField = captureResult {
                self.pendingEditGestureAction = nil
                self.editHotkeyGesture.reset()
                self.state = .error(message: "Can't edit password fields")
                self.autoDismissError()
                Logger.dictation.info("Edit command aborted — focused element is a secure field")
                return
            }

            guard case .captured(let selection) = captureResult,
                  !selection.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                self.pendingEditGestureAction = nil
                self.editHotkeyGesture.reset()
                self.state = .error(message: "Select text first")
                self.autoDismissError()
                Logger.dictation.info("Edit command aborted — no selection found")
                return
            }

            guard selection.text.count <= self.settings.clampedEditCommandMaxChars else {
                self.pendingEditGestureAction = nil
                self.editHotkeyGesture.reset()
                self.state = .error(message: "Selection too long to edit")
                self.autoDismissError()
                Logger.dictation.info("Edit command aborted — selection too long (\(selection.text.count) chars)")
                return
            }

            self.beginSession(kind: .edit, selection: selection, targetApp: frontmostApp)

            if let pending = self.pendingEditGestureAction {
                // The edit key was already released while capture ran.
                self.pendingEditGestureAction = nil
                if case .recording = self.state, self.recordingMode == .pushToTalk {
                    self.applyGestureAction(pending)
                }
            }
        }
    }

    // MARK: - Public API

    func startRecording() {
        guard !isCapturingEditSelection else {
            Logger.dictation.info("Ignoring startRecording — edit selection capture in flight")
            return
        }
        beginSession(kind: .dictation, selection: nil, targetApp: NSWorkspace.shared.frontmostApplication)
    }

    /// Shared session start for dictation and edit commands. The caller has
    /// already resolved the target app (and, for edits, the selection).
    private func beginSession(
        kind: SessionKind,
        selection: CapturedSelection?,
        targetApp frontmostApp: NSRunningApplication?
    ) {
        guard case .idle = state else {
            Logger.dictation.info("Ignoring startRecording — not idle (state: \(String(describing: self.state)))")
            return
        }

        recordingMode = .pushToTalk
        sessionKind = kind
        editSelection = selection
        // Edit sessions replace the selection at the end and never stream.
        streamingSession = (kind == .dictation && settings.inFieldStreamingEnabled)
            ? makeStreamingSession(frontmostApp)
            : nil

        do {
            // Capture the target app NOW, before the floating panel appears
            targetApp = frontmostApp
            let selectedDeviceID = Self.resolvedInputDeviceID(from: settings.selectedAudioDevice)
            try audioService.startCapture(deviceID: selectedDeviceID)
            state = .recording(startTime: Date())
            startCapTimer()
            startLiveDecodeLoop()
            startAudioHealthMonitor()
            if let selectedDeviceID {
                if let activeDeviceID = audioService.activeInputDeviceID, activeDeviceID != selectedDeviceID {
                    Logger.dictation.warning(
                        "Recording requested preferred input \(selectedDeviceID), but active input is \(activeDeviceID)"
                    )
                } else {
                    Logger.dictation.info("Recording started using preferred input device \(selectedDeviceID)")
                }
            } else if let activeDeviceID = audioService.activeInputDeviceID {
                Logger.dictation.info("Recording started using input device \(activeDeviceID)")
            } else {
                Logger.dictation.info("Recording started using system default input device")
            }
        } catch {
            state = .error(message: "Microphone access needed")
            endSessionContext()
            autoDismissError()
            Logger.dictation.error("Failed to start recording: \(error.localizedDescription)")
        }
    }

    /// Starts a recording that is hands-free from the outset (no key is held
    /// to release later). Used by the floating panel's mic button. Falls back
    /// to a plain recording when hands-free is disabled in settings.
    func startHandsFreeRecording() {
        startRecording()
        guard settings.handsFreeModeEnabled else { return }
        promoteToHandsFree()
    }

    /// Switches an in-progress push-to-talk recording to hands-free (tap
    /// gesture). Audio capture continues untouched; only the stop conditions
    /// change: the cap timer restarts against the hands-free budget and the
    /// silence auto-stop begins evaluating.
    private func promoteToHandsFree() {
        guard case .recording(let startTime) = state, recordingMode == .pushToTalk else { return }
        recordingMode = .handsFree
        capTimerTask?.cancel()
        countdownSeconds = nil
        startCapTimer(alreadyElapsed: Date().timeIntervalSince(startTime))
        Logger.dictation.info("Hands-free mode engaged")
    }

    func stopRecording() {
        guard case .recording(let startTime) = state else {
            Logger.dictation.info("Ignoring stopRecording — not recording")
            return
        }

        // Cancel cap timer
        capTimerTask?.cancel()
        capTimerTask = nil
        countdownSeconds = nil
        liveDecodeTask?.cancel()
        liveDecodeTask = nil
        audioHealthTask?.cancel()
        audioHealthTask = nil
        liveTranscript = nil
        finishLiveEventStream()
        Task { [transcriptionService] in
            await transcriptionService.setLiveTranscriptEventHandler(nil)
        }

        // Stop capture
        let samples = audioService.stopCapture()
        let duration = Date().timeIntervalSince(startTime)

        // Check minimum duration
        guard duration >= minDuration else {
            state = .idle
            endSessionContext()
            Task {
                await transcriptionService.cancelLiveTranscriptionSession()
            }
            historyStore.logSkippedRecording(duration: duration)
            Logger.dictation.info("Recording too short (\(duration, format: .fixed(precision: 2))s), skipping")
            return
        }

        let estimatedProcessing = estimateProcessingTime(duration)
        state = .processing(estimatedDuration: settings.showProcessingEstimate ? estimatedProcessing : nil)

        Logger.dictation.info("Recording stopped, duration: \(duration, format: .fixed(precision: 2))s, processing...")

        processingTask = Task { @MainActor [weak self] in
            guard let self = self else { return }
            await self.processRecording(samples: samples, recordingDurationMs: Int(duration * 1000))
        }
    }

    // MARK: - Private

    @MainActor
    private func processRecording(
        samples: [Float],
        recordingDurationMs: Int
    ) async {
        let appName = self.targetApp?.localizedName ?? NSWorkspace.shared.frontmostAppName
        let appBundleID = self.targetApp?.bundleIdentifier ?? NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let processingStart = CFAbsoluteTimeGetCurrent()
        var settingsSyncMs: Int?
        var transcriptionMs: Int?
        var textProcessingMs: Int?
        var injectionMs: Int?
        var injectionTelemetry: InjectionTelemetry?

        do {
            // Sync transcription settings before transcribing
            let settingsSyncStart = CFAbsoluteTimeGetCurrent()
            await syncTranscriptionSettings()
            settingsSyncMs = Int((CFAbsoluteTimeGetCurrent() - settingsSyncStart) * 1000)

            try await ensureTranscriptionModelLoaded()

            // Finalize using any speculative work started while recording.
            let transcriptionStart = CFAbsoluteTimeGetCurrent()
            let transcript = try await transcriptionService.finalizeLiveTranscription(audioSamples: samples)
            transcriptionMs = Int((CFAbsoluteTimeGetCurrent() - transcriptionStart) * 1000)

            // Edit sessions treat the transcript as the spoken instruction:
            // the polish/injection pipeline below is dictation-only.
            if sessionKind == .edit, let editSelection {
                await processEditInstruction(
                    rawInstruction: transcript,
                    selection: editSelection,
                    appName: appName,
                    appBundleID: appBundleID,
                    recordingDurationMs: recordingDurationMs,
                    settingsSyncMs: settingsSyncMs,
                    transcriptionMs: transcriptionMs,
                    processingStart: processingStart
                )
                return
            }

            // Process through text processor. Sessions that streamed text
            // into the field defer LLM polish: polish rewrites the whole
            // utterance, which would visibly delete and retype words the user
            // already watched land. Deterministic passes still apply and are
            // reconciled exactly at finalize.
            let didStreamText = !(streamingSession?.streamedText.isEmpty ?? true)
            let textProcessStart = CFAbsoluteTimeGetCurrent()
            let input = TextProcessorInput(
                rawTranscript: transcript,
                targetApp: appName,
                mode: .raw,
                deferPolish: didStreamText
            )
            let output = try await textProcessor.process(input)
            textProcessingMs = Int((CFAbsoluteTimeGetCurrent() - textProcessStart) * 1000)

            // Inject into the app that was focused when the user started
            // recording. Sessions that streamed reconcile the streamed span
            // to the final text instead of pasting the whole transcript.
            state = .injecting
            injectionService.lowLatencyModeEnabled = settings.lowLatencyModeEnabled
            let injectionStart = CFAbsoluteTimeGetCurrent()
            let result: InjectionResult
            if didStreamText, let streamingSession {
                switch await streamingSession.finalize(finalText: output.text) {
                case .completed:
                    injectionService.recordDeliveredTranscript(output.text)
                    result = .success(method: .streamed)
                case .failedNeedsManualPaste:
                    // The session left the final transcript on the clipboard;
                    // the streamed text stays untouched in the field.
                    result = .failedAllMethods
                case .notStreamed:
                    result = await injectionService.inject(text: output.text, targetApp: self.targetApp)
                    injectionTelemetry = injectionService.lastInjectionTelemetry
                }
            } else {
                result = await injectionService.inject(text: output.text, targetApp: self.targetApp)
                injectionTelemetry = injectionService.lastInjectionTelemetry
            }
            injectionMs = Int((CFAbsoluteTimeGetCurrent() - injectionStart) * 1000)

            let processingMs = Int((CFAbsoluteTimeGetCurrent() - processingStart) * 1000)

            let latency = DictationLatencyTelemetry(
                settingsSyncMs: settingsSyncMs,
                transcriptionMs: transcriptionMs,
                textProcessingMs: textProcessingMs,
                injectionMs: injectionMs,
                appActivationMs: injectionTelemetry?.appActivationMs,
                clipboardRestoreDelayMs: injectionTelemetry?.clipboardRestoreDelayMs
            )

            switch result {
            case .success(let method):
                let runtimeModelID = await transcriptionService.loadedModelID()
                let resolvedModelID: String = {
                    if let runtimeModelID, !runtimeModelID.isEmpty {
                        return runtimeModelID
                    }
                    let activeModelID = settings.activeModelId.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !activeModelID.isEmpty {
                        return activeModelID
                    }
                    return settings.selectedModelId
                }()
                settings.activeModelId = resolvedModelID

                persistTranscription(
                    text: output.text,
                    appName: appName,
                    bundleID: appBundleID,
                    recordingMs: recordingDurationMs,
                    processingMs: processingMs,
                    modelId: resolvedModelID,
                    latency: latency,
                    injectionMethod: method
                )
                maybeStartFastFirstPrefetch(afterSuccessfulDictationWith: resolvedModelID)
                state = .idle
                endSessionContext()
                Logger.dictation.info(
                    "Latency telemetry (ms): settings=\(settingsSyncMs ?? -1), transcribe=\(transcriptionMs ?? -1), process=\(textProcessingMs ?? -1), inject=\(injectionMs ?? -1), activate=\(injectionTelemetry?.appActivationMs ?? -1), restoreDelay=\(injectionTelemetry?.clipboardRestoreDelayMs ?? -1), pipeline=\(processingMs), method=\(method.rawValue)"
                )
                Logger.dictation.info("Dictation complete: \(output.text.prefix(50))... (\(processingMs)ms)")

            case .failedAllMethods:
                // Injection verifiably failed everywhere. The transcript is
                // already on the clipboard; record an honest failed entry and
                // tell the user instead of reporting silent success.
                persistTranscription(
                    text: output.text,
                    appName: appName,
                    bundleID: appBundleID,
                    recordingMs: recordingDurationMs,
                    processingMs: processingMs,
                    modelId: settings.activeModelId.isEmpty ? settings.selectedModelId : settings.activeModelId,
                    latency: latency,
                    injectionMethod: .failed
                )
                state = .error(message: "Couldn't insert text. Press Cmd+V to paste it.")
                endSessionContext()
                autoDismissError()

            case .blockedSecureField:
                state = .error(message: "Can't dictate into password fields")
                endSessionContext()
                autoDismissError()

            case .noTranscript:
                state = .error(message: "No transcript available to paste")
                endSessionContext()
                autoDismissError()
            }

        } catch {
            await transcriptionService.cancelLiveTranscriptionSession()
            Logger.dictation.error("Processing failed: \(error.localizedDescription)")
            state = .error(message: "Couldn't transcribe. Try again.")
            endSessionContext()
            autoDismissError()
        }
    }

    /// Clears per-session context once a session (dictation or edit) is over.
    private func endSessionContext() {
        targetApp = nil
        editSelection = nil
        sessionKind = .dictation
        streamingSession = nil
    }

    /// Applies the spoken instruction to the captured selection through the
    /// edit LLM and replaces the selection via the verified injection path.
    /// Every failure leaves the selection untouched and shows an honest pill
    /// error — a refusal or garbage response is never injected.
    @MainActor
    private func processEditInstruction(
        rawInstruction: String,
        selection: CapturedSelection,
        appName: String?,
        appBundleID: String?,
        recordingDurationMs: Int,
        settingsSyncMs: Int?,
        transcriptionMs: Int?,
        processingStart: CFAbsoluteTime
    ) async {
        let instruction = rawInstruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !instruction.isEmpty else {
            state = .error(message: "Didn't catch the instruction. Try again.")
            endSessionContext()
            autoDismissError()
            return
        }

        let editStart = CFAbsoluteTimeGetCurrent()
        let outcome = await editProcessor.performEdit(selection: selection.text, instruction: instruction)
        let editMs = Int((CFAbsoluteTimeGetCurrent() - editStart) * 1000)

        switch outcome {
        case .edited(let editedText):
            state = .injecting
            injectionService.lowLatencyModeEnabled = settings.lowLatencyModeEnabled
            let injectionStart = CFAbsoluteTimeGetCurrent()
            let result = await injectionService.inject(text: editedText, targetApp: targetApp)
            let injectionMs = Int((CFAbsoluteTimeGetCurrent() - injectionStart) * 1000)
            let injectionTelemetry = injectionService.lastInjectionTelemetry
            let processingMs = Int((CFAbsoluteTimeGetCurrent() - processingStart) * 1000)

            let latency = DictationLatencyTelemetry(
                settingsSyncMs: settingsSyncMs,
                transcriptionMs: transcriptionMs,
                textProcessingMs: editMs,
                injectionMs: injectionMs,
                appActivationMs: injectionTelemetry?.appActivationMs,
                clipboardRestoreDelayMs: injectionTelemetry?.clipboardRestoreDelayMs
            )
            let modelId = settings.activeModelId.isEmpty ? settings.selectedModelId : settings.activeModelId

            switch result {
            case .success(let method):
                persistEditCommand(
                    text: editedText,
                    instruction: instruction,
                    appName: appName,
                    bundleID: appBundleID,
                    recordingMs: recordingDurationMs,
                    processingMs: processingMs,
                    modelId: modelId,
                    latency: latency,
                    injectionMethod: method
                )
                state = .idle
                Logger.dictation.info(
                    "Edit command complete via \(method.rawValue) [selection=\(selection.method.rawValue), editMs=\(editMs), pipelineMs=\(processingMs)]"
                )
            case .failedAllMethods:
                persistEditCommand(
                    text: editedText,
                    instruction: instruction,
                    appName: appName,
                    bundleID: appBundleID,
                    recordingMs: recordingDurationMs,
                    processingMs: processingMs,
                    modelId: modelId,
                    latency: latency,
                    injectionMethod: .failed
                )
                state = .error(message: "Couldn't insert the edit. Press Cmd+V to paste it.")
                autoDismissError()
            case .blockedSecureField:
                state = .error(message: "Can't edit password fields")
                autoDismissError()
            case .noTranscript:
                state = .error(message: "Couldn't apply the edit")
                autoDismissError()
            }
            endSessionContext()

        case .unchanged:
            state = .error(message: "No changes needed")
            endSessionContext()
            autoDismissError()

        case .failed(let reason):
            // Honest failure: the selection in the target app is untouched.
            state = .error(message: reason)
            endSessionContext()
            autoDismissError()
        }
    }

    /// Persists an edit-command history entry with the same bounded-retry
    /// policy as dictation entries.
    private func persistEditCommand(
        text: String,
        instruction: String,
        appName: String?,
        bundleID: String?,
        recordingMs: Int,
        processingMs: Int,
        modelId: String,
        latency: DictationLatencyTelemetry,
        injectionMethod: InjectionMethod
    ) {
        let historyStore = self.historyStore
        Task.detached(priority: .utility) {
            let failure = await BoundedRetry.run(
                attempts: Self.historySaveAttempts,
                delayNs: Self.historySaveRetryDelayNs
            ) {
                try historyStore.saveEditCommandEntry(
                    text: text,
                    instruction: instruction,
                    appName: appName,
                    bundleID: bundleID,
                    recordingMs: recordingMs,
                    processingMs: processingMs,
                    modelId: modelId,
                    latency: latency,
                    injectionMethod: injectionMethod.rawValue
                )
            }
            guard let failure else { return }
            Logger.dictation.error(
                "Edit history save failed after \(failure.attempts) attempts: \(failure.lastError.localizedDescription, privacy: .public)"
            )
            await MainActor.run {
                NotificationCenter.default.post(name: .transcriptionHistorySaveDidFail, object: nil)
            }
        }
    }

    /// Persists a history entry with bounded retries. History persistence
    /// must never affect injection (the text is already delivered/on the
    /// clipboard) but must not vanish silently either: final failure logs an
    /// error and posts a user-visible breadcrumb.
    private func persistTranscription(
        text: String,
        appName: String?,
        bundleID: String?,
        recordingMs: Int,
        processingMs: Int,
        modelId: String,
        latency: DictationLatencyTelemetry,
        injectionMethod: InjectionMethod
    ) {
        let historyStore = self.historyStore
        Task.detached(priority: .utility) {
            let failure = await BoundedRetry.run(
                attempts: Self.historySaveAttempts,
                delayNs: Self.historySaveRetryDelayNs
            ) {
                try historyStore.saveTranscriptionEntry(
                    text: text,
                    appName: appName,
                    bundleID: bundleID,
                    recordingMs: recordingMs,
                    processingMs: processingMs,
                    modelId: modelId,
                    latency: latency,
                    injectionMethod: injectionMethod.rawValue
                )
            }
            guard let failure else { return }
            Logger.dictation.error(
                "History save failed after \(failure.attempts) attempts: \(failure.lastError.localizedDescription, privacy: .public)"
            )
            await MainActor.run {
                NotificationCenter.default.post(name: .transcriptionHistorySaveDidFail, object: nil)
            }
        }
    }

    // MARK: - Paste Last Transcript

    /// Re-injects the most recent transcript through the same verified
    /// injection path used for live dictation. Wired to the
    /// `.pasteLastTranscript` keyboard shortcut.
    func pasteLastTranscript() {
        guard case .idle = state else {
            Logger.dictation.info("Ignoring pasteLastTranscript — not idle (state: \(String(describing: self.state)))")
            return
        }

        // Capture the frontmost app now, matching how dictation targets the
        // app that was focused when the user acted.
        let frontmostApp = NSWorkspace.shared.frontmostApplication
        state = .injecting
        injectionService.lowLatencyModeEnabled = settings.lowLatencyModeEnabled

        Task { @MainActor [weak self] in
            guard let self else { return }
            let result = await self.injectionService.pasteLastTranscript(targetApp: frontmostApp)
            switch result {
            case .success(let method):
                Logger.dictation.info("Paste-last-transcript succeeded via \(method.rawValue)")
                self.state = .idle
            case .noTranscript:
                self.state = .error(message: "No transcript available to paste")
                self.autoDismissError()
            case .blockedSecureField:
                self.state = .error(message: "Can't dictate into password fields")
                self.autoDismissError()
            case .failedAllMethods:
                self.state = .error(message: "Couldn't insert text. Press Cmd+V to paste it.")
                self.autoDismissError()
            }
        }
    }

    @MainActor
    private func ensureTranscriptionModelLoaded() async throws {
        let isLoaded = await transcriptionService.isLoaded
        guard !isLoaded else { return }

        let selectedModelID = settings.selectedModelId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !selectedModelID.isEmpty else {
            throw OrttaaiError.modelNotLoaded
        }

        Logger.model.warning("Transcription model was not loaded at recording finalization; loading \(selectedModelID)")
        try await transcriptionService.loadModel(named: selectedModelID)
        let runtimeModelID = await transcriptionService.loadedModelID() ?? selectedModelID
        settings.activeModelId = runtimeModelID
        Logger.model.info("On-demand transcription model load complete: \(runtimeModelID)")
    }

    private func maybeStartFastFirstPrefetch(afterSuccessfulDictationWith activeModelId: String) {
        guard settings.fastFirstOnboardingEnabled else { return }
        guard !settings.fastFirstPrefetchStarted else { return }

        // Keep the exact variant id for the download; normalize only for the
        // same-family comparison (suffix-stripped ids are ambiguous targets).
        let recommendedModelId = settings.fastFirstRecommendedModelId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !recommendedModelId.isEmpty else { return }
        guard ModelManager.normalizedModelID(recommendedModelId) != ModelManager.normalizedModelID(activeModelId) else { return }

        settings.fastFirstPrefetchStarted = true
        settings.fastFirstPrefetchReady = false
        settings.fastFirstPrefetchErrorMessage = ""
        NotificationCenter.default.post(name: .fastFirstUpgradeAvailabilityDidChange, object: nil)

        Task.detached(priority: .utility) {
            let outcome = await ModelManager.prefetchModelIfNeeded(recommendedModelId)
            await MainActor.run {
                let appSettings = AppSettings()
                switch outcome {
                case .alreadyAvailable, .downloaded:
                    appSettings.fastFirstPrefetchReady = true
                    appSettings.fastFirstPrefetchErrorMessage = ""
                case .failed(let message):
                    appSettings.fastFirstPrefetchStarted = false
                    appSettings.fastFirstPrefetchErrorMessage = message
                }
                NotificationCenter.default.post(name: .fastFirstUpgradeAvailabilityDidChange, object: nil)
            }
        }
    }

    /// Bounds the recording at the mode-appropriate max duration, surfacing
    /// the countdown for the final warning window. `alreadyElapsed` accounts
    /// for recording time spent before a mode switch (tap promotion restarts
    /// the timer against the hands-free budget mid-recording).
    private func startCapTimer(alreadyElapsed: TimeInterval = 0) {
        capTimerTask = Task { @MainActor [weak self] in
            guard let self = self else { return }

            // Wait until the warning window begins
            let warningDelay = max(0, self.countdownStart - alreadyElapsed)
            try? await Task.sleep(nanoseconds: UInt64(warningDelay * 1_000_000_000))

            guard !Task.isCancelled else { return }

            let countdownFrom = max(self.countdownStart, alreadyElapsed)
            let remainingSeconds = Int((self.maxDuration - countdownFrom).rounded())
            for i in stride(from: remainingSeconds, through: 1, by: -1) {
                guard !Task.isCancelled else { return }
                self.countdownSeconds = i
                try? await Task.sleep(nanoseconds: 1_000_000_000) // 1 second
            }

            guard !Task.isCancelled else { return }

            // Time's up — stop recording
            Logger.dictation.info("Cap timer fired at \(self.maxDuration)s — stopping recording")
            self.stopRecording()
        }
    }

    private func startLiveDecodeLoop() {
        liveDecodeTask?.cancel()

        // Events flow through a single AsyncStream so delivery order is
        // guaranteed FIFO: the transcription actor yields synchronously in
        // emission order and one MainActor task consumes sequentially. (The
        // previous per-event `Task { @MainActor }` had no ordering guarantee.)
        finishLiveEventStream()
        let (stream, continuation) = AsyncStream.makeStream(of: LiveTranscriptEvent.self)
        liveEventContinuation = continuation
        liveEventTask = Task { @MainActor [weak self] in
            for await event in stream {
                guard let self else { break }
                self.applyLiveTranscriptEvent(event)
                // Streaming rides the same FIFO: each event is fully handled
                // (typed + verified) before the next, so increments can never
                // land out of order.
                await self.dispatchLiveEventToStreamingSession(event)
            }
        }

        liveDecodeTask = Task(priority: .userInitiated) { [weak self] in
            guard let self = self else { return }

            await self.syncTranscriptionSettings()
            // Snapshot the personal vocabulary once per session, before any
            // audio is decoded — the database is never touched from the
            // decode loop below.
            await self.transcriptionService.setVocabularyBias(terms: self.sessionVocabularyBiasTerms())
            guard !Task.isCancelled else { return }
            // Handler installed before the session begins so no early commit
            // or speculative result is missed.
            await self.transcriptionService.setLiveTranscriptEventHandler { event in
                continuation.yield(event)
            }
            guard !Task.isCancelled else { return }
            await self.transcriptionService.beginLiveTranscriptionSession()

            while !Task.isCancelled {
                let snapshot = self.audioService.currentSamplesSnapshot()
                await self.transcriptionService.processLiveAudioSnapshot(snapshot)
                // Hands-free silence auto-stop rides the same snapshot the
                // live decode already takes — no second audio analysis path.
                await MainActor.run {
                    self.evaluateHandsFreeAutoStopIfNeeded(samples: snapshot)
                }
                try? await Task.sleep(nanoseconds: self.liveDecodePollIntervalNs)
            }
        }
    }

    /// Stops a hands-free recording once the trailing silence reaches the
    /// user's configured window. Push-to-talk recordings are never affected.
    @MainActor
    private func evaluateHandsFreeAutoStopIfNeeded(samples: [Float]) {
        guard case .recording(let startTime) = state, recordingMode == .handsFree else { return }
        guard let silenceStop = settings.effectiveHandsFreeSilenceStopSeconds else { return }
        // Never race the minimum-duration guard: an auto-stop should always
        // produce a real finalization, not a skipped recording.
        guard Date().timeIntervalSince(startTime) >= minDuration else { return }
        guard HandsFreeAutoStop.shouldAutoStop(samples: samples, silenceDuration: silenceStop) else { return }

        Logger.dictation.info(
            "Hands-free auto-stop after \(silenceStop, format: .fixed(precision: 1))s of trailing silence"
        )
        stopRecording()
    }

    /// Ends the live event pipeline. The consumer task drains any buffered
    /// events and exits; events arriving after recording stops are dropped by
    /// `applyLiveTranscriptEvent`'s recording-state guard as before.
    private func finishLiveEventStream() {
        liveEventContinuation?.finish()
        liveEventContinuation = nil
        liveEventTask = nil
    }

    /// Checks that the audio tap is actually producing samples shortly after
    /// recording starts. If not (common after macOS sleep/wake when Core Audio
    /// silently goes stale), tears down the capture and retries once.
    private func startAudioHealthMonitor() {
        audioHealthTask?.cancel()
        audioHealthTask = Task { @MainActor [weak self] in
            // Allow time for the audio engine to start producing samples.
            try? await Task.sleep(nanoseconds: 800_000_000) // 800ms

            guard let self, case .recording = self.state else { return }

            let snapshot = self.audioService.currentSamplesSnapshot()
            if snapshot.isEmpty {
                Logger.dictation.warning("Audio health check failed — no samples after 800ms, attempting recovery")

                // Tear down the stale capture session.
                _ = self.audioService.stopCapture()

                // Brief delay for Core Audio to stabilize.
                try? await Task.sleep(nanoseconds: 500_000_000) // 500ms

                // User may have stopped recording in the meantime.
                guard case .recording = self.state else { return }

                do {
                    let selectedDeviceID = Self.resolvedInputDeviceID(from: self.settings.selectedAudioDevice)
                    try self.audioService.startCapture(deviceID: selectedDeviceID)
                    Logger.dictation.info("Audio capture recovered after health check")
                } catch {
                    Logger.dictation.error("Audio recovery failed: \(error.localizedDescription)")
                    self.capTimerTask?.cancel()
                    self.capTimerTask = nil
                    self.countdownSeconds = nil
                    self.liveDecodeTask?.cancel()
                    self.liveDecodeTask = nil
                    self.finishLiveEventStream()
                    self.liveTranscript = nil
                    self.state = .error(message: "Microphone unavailable. Try again.")
                    self.endSessionContext()
                    self.autoDismissError()
                }
            }
        }
    }

    /// Routes live events to the in-field streaming session. Commits stream
    /// their text at the caret; speculative events double as a cheap focus
    /// re-check so an app switch stops streaming within sub-second cadence.
    /// Events after recording ended are dropped — text committed but not yet
    /// streamed is delivered by finalize reconciliation instead.
    @MainActor
    private func dispatchLiveEventToStreamingSession(_ event: LiveTranscriptEvent) async {
        guard case .recording = state, let streamingSession else { return }
        switch event {
        case .committed(let text):
            await streamingSession.ingestCommit(text)
        case .speculative:
            streamingSession.refreshFocusGate()
        case .sessionBegan:
            break
        }
    }

    /// Folds a live transcript event into the display model. Events landing
    /// after recording ended (in-flight commits) are ignored — the final
    /// transcript comes from finalizeLiveTranscription, never from here.
    @MainActor
    private func applyLiveTranscriptEvent(_ event: LiveTranscriptEvent) {
        guard case .recording = state else { return }
        var transcript = liveTranscript ?? LiveTranscript()
        transcript.apply(event)
        liveTranscript = transcript.isEmpty ? nil : transcript
    }

    private func syncTranscriptionSettings() async {
        await settings.syncTranscriptionSettings(to: transcriptionService)
    }

    /// The vocabulary-bias snapshot for the session that is starting: active
    /// dictionary targets and snippet triggers, or nothing when the user has
    /// turned recognizer biasing off.
    private func sessionVocabularyBiasTerms() -> [String] {
        guard settings.vocabularyBiasEnabled else { return [] }
        guard let provider = textProcessor as? VocabularyBiasProviding else { return [] }
        return provider.vocabularyBiasTerms()
    }

    func estimateProcessingTime(_ recordingDuration: TimeInterval) -> TimeInterval {
        // Rough estimate: ~0.3x recording duration on M4, ~0.5x on M1
        let factor = 0.3
        return max(1.0, recordingDuration * factor)
    }

    private func autoDismissError() {
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000) // 2 seconds
            guard let self = self, case .error = self.state else { return }
            self.state = .idle
        }
    }
}
