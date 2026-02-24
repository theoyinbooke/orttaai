// FloatingPanelController.swift
// Orttaai

import Cocoa
import SwiftUI
import os

final class FloatingPanelController: NSObject {
    private var panel: NSPanel!
    private var hostingView: NSHostingView<AnyView>?
    private var handleLayer: CALayer!
    private var backgroundView: NSVisualEffectView!
    private var currentSize: CGSize = WindowSize.floatingPanelHandle
    private var isShowingHint = false

    // The panel frame stays at hint size in handle state so the tracking area
    // doesn't shift on hover. Only the gold pill + hint text toggle visibility.
    private let handlePillSize = CGSize(width: 48, height: 5)

    enum PanelState {
        case handle
        case recording
        case processing
        case error
    }
    private var panelState: PanelState = .handle

    override init() {
        super.init()
        setupPanel()
        observeScreenChanges()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    // MARK: - Setup

    private func setupPanel() {
        let hintSize = WindowSize.floatingPanelHandle
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: hintSize.width, height: hintSize.height),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false

        let contentView = panel.contentView!
        contentView.wantsLayer = true

        // Dark vibrancy background — hidden in handle, visible when expanded or hovered
        backgroundView = NSVisualEffectView(frame: contentView.bounds)
        backgroundView.material = .hudWindow
        backgroundView.blendingMode = .behindWindow
        backgroundView.state = .active
        backgroundView.wantsLayer = true
        backgroundView.layer?.cornerRadius = hintSize.height / 2
        backgroundView.layer?.masksToBounds = true
        backgroundView.autoresizingMask = [.width, .height]
        backgroundView.alphaValue = 0
        contentView.addSubview(backgroundView)

        // Small gold pill centered in the panel
        handleLayer = CALayer()
        handleLayer.backgroundColor = NSColor.Orttaai.accent.withAlphaComponent(0.75).cgColor
        handleLayer.cornerRadius = handlePillSize.height / 2
        handleLayer.frame = centeredPillRect(in: contentView.bounds)
        contentView.layer?.addSublayer(handleLayer)

        setupTrackingArea()
        currentSize = hintSize
    }

    private func setupTrackingArea() {
        guard let contentView = panel.contentView else { return }
        let area = NSTrackingArea(
            rect: contentView.bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        contentView.addTrackingArea(area)
    }

    private func observeScreenChanges() {
        // Fires when display config changes (resolution, arrangement, Dock show/hide)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenDidChange),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
        // Fires when user switches Spaces or enters/exits fullscreen
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(screenDidChange),
            name: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil
        )
    }

    @objc private func screenDidChange() {
        guard panel.isVisible else { return }
        // Reposition immediately
        positionAtBottomCenter(size: currentSize)
        // visibleFrame may lag behind the space change — retry after the system settles
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self = self, self.panel.isVisible else { return }
            self.positionAtBottomCenter(size: self.currentSize)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            guard let self = self, self.panel.isVisible else { return }
            self.positionAtBottomCenter(size: self.currentSize)
        }
    }

    private func centeredPillRect(in bounds: NSRect) -> CGRect {
        CGRect(
            x: (bounds.width - handlePillSize.width) / 2,
            y: (bounds.height - handlePillSize.height) / 2,
            width: handlePillSize.width,
            height: handlePillSize.height
        )
    }

    // MARK: - Public API

    func show() {
        panelState = .handle
        positionAtBottomCenter(size: currentSize)
        applyHandleAppearance()
        panel.alphaValue = 1
        panel.orderFront(nil)
        Logger.ui.info("Floating panel shown as handle")
    }

    func transitionToHandle() {
        panelState = .handle
        isShowingHint = false
        let size = WindowSize.floatingPanelHandle
        animateTransition(to: size) { [weak self] in
            self?.applyHandleAppearance()
        }
    }

    func transitionToRecording(content view: some View) {
        panelState = .recording
        isShowingHint = false
        let size = WindowSize.floatingPanelRecording
        updateContent(view)
        hostingView?.isHidden = false
        animateTransition(to: size) { [weak self] in
            self?.applyExpandedAppearance()
        }
    }

    func transitionToProcessing(content view: some View) {
        panelState = .processing
        isShowingHint = false
        let size = WindowSize.floatingPanelProcessing
        updateContent(view)
        hostingView?.isHidden = false
        animateTransition(to: size) { [weak self] in
            self?.applyExpandedAppearance()
        }
    }

    func transitionToError(content view: some View) {
        panelState = .error
        isShowingHint = false
        let size = WindowSize.floatingPanelError
        updateContent(view)
        hostingView?.isHidden = false
        animateTransition(to: size) { [weak self] in
            self?.applyExpandedAppearance()
        }
    }

    func updateContent<V: View>(_ view: V) {
        if let existing = hostingView {
            existing.rootView = AnyView(view)
            return
        }

        let hosting = NSHostingView(rootView: AnyView(view))
        hosting.frame = panel.contentView!.bounds
        hosting.autoresizingMask = [.width, .height]
        panel.contentView?.addSubview(hosting)
        hostingView = hosting
    }

    // MARK: - Hover (handle state only)

    @objc(mouseEntered:) func mouseEntered(with event: NSEvent) {
        guard panelState == .handle, !isShowingHint else { return }
        isShowingHint = true

        // Show hint text + dark background — NO resize, panel stays same frame
        let hintView = HStack(spacing: 4) {
            Text("Hold")
                .foregroundStyle(.white.opacity(0.5))
            Text("Ctrl + Shift + Space")
                .foregroundStyle(.white.opacity(0.85))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(.white.opacity(0.1))
                )
            Text("to dictate")
                .foregroundStyle(.white.opacity(0.5))
        }
        .font(.system(size: 11, weight: .medium))
        .frame(maxWidth: .infinity, maxHeight: .infinity)

        updateContent(hintView)
        hostingView?.isHidden = false

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            context.allowsImplicitAnimation = true
            self.backgroundView.animator().alphaValue = 1
            self.handleLayer.opacity = 0
            self.panel.hasShadow = true
        }
    }

    @objc(mouseExited:) func mouseExited(with event: NSEvent) {
        guard panelState == .handle, isShowingHint else { return }
        isShowingHint = false

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.2
            context.allowsImplicitAnimation = true
            self.backgroundView.animator().alphaValue = 0
            self.handleLayer.opacity = 1
            self.panel.hasShadow = false
        }, completionHandler: { [weak self] in
            guard self?.panelState == .handle else { return }
            self?.hostingView?.isHidden = true
        })
    }

    // MARK: - Animation & Positioning

    private func animateTransition(to size: CGSize, completion: (() -> Void)? = nil) {
        currentSize = size

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.25
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            context.allowsImplicitAnimation = true

            let frame = self.bottomCenterFrame(for: size)
            self.panel.animator().setFrame(frame, display: true)
            self.backgroundView.layer?.cornerRadius = size.height / 2
        }, completionHandler: { [weak self] in
            self?.updateHandleLayerFrame()
            completion?()
        })
    }

    private func positionAtBottomCenter(size: CGSize) {
        let frame = bottomCenterFrame(for: size)
        panel.setFrame(frame, display: true)
        backgroundView.layer?.cornerRadius = size.height / 2
        updateHandleLayerFrame()
    }

    private func bottomCenterFrame(for size: CGSize) -> NSRect {
        let screen = NSScreen.main ?? NSScreen.screens.first!
        let fullFrame = screen.frame
        let bottomMargin: CGFloat = 4

        let x = fullFrame.midX - size.width / 2
        let y = fullFrame.minY + bottomMargin

        return NSRect(x: x, y: y, width: size.width, height: size.height)
    }

    private func updateHandleLayerFrame() {
        guard let contentView = panel.contentView else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        handleLayer.frame = centeredPillRect(in: contentView.bounds)
        CATransaction.commit()
    }

    // MARK: - Appearance

    private func applyHandleAppearance() {
        handleLayer.isHidden = false
        handleLayer.opacity = 1
        backgroundView.alphaValue = 0
        hostingView?.isHidden = true
        panel.hasShadow = false
        updateHandleLayerFrame()
    }

    private func applyExpandedAppearance() {
        handleLayer.isHidden = true
        backgroundView.alphaValue = 1
        backgroundView.layer?.cornerRadius = currentSize.height / 2
        panel.hasShadow = true
    }
}
