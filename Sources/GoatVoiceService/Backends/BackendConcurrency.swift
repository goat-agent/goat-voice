import Foundation

struct BackendInferenceOperation: Sendable {
    enum Purpose: Sendable {
        case preview
        case final
    }

    let id = UUID()
    let purpose: Purpose
    let task: Task<String, Error>

    func waitForCompletion() async throws {
        let latch = TranscriptionLatch()
        let task = task
        _ = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                latch.arm(continuation)
                Task {
                    _ = await task.result
                    latch.resume(with: .success(""))
                }
            }
        } onCancel: {
            latch.resume(with: .failure(CancellationError()))
        }
    }
}

struct UncheckedSendableBox<T>: @unchecked Sendable {
    let value: T

    init(_ value: T) {
        self.value = value
    }
}

final class TranscriptionLatch: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<String, Error>?
    private var result: Result<String, Error>?

    func arm(_ continuation: CheckedContinuation<String, Error>) {
        lock.lock()
        let stored = result
        if stored == nil {
            self.continuation = continuation
        }
        lock.unlock()
        if let stored {
            continuation.resume(with: stored)
        }
    }

    func resume(with result: Result<String, Error>) {
        lock.lock()
        guard self.result == nil else {
            lock.unlock()
            return
        }
        self.result = result
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }
}
