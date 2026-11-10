// ModifierTapMonitor.swift
// Orttaai
//
// Listens for taps of the Right Option key (dictate) and the Right Command
// key (edit) anywhere on the Mac. A Carbon hotkey can't be a lone modifier,
// so this uses a listen-only event tap: it sees modifier changes, key-downs
// and clicks, never changes or blocks them, and needs the Input Monitoring
// permission. ModifierTapDetector does the deciding; this class only feeds
// it events.

import AppKit
import Carbon
import os

@MainActor
final class ModifierTapMonitor {
    /// Called on the main thread for each clean tap of Right Option.
    var onRightOptionTap: (() -> Void)?
    /// Called on the main thread for each clean tap of Right Command.
    var onRightCommandTap: (() -> Void)?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var rightOption = ModifierTapDetector(keyCode: ModifierTapDetector.rightOptionKeyCode)
    private var rightCommand = ModifierTapDetector(
        keyCode: ModifierTapDetector.rightCommandKeyCode,
        maxTapDuration: ModifierTapDetector.rightCommandTapMaxDuration
    )

    var isRunning: Bool { eventTap != nil }

    /// Whether macOS currently lets Orttaai listen to the keyboard.
    static var hasInputMonitoringAccess: Bool {
        CGPreflightListenEventAccess()
    }

    // Device-specific flag bits (NX_DEVICE*KEYMASK), which tell the left and
    // right keys apart.
    private static let leftCommandDeviceMask: UInt64 = 0x0000_0008
    private static let rightCommandDeviceMask: UInt64 = 0x0000_0010
    private static let leftOptionDeviceMask: UInt64 = 0x0000_0020
    private static let rightOptionDeviceMask: UInt64 = 0x0000_0040

    /// Starts listening. Returns false when macOS refuses the tap, which
    /// means Input Monitoring hasn't been granted.
    @discardableResult
    func start() -> Bool {
        if isRunning { return true }

        let interesting: [CGEventType] = [
            .flagsChanged, .keyDown,
            .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel,
        ]
        let mask = interesting.reduce(CGEventMask(0)) { $0 | (1 << CGEventMask($1.rawValue)) }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: { _, type, event, userInfo in
                if let userInfo {
                    let monitor = Unmanaged<ModifierTapMonitor>.fromOpaque(userInfo).takeUnretainedValue()
                    let keyCode = UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode))
                    let flags = event.flags.rawValue
                    let time = TimeInterval(event.timestamp) / 1_000_000_000
                    MainActor.assumeIsolated {
                        monitor.handle(type: type, keyCode: keyCode, flags: flags, time: time)
                    }
                }
                return Unmanaged.passUnretained(event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            Logger.hotkey.error("Modifier key listener refused; Input Monitoring not granted")
            return false
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        eventTap = tap
        runLoopSource = source
        resetDetectors()
        Logger.hotkey.info("Modifier key listener started")
        return true
    }

    func stop() {
        guard let tap = eventTap else { return }
        CGEvent.tapEnable(tap: tap, enable: false)
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        CFMachPortInvalidate(tap)
        eventTap = nil
        runLoopSource = nil
        resetDetectors()
        Logger.hotkey.info("Modifier key listener stopped")
    }

    private func resetDetectors() {
        rightOption.reset()
        rightCommand.reset()
    }

    private func handle(type: CGEventType, keyCode: UInt16, flags: UInt64, time: TimeInterval) {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // macOS switches a tap off if it ever stalls; switch it back on.
            resetDetectors()
            if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: true) }

        case .flagsChanged:
            let modifierFlags = CGEventFlags(rawValue: flags)
            let controlShiftOrFn = modifierFlags.contains(.maskControl)
                || modifierFlags.contains(.maskShift)
                || modifierFlags.contains(.maskSecondaryFn)

            if rightOption.modifiersChanged(
                keyCode: keyCode,
                keyIsDown: flags & Self.rightOptionDeviceMask != 0,
                otherModifiersDown: controlShiftOrFn
                    || modifierFlags.contains(.maskCommand)
                    || flags & Self.leftOptionDeviceMask != 0,
                at: time
            ) {
                Logger.hotkey.info("Right Option tapped")
                onRightOptionTap?()
            }

            // While a password field (or a terminal's Secure Keyboard Entry)
            // has the keyboard, key presses are hidden from the listener, so
            // ⌘V there would look like a lone tap.
            if rightCommand.modifiersChanged(
                keyCode: keyCode,
                keyIsDown: flags & Self.rightCommandDeviceMask != 0,
                otherModifiersDown: controlShiftOrFn
                    || modifierFlags.contains(.maskAlternate)
                    || flags & Self.leftCommandDeviceMask != 0,
                at: time
            ), !IsSecureEventInputEnabled() {
                Logger.hotkey.info("Right Command tapped")
                onRightCommandTap?()
            }

        default:
            rightOption.otherInput()
            rightCommand.otherInput()
        }
    }
}
