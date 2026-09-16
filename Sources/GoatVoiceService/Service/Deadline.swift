import Foundation

final class RaceControl<Response>: @unchecked Sendable {
    private let lock = NSLock()
    private var tasks: [Task<Void, Never>] = []
    private var continuation: CheckedContinuation<Response, Error>?
    private var result: Result<Response, Error>?
    private var resolved = false

    func arm(_ continuation: CheckedContinuation<Response, Error>) {
        lock.lock()
        self.continuation = continuation
        let stored = result
        lock.unlock()
        if let stored {
            continuation.resume(with: stored)
        }
    }

    func register(_ task: Task<Void, Never>) {
        lock.lock()
        if resolved {
            lock.unlock()
            task.cancel()
            return
        }
        tasks.append(task)
        lock.unlock()
    }

    @discardableResult
    func resolve(_ outcome: Result<Response, Error>) -> Bool {
        lock.lock()
        guard !resolved else {
            lock.unlock()
            return false
        }
        resolved = true
        let pending = continuation
        continuation = nil
        let running = tasks
        tasks = []
        if pending == nil {
            result = outcome
        }
        lock.unlock()
        for task in running {
            task.cancel()
        }
        if let pending {
            pending.resume(with: outcome)
        }
        return true
    }

    func cancel() {
        resolve(.failure(CancellationError()))
    }
}

enum Deadline {
    static func race<T: Sendable>(
        until deadline: Date,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let control = RaceControl<T>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let work = Task {
                    do {
                        let value = try await operation()
                        control.resolve(.success(value))
                    } catch {
                        control.resolve(.failure(error))
                    }
                }
                let timer = Task {
                    let interval = deadline.timeIntervalSinceNow
                    if interval > 0 {
                        try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                    }
                    control.resolve(.failure(GoatVoiceServiceError.deadlineExceeded))
                }
                control.register(work)
                control.register(timer)
                control.arm(continuation)
            }
        } onCancel: {
            control.cancel()
        }
    }
}
