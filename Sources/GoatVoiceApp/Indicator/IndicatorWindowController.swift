import AppKit
import Combine
import Foundation

final class IndicatorPanel: NSPanel {
    var onCancel: (() -> Void)?

    override var canBecomeKey: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            onCancel?()
        } else {
            super.keyDown(with: event)
        }
    }
}

@MainActor
final class IndicatorWindowController {
    var onNoticeDismissed: ((Notice) -> Void)?
    var onNoticeAction: ((Notice.Action) -> Void)?

    private let model: AppModel
    private let panel: IndicatorPanel
    private let indicatorView: IndicatorView
    private var cancellables = Set<AnyCancellable>()
    private var lockedScreen: NSScreen?
    private var dismissalTimer: Timer?
    private var presentationGeneration: UInt64 = 0

    init(model: AppModel) {
        self.model = model
        panel = IndicatorPanel(
            contentRect: NSRect(origin: .zero, size: NSSize(width: 160, height: 30)),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.animationBehavior = .none

        indicatorView = IndicatorView(frame: panel.contentView?.bounds ?? .zero)
        indicatorView.autoresizingMask = [.width, .height]
        panel.contentView?.addSubview(indicatorView)

        bind()
    }

    private func bind() {
        panel.onCancel = { [weak self] in self?.handleEscape() }
        indicatorView.onHUDAction = { [weak self] in self?.handleHUDAction() }

        model.$presentation
            .receive(on: RunLoop.main)
            .sink { [weak self] presentation in self?.apply(presentation) }
            .store(in: &cancellables)

        model.$audioLevel
            .receive(on: RunLoop.main)
            .sink { [weak self] level in self?.indicatorView.setAudioLevel(level) }
            .store(in: &cancellables)

        model.$previewText
            .receive(on: RunLoop.main)
            .sink { [weak self] text in
                guard let self else { return }
                self.indicatorView.setPreview(text)
                self.refitPanel(animated: true)
            }
            .store(in: &cancellables)

        model.$reduceMotion
            .receive(on: RunLoop.main)
            .sink { [weak self] reduceMotion in self?.indicatorView.reduceMotion = reduceMotion }
            .store(in: &cancellables)

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.handleScreenParametersChanged() }
        }

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.model.refreshReduceMotion() }
        }
    }

    private func apply(_ presentation: SessionPresentation) {
        presentationGeneration &+= 1
        let generation = presentationGeneration
        dismissalTimer?.invalidate()
        dismissalTimer = nil
        switch presentation.content {
        case .hidden:
            dismissalTimer?.invalidate()
            dismissalTimer = nil
            indicatorView.hideImmediately()
            lockedScreen = nil
            panel.orderOut(nil)
        case .strip(let phase):
            lockDisplayIfNeeded(presentation.displayID)
            panel.ignoresMouseEvents = true
            switch phase {
            case .listening:
                indicatorView.showListening(animated: lockedScreen != nil)
            case .processing:
                indicatorView.beginProcessing()
            }
            refitPanel(animated: false)
            orderFrontIfNeeded()
        case .notice(let notice):
            lockDisplayIfNeeded(presentation.displayID)
            panel.ignoresMouseEvents = false
            indicatorView.showNotice(notice)
            refitPanel(animated: false)
            orderFrontIfNeeded()
            scheduleDismissal(for: notice)
        case .exiting(let kind):
            dismissalTimer?.invalidate()
            dismissalTimer = nil
            panel.ignoresMouseEvents = true
            indicatorView.exit(kind: kind) { [weak self] in
                guard let self, self.presentationGeneration == generation else { return }
                self.panel.orderOut(nil)
                self.lockedScreen = nil
            }
        }
    }

    private func lockDisplayIfNeeded(_ displayID: CGDirectDisplayID?) {
        if let locked = lockedScreen, NotchGeometry.isAttached(locked) { return }
        if let displayID, let screen = NotchGeometry.screen(for: displayID) {
            lockedScreen = screen
        } else {
            lockedScreen = Self.fallbackScreen()
        }
    }

    private static func fallbackScreen() -> NSScreen? {
        NSScreen.main ?? NSScreen.screens.first
    }

    private func handleScreenParametersChanged() {
        guard panel.isVisible else {
            lockedScreen = nil
            return
        }
        if let locked = lockedScreen, let id = NotchGeometry.displayID(of: locked),
           let current = NotchGeometry.screen(for: id) {
            lockedScreen = current
            refitPanel(animated: false)
            return
        }
        lockedScreen = Self.fallbackScreen()
        refitPanel(animated: false)
    }

    private func refitPanel(animated: Bool) {
        guard let screen = lockedScreen else { return }
        switch model.presentation.content {
        case .strip, .notice: break
        case .hidden, .exiting: return
        }
        let maxWidth = NotchGeometry.maxContentWidth(for: screen)
        let size = indicatorView.fittingSize(maxWidth: maxWidth)
        let layout = NotchGeometry.capsuleLayout(for: screen, contentSize: size)
        let target = layout.frame
        indicatorView.needsLayout = true
        guard target != panel.frame else { return }
        if animated, panel.isVisible, !model.reduceMotion {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.15
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                panel.animator().setFrame(target, display: true)
            }
        } else {
            panel.setFrame(target, display: true)
        }
    }

    private func orderFrontIfNeeded() {
        guard !panel.isVisible else { return }
        panel.orderFrontRegardless()
    }

    private func scheduleDismissal(for notice: Notice) {
        dismissalTimer?.invalidate()
        let generation = presentationGeneration
        dismissalTimer = Timer.scheduledTimer(
            withTimeInterval: notice.dismissalTimeout,
            repeats: false
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.presentationGeneration == generation else { return }
                self.indicatorView.hideImmediately()
                self.panel.orderOut(nil)
                self.lockedScreen = nil
                self.onNoticeDismissed?(notice)
            }
        }
    }

    private func handleEscape() {
        if let notice = currentNotice {
            dismissalTimer?.invalidate()
            dismissalTimer = nil
            indicatorView.hideImmediately()
            panel.orderOut(nil)
            lockedScreen = nil
            onNoticeDismissed?(notice)
        }
    }

    private func handleHUDAction() {
        if case .notice(let notice) = model.presentation.content, let action = notice.action {
            onNoticeAction?(action)
        }
    }

    private var currentNotice: Notice? {
        if case .notice(let notice) = model.presentation.content {
            return notice
        }
        return nil
    }
}
