import AppKit
import Foundation
import GoatVoicePlatform

@MainActor
final class PermissionMonitor {
    struct State: Equatable {
        let microphone: MicrophonePermission
        let accessibility: AccessibilityPermission

        var needsSetup: Bool {
            microphone != .granted || accessibility != .trusted
        }
    }

    var onChange: ((State) -> Void)?
    var onPoll: (() -> Void)?

    private let permissions: PermissionCenter
    private let notifications: NotificationCenter
    private let setupInterval: Duration
    private let readyInterval: Duration
    private var previousState: State?
    private var pollingTask: Task<Void, Never>?
    private var activationToken: NotificationToken?
    private var running = false

    init(permissions: PermissionCenter,
         notifications: NotificationCenter = .default,
         setupInterval: Duration = .milliseconds(250),
         readyInterval: Duration = .seconds(2)) {
        self.permissions = permissions
        self.notifications = notifications
        self.setupInterval = setupInterval
        self.readyInterval = readyInterval
    }

    func start() {
        guard !running else { return }
        running = true
        previousState = nil
        refresh()
        guard running else { return }
        activationToken = NotificationCenterObserver(notifications).observe(
            NSApplication.didBecomeActiveNotification
        ) { [weak self] in
            MainHop.async { self?.refresh() }
        }
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let interval = self?.pollingInterval else { return }
                do {
                    try await Task.sleep(for: interval)
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                self?.refresh()
            }
        }
    }

    func stop() {
        running = false
        pollingTask?.cancel()
        pollingTask = nil
        activationToken?.cancel()
        activationToken = nil
        previousState = nil
    }

    func refresh() {
        guard running else { return }
        let state = State(microphone: permissions.microphone(),
                          accessibility: permissions.accessibility())
        if state != previousState {
            previousState = state
            onChange?(state)
        }
        if running { onPoll?() }
    }

    private var pollingInterval: Duration {
        previousState?.needsSetup == false ? readyInterval : setupInterval
    }

    deinit {
        pollingTask?.cancel()
        activationToken?.cancel()
    }
}
