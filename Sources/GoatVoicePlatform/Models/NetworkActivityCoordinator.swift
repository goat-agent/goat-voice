import Foundation

public protocol NetworkPausable: AnyObject, Sendable {
    func pauseNetworkActivity() async
    func resumeNetworkActivity() async
}

public final class NetworkSessionGate: @unchecked Sendable {
    private let lock = NSLock()
    private var blocked = false
    private final class Registration {
        let client: any NetworkPausable
        var tail: Task<Void, Never>?

        init(_ client: any NetworkPausable) { self.client = client }

        func enqueue(_ operation: @escaping @Sendable (any NetworkPausable) async -> Void) {
            let previous = tail
            let client = client
            tail = Task {
                await previous?.value
                await operation(client)
            }
        }
    }

    private var clients: [ObjectIdentifier: Registration] = [:]
    private var pauseIssued: Set<ObjectIdentifier> = []

    public init() {}

    public var allowsNewNetworkWork: Bool {
        lock.withLock { !blocked }
    }

    @discardableResult
    public func performStart(_ start: () -> Void) -> Bool {
        lock.withLock {
            guard !blocked else { return false }
            start()
            return true
        }
    }

    func register(_ client: any NetworkPausable) {
        lock.withLock {
            let id = ObjectIdentifier(client)
            if clients[id] == nil { clients[id] = Registration(client) }
        }
    }

    func unregister(_ client: any NetworkPausable) {
        lock.withLock {
            let id = ObjectIdentifier(client)
            clients[id] = nil
            pauseIssued.remove(id)
        }
    }

    func beginSession() {
        lock.withLock {
            guard !blocked else { return }
            blocked = true
            pauseIssued = Set(clients.keys)
            for registration in clients.values {
                registration.enqueue { await $0.pauseNetworkActivity() }
            }
        }
    }

    func endSession() {
        lock.withLock {
            guard blocked else { return }
            blocked = false
            let targets = pauseIssued.compactMap { clients[$0] }
            pauseIssued = []
            for registration in targets {
                registration.enqueue { await $0.resumeNetworkActivity() }
            }
        }
    }
}

public actor NetworkActivityCoordinator {
    private let gate = NetworkSessionGate()

    public init() {}

    public nonisolated var sessionGate: NetworkSessionGate { gate }

    public nonisolated var allowsNewNetworkWork: Bool {
        gate.allowsNewNetworkWork
    }

    public nonisolated func beginDictationSession() {
        gate.beginSession()
    }

    public nonisolated func endDictationSession() {
        gate.endSession()
    }

    public nonisolated func register(_ client: any NetworkPausable) {
        gate.register(client)
    }

    public nonisolated func unregister(_ client: any NetworkPausable) {
        gate.unregister(client)
    }
}
