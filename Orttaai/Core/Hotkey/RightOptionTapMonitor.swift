// RightOptionTapMonitor.swift
// Orttaai
//
// Listens for a tap of the Right Option key anywhere on the Mac. A Carbon
// hotkey can't be a lone modifier, so this uses a listen-only event tap: it
// sees modifier changes, key-downs and clicks, never changes or blocks them,
// and needs the Input Monitoring permission. RightOptionTapDetector does the
// deciding; this class only feeds it events.

import AppKit
import os

@MainActor
final class RightOptionTapMonitor {
    /// Called on the main thread for each clean tap.
    var onTap: (() -> Void)?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var detector = RightOptionTapDetector()

    var isRunning: Bool { eventTap != nil }

    /// Whether macOS currently lets Orttaai listen to the keyboard.
    static var hasInputMonitoringAccess: Bool {
        CGPreflightListenEventAccess()
    }

    // NX_DEVICELALTKEYMASK: Left Option, as a device-specific flag bit.
    private static let leftOptionDeviceMask: UInt64 = 0x0000_0020
    // NX_DEVICERALTKEYMASK: Right Option.
    private static let rightOptionDeviceMask: UInt64 = 0x0000_0040

    /// Starts listening. Returns false when macOS refuses the tap, which
    /// means Input Monitoring hasn't been granted.
    @discardableResult
    func start() -> Bool {
        if isRunning { return true }

        let interesting: [CGEventType] = [
            .flagsChanged, .keyDown,
            .leftMouseDown, .rightMouseDown, .otherMouseDown,
        ]
        let mask = interesting.reduce(CGEventMask(0)) { $0 | (1 << CGEventMask($1.rawValue)) }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: { _, type, event, userInfo in
                if let userInfo {
                    let monitor = Unmanaged<RightOptionTapMonitor>.fromOpaque(userInfo).takeUnretainedValue()
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
            Logger.hotkey.error("Right Option listener refused; Input Monitoring not granted")
            return false
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        eventTap = tap
        runLoopSource = source
        detector.reset()
        Logger.hotkey.info("Right Option listener started")
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
        detector.reset()
        Logger.hotkey.info("Right Option listener stopped")
    }

    private func handle(type: CGEventType, keyCode: UInt16, flags: UInt64, time: TimeInterval) {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // macOS switches a tap off if it ever stalls; switch it back on.
            detector.reset()
            if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: true) }

        case .flagsChanged:
            let modifierFlags = CGEventFlags(rawValue: flags)
            let otherModifiersDown = modifierFlags.contains(.maskCommand)
                || modifierFlags.contains(.maskControl)
                || modifierFlags.contains(.maskShift)
                || modifierFlags.contains(.maskSecondaryFn)
                || flags & Self.leftOptionDeviceMask != 0
            let tapped = detector.modifiersChanged(
                keyCode: keyCode,
                rightOptionDown: flags & Self.rightOptionDeviceMask != 0,
                otherModifiersDown: otherModifiersDown,
                at: time
            )
            if tapped {
                Logger.hotkey.info("Right Option tapped")
                onTap?()
            }

        default:
            detector.otherInput()
        }
    }
}
