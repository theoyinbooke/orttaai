// HotkeyService.swift
// Orttaai

import Cocoa
import os

final class HotkeyService {
    fileprivate var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var targetKeyCode: CGKeyCode = 0
    private var targetModifiers: CGEventFlags = []

    var onKeyDown: (() -> Void)?
    var onKeyUp: (() -> Void)?

    private var isKeyHeld = false

    func start(keyCode: CGKeyCode = 49, modifiers: CGEventFlags = [.maskControl, .maskShift]) -> Bool {
        targetKeyCode = keyCode
        targetModifiers = modifiers

        let eventMask: CGEventMask = (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue)

        let userInfo = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: hotkeyCallback,
            userInfo: userInfo
        ) else {
            Logger.hotkey.error("Failed to create event tap — Input Monitoring not granted")
            return false
        }

        eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        Logger.hotkey.info("Hotkey service started, keyCode: \(keyCode), modifiers: \(modifiers.rawValue)")
        return true
    }

    func stop() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
        isKeyHeld = false
        Logger.hotkey.info("Hotkey service stopped")
    }

    fileprivate func handleEvent(_ event: CGEvent, type: CGEventType) -> Unmanaged<CGEvent>? {
        let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags

        // Check if our target modifiers are held
        let hasModifiers = flags.contains(targetModifiers)

        switch type {
        case .keyDown:
            if keyCode == targetKeyCode {
                if hasModifiers && !isKeyHeld {
                    isKeyHeld = true
                    onKeyDown?()
                }

                if isKeyHeld {
                    return nil // Consume initial and repeat keyDown events while held
                }
            }

        case .keyUp:
            if keyCode == targetKeyCode && isKeyHeld {
                isKeyHeld = false
                onKeyUp?()
                return nil // Consume the event
            }

        case .flagsChanged:
            // If modifiers are released while key is held, treat as key up
            if isKeyHeld && !hasModifiers {
                isKeyHeld = false
                onKeyUp?()
            }

        default:
            break
        }

        return Unmanaged.passUnretained(event)
    }
}

private func hotkeyCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo = userInfo else {
        return Unmanaged.passUnretained(event)
    }

    // Handle tap disabled events (system can disable taps under load)
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        let service = Unmanaged<HotkeyService>.fromOpaque(userInfo).takeUnretainedValue()
        if let tap = service.eventTap {
            CGEvent.tapEnable(tap: tap, enable: true)
        }
        return Unmanaged.passUnretained(event)
    }

    let service = Unmanaged<HotkeyService>.fromOpaque(userInfo).takeUnretainedValue()
    return service.handleEvent(event, type: type)
}
