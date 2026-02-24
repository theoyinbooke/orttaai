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

        switch state {
        case .idle:
            setTemplateIcon(symbolName: "waveform.circle")

        case .recording:
            setTintedIcon(symbolName: "waveform.circle.fill", color: NSColor.Orttaai.accent)
            startPulseTimer()

        case .processing:
            setTintedIcon(symbolName: "waveform.circle.fill", color: NSColor.Orttaai.accent)

        case .downloading:
            setTemplateIcon(symbolName: "waveform.circle")
            // TODO: Draw progress ring overlay in Phase 3

        case .error:
            setTemplateIcon(symbolName: "waveform.circle")
            // TODO: Draw amber dot badge in Phase 3
        }
    }

    // MARK: - Private

    private func setTemplateIcon(symbolName: String) {
        guard let button = statusItem.button else { return }
        let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "Orttaai")
        image?.isTemplate = true
        button.image = image
        button.alphaValue = 1.0
    }

    private func setTintedIcon(symbolName: String, color: NSColor) {
        guard let button = statusItem.button else { return }
        let config = NSImage.SymbolConfiguration(pointSize: 16, weight: .regular)
        let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "Orttaai")?
            .withSymbolConfiguration(config)
        image?.isTemplate = false

        // Apply tint by drawing into an image with the desired color
        if let tinted = tintImage(image, with: color) {
            button.image = tinted
        }
    }

    private func tintImage(_ image: NSImage?, with color: NSColor) -> NSImage? {
        guard let image = image else { return nil }
        let tinted = NSImage(size: image.size, flipped: false) { rect in
            image.draw(in: rect)
            color.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        tinted.isTemplate = false
        return tinted
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
