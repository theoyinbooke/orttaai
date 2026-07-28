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

/// Text content of the focused UI element, read for paste verification.
nonisolated struct FocusedTextSnapshot: Equatable, Sendable {
    /// kAXValueAttribute as a string, nil when the element exposes no value.
    var value: String?
    /// kAXSelectedTextAttribute, nil when unsupported.
    var selectedText: String?
}

/// Result of an accessibility read. `.axError` means the AX API itself failed
/// (no permission, timeout, no focused element) — callers fail open on it,
/// matching the app's long-standing behavior. A successful read with missing
/// optional attributes is still `.value`.
nonisolated enum AXInspection<Value: Equatable & Sendable>: Equatable, Sendable {
    case value(Value)
    case axError
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

    func focusedElementDetails(processIdentifier: pid_t?) -> AXInspection<FocusedElementDetails> {
        guard let element = focusedElement(processIdentifier: processIdentifier) else {
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
        guard let element = focusedElement(processIdentifier: processIdentifier) else {
            return .axError
        }

        var snapshot = FocusedTextSnapshot()
        snapshot.value = copyStringAttribute(element, kAXValueAttribute)
        snapshot.selectedText = copyStringAttribute(element, kAXSelectedTextAttribute)
        return .value(snapshot)
    }

    func insertTextAtFocus(_ text: String, processIdentifier: pid_t?) -> Bool {
        guard let element = focusedElement(processIdentifier: processIdentifier) else {
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

    // MARK: - Private

    private func focusedElement(processIdentifier: pid_t?) -> AXUIElement? {
        guard let pid = processIdentifier else { return nil }
        let appElement = AXUIElementCreateApplication(pid)

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
}
