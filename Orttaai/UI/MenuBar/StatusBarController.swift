// StatusBarController.swift
// Orttaai

import Cocoa
import os

enum StatusBarIconState {
    case idle
    case recording
    case processing
    case downloading(progress: Double)
    case error
}

final class StatusBarController {
    private let statusItem: NSStatusItem
    private var pulseTimer: Timer?
    private var currentState: StatusBarIconState = .idle

    init(statusItem: NSStatusItem) {
        self.statusItem = statusItem
        updateIcon(state: .idle)
    }

    func updateIcon(state: StatusBarIconState) {
        currentState = state
        stopPulseTimer()
        applyIcon(for: state)

        switch state {
        case .recording:
            startPulseTimer()
        case .idle, .processing, .downloading, .error:
            break
        }
    }

    // MARK: - Private

    private func applyIcon(for state: StatusBarIconState) {
        guard let button = statusItem.button else { return }
        let renderedState: MenuBarIconRenderer.IconState = switch state {
        case .idle:
            .idle
        case .recording:
            .recording
        case .processing:
            .processing
        case .downloading(let progress):
            .downloading(progress: progress)
        case .error:
            .error
        }
        button.image = MenuBarIconRenderer.renderIcon(for: renderedState)
        button.alphaValue = 1.0
    }

    private func startPulseTimer() {
        var increasing = false
        pulseTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            guard let button = self?.statusItem.button else { return }
            if increasing {
                button.alphaValue += 0.015
                if button.alphaValue >= 1.0 { increasing = false }
            } else {
                button.alphaValue -= 0.015
                if button.alphaValue <= 0.7 { increasing = true }
            }
        }
    }

    private func stopPulseTimer() {
        pulseTimer?.invalidate()
        pulseTimer = nil
        statusItem.button?.alphaValue = 1.0
    }
}
