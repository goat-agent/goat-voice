import Foundation

final class CancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var observed = false

    var isObserved: Bool {
        lock.withLock { observed }
    }

    func note() {
        lock.withLock { observed = true }
    }

    func reset() {
        lock.withLock { observed = false }
    }
}

enum MainHop {
    static func async(_ body: @escaping @MainActor () -> Void) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated(body)
        }
    }
}

final class ValueCoalescer<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: Value?
    private var scheduled = false

    func push(_ value: Value) -> Bool {
        lock.withLock {
            pending = value
            guard !scheduled else { return false }
            scheduled = true
            return true
        }
    }

    func take() -> Value? {
        lock.withLock {
            scheduled = false
            defer { pending = nil }
            return pending
        }
    }
}
