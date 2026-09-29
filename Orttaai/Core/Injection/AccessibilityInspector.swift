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
final class SystemAccessibilityInspector: AccessibilityInspecting {
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
