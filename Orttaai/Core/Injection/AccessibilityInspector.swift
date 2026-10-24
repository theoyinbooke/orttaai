// AccessibilityInspector.swift
// Orttaai

import Cocoa
import ApplicationServices
import os

/// Attributes of the focused UI element that drive the secure-field decision.
nonisolated struct FocusedElementDetails: Equatable, Sendable {
    var role: String?
    var subrole: String?
    var roleDescription: String?
}

/// Selection range of the focused element in UTF-16 units, as AX reports it.
/// A zero-length range is the caret position.
nonisolated struct FocusedTextRange: Equatable, Sendable {
    var location: Int
    var length: Int
}

/// Text content of the focused UI element, read for paste verification.
nonisolated struct FocusedTextSnapshot: Equatable, Sendable {
    /// kAXValueAttribute as a string, nil when the element exposes no value.
    var value: String?
    /// kAXSelectedTextAttribute, nil when unsupported.
    var selectedText: String?
    /// kAXSelectedTextRangeAttribute, nil when unsupported.
    var selectedRange: FocusedTextRange?

    init(value: String? = nil, selectedText: String? = nil, selectedRange: FocusedTextRange? = nil) {
        self.value = value
        self.selectedText = selectedText
        self.selectedRange = selectedRange
    }
}

/// One read of the focused text field, for learning from the user's edits.
nonisolated struct FocusedFieldRead: Equatable, Sendable {
    /// Identifies the element, so a later read can tell the user moved on to
    /// a different field.
    var elementID: Int
    /// Password and other secure fields are never read.
    var isSecure: Bool
    var text: String?
    /// End of the selection (the caret) in UTF-16 units.
    var caretUTF16: Int?
}

protocol FocusedFieldReading: AnyObject {
    /// Asks the app to expose its text fields, ahead of the reads. Called when
    /// recording starts, so the app has the whole recording to get ready.
    func prepareToRead(_ app: NSRunningApplication)
    /// The focused element of the app, or nil when Accessibility can't read it.
    func readFocusedField(processIdentifier: pid_t) -> FocusedFieldRead?
    /// Calls `onChange` with the field's new text each time the app's focused
    /// field changes its value (nil when that read fails or the field goes
    /// away), for as long as the returned token is kept. Nil when the field
    /// can't be observed; callers then rely on their own reads.
    func observeFocusedField(processIdentifier: pid_t, onChange: @escaping (String?) -> Void) -> AnyObject?
}

extension FocusedFieldReading {
    func prepareToRead(_ app: NSRunningApplication) {}

    func observeFocusedField(processIdentifier: pid_t, onChange: @escaping (String?) -> Void) -> AnyObject? {
        nil
    }
}

/// Chromium keeps a page out of Accessibility until an assistive app asks for
/// it, so the text boxes of Electron apps (Claude, Slack, T3 Code) and of
/// Chrome-based apps (Chrome, ChatGPT) read as nothing: no focused element,
/// no text. Electron apps take `AXManualAccessibility`; Chrome-based apps
/// only `AXEnhancedUserInterface`, the switch VoiceOver uses. Native apps
/// need neither and are left alone. The switch is set again before every
/// dictation, since Chromium can turn an idle tree back off, and is never
/// turned off: VoiceOver or another assistive app may rely on it.
nonisolated enum ChromiumAccessibility {
    nonisolated enum Engine: Equatable, Sendable {
        case electron
        case chromium
        case other
    }

    static let manualAttribute = "AXManualAccessibility"
    static let enhancedAttribute = "AXEnhancedUserInterface"

    /// Code editors that change how they behave when Accessibility comes on
    /// (VS Code switches to screen reader mode), so they are never switched.
    static let excludedBundleIDs: Set<String> = [
        "com.microsoft.VSCode",
        "com.microsoft.VSCodeInsiders",
        "com.vscodium",
        "com.todesktop.230313mzl4w4u92", // Cursor
        "com.exafunction.windsurf"
    ]

    /// Which web engine the app bundle ships, judged from its frameworks:
    /// Electron's framework, or any framework with Chromium's crash handler.
    static func engine(ofBundleAt bundleURL: URL, fileManager: FileManager = .default) -> Engine {
        let frameworks = bundleURL.appendingPathComponent("Contents/Frameworks", isDirectory: true)
        guard let names = try? fileManager.contentsOfDirectory(atPath: frameworks.path) else { return .other }
        if names.contains("Electron Framework.framework") { return .electron }
        for name in names where name.hasSuffix(".framework") {
            let helpers = frameworks.appendingPathComponent("\(name)/Versions/Current/Helpers", isDirectory: true)
            if let helperNames = try? fileManager.contentsOfDirectory(atPath: helpers.path),
               helperNames.contains(where: { $0.hasSuffix("crashpad_handler") }) {
                return .chromium
            }
        }
        return .other
    }

    /// The switches to try, in order, for an app.
    static func attributes(for engine: Engine, bundleID: String?) -> [String] {
        if let bundleID, excludedBundleIDs.contains(bundleID) { return [] }
        switch engine {
        case .electron: return [manualAttribute]
        case .chromium: return [manualAttribute, enhancedAttribute]
        case .other: return []
        }
    }
}

/// Result of an accessibility read. `.axError` means the AX API itself failed
/// (no permission, timeout, no focused element) — callers fail open on it,
/// matching the app's long-standing behavior. A successful read with missing
/// optional attributes is still `.value`.
nonisolated enum AXInspection<Value: Equatable & Sendable>: Equatable, Sendable {
    case value(Value)
    case axError
}

/// How long a single AX call may wait on the target app before giving up.
/// AX calls are synchronous, and an unresponsive target (typically an Electron
/// app) otherwise blocks the caller for the system default of several seconds.
/// The timeout applies per element, so it is set on the application element
/// and on every element read from it.
nonisolated struct AXTimeoutPolicy: Equatable, Sendable {
    /// Budget for the secure-field guard. Generous, so a slow-but-alive
    /// password field is still inspected rather than failing open.
    static let secureFieldCheckSeconds: Float = 3.0
    /// Budget for verification snapshots and post-paste writes. Short, because
    /// an unanswered read only makes verification inconclusive.
    static let verificationSeconds: Float = 0.4

    let seconds: Float

    static let secureFieldCheck = AXTimeoutPolicy(seconds: secureFieldCheckSeconds)
    static let verification = AXTimeoutPolicy(seconds: verificationSeconds)

    /// True when an attribute read failed because the target did not answer
    /// (timeout) or does not speak AX, as opposed to the attribute simply
    /// being absent. Verification treats such a read as unreadable.
    static func indicatesUnresponsiveTarget(_ error: AXError) -> Bool {
        error == .cannotComplete || error == .notImplemented
    }
}

/// Testable seam over the Accessibility API so unit tests can drive the real
/// secure-field and paste-verification decision logic without live AX calls.
protocol AccessibilityInspecting: AnyObject {
    func focusedElementDetails(processIdentifier: pid_t?) -> AXInspection<FocusedElementDetails>
    func focusedElementTextSnapshot(processIdentifier: pid_t?) -> AXInspection<FocusedTextSnapshot>
    /// Inserts text at the caret via kAXSelectedTextAttribute.
    /// Returns true when the AX API accepted the write.
    func insertTextAtFocus(_ text: String, processIdentifier: pid_t?) -> Bool
}

/// Real implementation backed by the AX API.
final class SystemAccessibilityInspector: AccessibilityInspecting, FocusedFieldReading {
    private let applyTimeout: (AXUIElement, Float) -> Void
    private let copyFocusedElement: (AXUIElement) -> AXUIElement?

    /// The closures are the seams for the two AX calls that decide which
    /// elements get a messaging timeout, so the policy can be tested without
    /// live AX.
    init(
        applyTimeout: @escaping (AXUIElement, Float) -> Void = { element, seconds in
            _ = AXUIElementSetMessagingTimeout(element, seconds)
        },
        copyFocusedElement: @escaping (AXUIElement) -> AXUIElement? = SystemAccessibilityInspector.copySystemFocusedElement
    ) {
        self.applyTimeout = applyTimeout
        self.copyFocusedElement = copyFocusedElement
    }

    func focusedElementDetails(processIdentifier: pid_t?) -> AXInspection<FocusedElementDetails> {
        guard let element = focusedElement(processIdentifier: processIdentifier, policy: .secureFieldCheck) else {
            return .axError
        }

        var details = FocusedElementDetails()
        details.role = copyStringAttribute(element, kAXRoleAttribute)
        guard details.role != nil else {
            // Role is mandatory for every AX element; failing to read it means
            // the API call itself failed, not that the attribute is absent.
            return .axError
        }
        details.subrole = copyStringAttribute(element, kAXSubroleAttribute)
        details.roleDescription = copyStringAttribute(element, kAXRoleDescriptionAttribute)
        return .value(details)
    }

    func focusedElementTextSnapshot(processIdentifier: pid_t?) -> AXInspection<FocusedTextSnapshot> {
        guard let element = focusedElement(processIdentifier: processIdentifier, policy: .verification) else {
            return .axError
        }

        // An unanswered read means the target is hung: report the whole
        // snapshot as unreadable (inconclusive to callers) instead of paying
        // another timeout per attribute or judging from a partial read.
        guard case .value(let value) = readAttribute(element, kAXValueAttribute),
              case .value(let selectedText) = readAttribute(element, kAXSelectedTextAttribute),
              case .value(let selectedRange) = readAttribute(element, kAXSelectedTextRangeAttribute) else {
            return .axError
        }
        return .value(FocusedTextSnapshot(
            value: value as? String,
            selectedText: selectedText as? String,
            selectedRange: Self.textRange(from: selectedRange)
        ))
    }

    /// Reads the field's text only after checking it is not a secure field.
    func readFocusedField(processIdentifier: pid_t) -> FocusedFieldRead? {
        guard let element = focusedElement(processIdentifier: processIdentifier, policy: .verification),
              let role = copyStringAttribute(element, kAXRoleAttribute) else { return nil }
        let details = FocusedElementDetails(
            role: role,
            subrole: copyStringAttribute(element, kAXSubroleAttribute),
            roleDescription: copyStringAttribute(element, kAXRoleDescriptionAttribute)
        )
        var read = FocusedFieldRead(elementID: Int(bitPattern: CFHash(element)), isSecure: true)
        guard TextInjectionService.assessSecureField(.value(details)) != .blocked else { return read }
        read.isSecure = false
        guard case .value(let value) = readAttribute(element, kAXValueAttribute),
              case .value(let selectedRange) = readAttribute(element, kAXSelectedTextRangeAttribute) else { return nil }
        read.text = value as? String
        read.caretUTF16 = Self.textRange(from: selectedRange).map { $0.location + $0.length }
        return read
    }

    /// Engines found per app bundle; looked up once per app.
    private var engines: [URL: ChromiumAccessibility.Engine] = [:]
    private let switchQueue = DispatchQueue(label: "com.orttaai.accessibility-switch", qos: .userInitiated)

    func prepareToRead(_ app: NSRunningApplication) {
        guard let bundleURL = app.bundleURL else { return }
        let engine = engines[bundleURL] ?? ChromiumAccessibility.engine(ofBundleAt: bundleURL)
        engines[bundleURL] = engine
        let attributes = ChromiumAccessibility.attributes(for: engine, bundleID: app.bundleIdentifier)
        guard !attributes.isEmpty else { return }
        let processIdentifier = app.processIdentifier
        // Off the main thread: a busy app must not delay the recording start.
        switchQueue.async {
            let appElement = AXUIElementCreateApplication(processIdentifier)
            _ = AXUIElementSetMessagingTimeout(appElement, AXTimeoutPolicy.verificationSeconds)
            for attribute in attributes
            where AXUIElementSetAttributeValue(appElement, attribute as CFString, kCFBooleanTrue) == .success {
                return
            }
            Logger.injection.info("Couldn't turn on Accessibility for pid \(processIdentifier)")
        }
    }

    func observeFocusedField(processIdentifier: pid_t, onChange: @escaping (String?) -> Void) -> AnyObject? {
        guard let element = focusedElement(processIdentifier: processIdentifier, policy: .verification) else { return nil }
        return AXValueChangeObservation(processIdentifier: processIdentifier, element: element) { [weak self] destroyed in
            // Only the value of the field already being watched: one call,
            // instead of finding the focused field and its role again.
            guard !destroyed, let self, case .value(let value) = self.readAttribute(element, kAXValueAttribute) else {
                onChange(nil)
                return
            }
            onChange(value as? String)
        }
    }

    func insertTextAtFocus(_ text: String, processIdentifier: pid_t?) -> Bool {
        guard let element = focusedElement(processIdentifier: processIdentifier, policy: .verification) else {
            return false
        }

        var settable = DarwinBoolean(false)
        let settableResult = AXUIElementIsAttributeSettable(
            element,
            kAXSelectedTextAttribute as CFString,
            &settable
        )
        guard settableResult == .success, settable.boolValue else {
            return false
        }

        let setResult = AXUIElementSetAttributeValue(
            element,
            kAXSelectedTextAttribute as CFString,
            text as CFString
        )
        return setResult == .success
    }

    // MARK: - Bounded element access

    /// Application element with the policy's messaging timeout applied.
    func boundedApplicationElement(processIdentifier: pid_t, policy: AXTimeoutPolicy) -> AXUIElement {
        let appElement = AXUIElementCreateApplication(processIdentifier)
        applyTimeout(appElement, policy.seconds)
        return appElement
    }

    /// Focused element of the target app. Both the application element and the
    /// returned element get the policy's timeout, since it is per object.
    func focusedElement(processIdentifier: pid_t?, policy: AXTimeoutPolicy) -> AXUIElement? {
        guard let pid = processIdentifier else { return nil }
        let appElement = boundedApplicationElement(processIdentifier: pid, policy: policy)
        guard let element = copyFocusedElement(appElement) else { return nil }
        applyTimeout(element, policy.seconds)
        return element
    }

    // MARK: - Private

    private static func copySystemFocusedElement(of appElement: AXUIElement) -> AXUIElement? {
        var focused: AnyObject?
        let result = AXUIElementCopyAttributeValue(
            appElement,
            kAXFocusedUIElementAttribute as CFString,
            &focused
        )
        guard result == .success, let element = focused else {
            return nil
        }
        // swiftlint:disable:next force_cast
        return (element as! AXUIElement)
    }

    private func copyStringAttribute(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: AnyObject?
        let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard result == .success else { return nil }
        return value as? String
    }

    private enum AttributeRead {
        /// The read completed; nil when the attribute is absent.
        case value(AnyObject?)
        /// The target did not answer, or does not speak AX.
        case unresponsive
    }

    private func readAttribute(_ element: AXUIElement, _ attribute: String) -> AttributeRead {
        var value: AnyObject?
        let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        if AXTimeoutPolicy.indicatesUnresponsiveTarget(result) { return .unresponsive }
        return .value(result == .success ? value : nil)
    }

    private static func textRange(from value: AnyObject?) -> FocusedTextRange? {
        guard let axValue = value, CFGetTypeID(axValue) == AXValueGetTypeID() else {
            return nil
        }
        // swiftlint:disable:next force_cast
        let rangeValue = axValue as! AXValue
        var range = CFRange()
        guard AXValueGetType(rangeValue) == .cfRange,
              AXValueGetValue(rangeValue, .cfRange, &range) else {
            return nil
        }
        return FocusedTextRange(location: range.location, length: range.length)
    }
}

/// Value-changed notifications from one element, and the element going away
/// (true), delivered on the main run loop until the observation is released.
private final class AXValueChangeObservation {
    private let observer: AXObserver
    private let element: AXUIElement
    private var destroyedObserved = false
    let onChange: (_ destroyed: Bool) -> Void

    init?(processIdentifier: pid_t, element: AXUIElement, onChange: @escaping (_ destroyed: Bool) -> Void) {
        var created: AXObserver?
        let callback: AXObserverCallback = { _, _, notification, refcon in
            guard let refcon else { return }
            let observation = Unmanaged<AXValueChangeObservation>.fromOpaque(refcon).takeUnretainedValue()
            let destroyed = (notification as String) == kAXUIElementDestroyedNotification
            MainActor.assumeIsolated { observation.onChange(destroyed) }
        }
        guard AXObserverCreate(processIdentifier, callback, &created) == .success, let created else { return nil }
        observer = created
        self.element = element
        self.onChange = onChange
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard AXObserverAddNotification(created, element, kAXValueChangedNotification as CFString, refcon) == .success else {
            return nil
        }
        // Optional: not every app reports it, and the timed reads catch a
        // field that went away anyway.
        destroyedObserved = AXObserverAddNotification(
            created, element, kAXUIElementDestroyedNotification as CFString, refcon
        ) == .success
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), .defaultMode)
    }

    deinit {
        AXObserverRemoveNotification(observer, element, kAXValueChangedNotification as CFString)
        if destroyedObserved {
            AXObserverRemoveNotification(observer, element, kAXUIElementDestroyedNotification as CFString)
        }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
    }
}
