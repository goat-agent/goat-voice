import AppKit
import Foundation

public enum SystemLifecycleEvent: Sendable, Equatable {
    case willSleep
    case didWake
    case screenLocked
    case screenUnlocked
    case willTerminate
}

public struct NotificationToken: Sendable {
    private let box: CancelBox

    public init(_ cancel: @escaping @Sendable () -> Void) {
        box = CancelBox(cancel)
    }

    public func cancel() {
        box.cancel()
    }

    private final class CancelBox: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        private let body: @Sendable () -> Void

        init(_ body: @escaping @Sendable () -> Void) {
            self.body = body
        }

        func cancel() {
            lock.lock()
            if cancelled {
                lock.unlock()
                return
            }
            cancelled = true
            lock.unlock()
            body()
        }
    }
}

public protocol NotificationObserving: Sendable {
    func observe(_ name: Notification.Name,
                 handler: @escaping @Sendable () -> Void) -> NotificationToken
}

public struct NotificationCenterObserver: NotificationObserving, @unchecked Sendable {
    private let center: NotificationCenter

    public init(_ center: NotificationCenter) {
        self.center = center
    }

    public func observe(_ name: Notification.Name,
                        handler: @escaping @Sendable () -> Void) -> NotificationToken {
        let raw = center.addObserver(forName: name, object: nil, queue: nil) { _ in
            handler()
        }
        return NotificationToken { [center] in
            center.removeObserver(raw)
        }
    }
}

public struct DistributedNotificationCenterObserver: NotificationObserving, @unchecked Sendable {
    private let center: DistributedNotificationCenter

    public init(_ center: DistributedNotificationCenter) {
        self.center = center
    }

    public func observe(_ name: Notification.Name,
                        handler: @escaping @Sendable () -> Void) -> NotificationToken {
        let raw = center.addObserver(forName: name, object: nil, queue: nil) { _ in
            handler()
        }
        return NotificationToken { [center] in
            center.removeObserver(raw)
        }
    }
}

private extension Notification.Name {
    static let screenIsLocked = Notification.Name("com.apple.screenIsLocked")
    static let screenIsUnlocked = Notification.Name("com.apple.screenIsUnlocked")
}

public final class SystemStateMonitor: @unchecked Sendable {
    private let workspaceCenter: NotificationObserving
    private let distributedCenter: NotificationObserving
    private let appCenter: NotificationObserving
    private let handler: @Sendable (SystemLifecycleEvent) -> Void
    private let queue = DispatchQueue(label: "goat.voice.platform.lifecycle.events")
    private let lock = NSLock()
    private var tokens: [NotificationToken] = []
    private var generation: UInt64 = 0

    public init(workspaceCenter: NotificationObserving,
                distributedCenter: NotificationObserving,
                appCenter: NotificationObserving,
                handler: @escaping @Sendable (SystemLifecycleEvent) -> Void) {
        self.workspaceCenter = workspaceCenter
        self.distributedCenter = distributedCenter
        self.appCenter = appCenter
        self.handler = handler
    }

    deinit {
        stop()
    }

    public static func system(
        handler: @escaping @Sendable (SystemLifecycleEvent) -> Void
    ) -> SystemStateMonitor {
        SystemStateMonitor(
            workspaceCenter: NotificationCenterObserver(NSWorkspace.shared.notificationCenter),
            distributedCenter: DistributedNotificationCenterObserver(.default()),
            appCenter: NotificationCenterObserver(.default),
            handler: handler)
    }

    public func start() {
        lock.lock()
        guard tokens.isEmpty else {
            lock.unlock()
            return
        }
        generation &+= 1
        let generation = self.generation
        tokens = [
            workspaceCenter.observe(NSWorkspace.willSleepNotification) { [weak self] in
                self?.emit(.willSleep, generation: generation)
            },
            workspaceCenter.observe(NSWorkspace.didWakeNotification) { [weak self] in
                self?.emit(.didWake, generation: generation)
            },
            distributedCenter.observe(.screenIsLocked) { [weak self] in
                self?.emit(.screenLocked, generation: generation)
            },
            distributedCenter.observe(.screenIsUnlocked) { [weak self] in
                self?.emit(.screenUnlocked, generation: generation)
            },
            appCenter.observe(NSApplication.willTerminateNotification) { [weak self] in
                self?.emit(.willTerminate, generation: generation)
            },
        ]
        lock.unlock()
    }

    public func stop() {
        lock.lock()
        let tokens = self.tokens
        self.tokens = []
        generation &+= 1
        lock.unlock()
        for token in tokens {
            token.cancel()
        }
    }

    private func emit(_ event: SystemLifecycleEvent, generation: UInt64) {
        queue.async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let valid = generation == self.generation && !self.tokens.isEmpty
            self.lock.unlock()
            guard valid else { return }
            self.handler(event)
        }
    }
}
