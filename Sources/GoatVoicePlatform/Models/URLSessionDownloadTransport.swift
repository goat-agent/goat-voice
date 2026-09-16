import Foundation

public final class URLSessionDownloadTransport: NSObject, NetworkTransport, URLSessionDownloadDelegate,
                                                @unchecked Sendable {
    private struct ActiveTransfer {
        var task: URLSessionDownloadTask
        var destination: URL
        var progress: @Sendable (Int64) -> Void
        var completion: CheckedContinuation<Void, any Error>
        var deadline: ContinuousClock.Instant
        var generation: UInt64
    }

    private struct PauseWaiter {
        var generation: UInt64
        var continuation: CheckedContinuation<Data?, Never>
    }

    private let gate: NetworkSessionGate
    private var session: URLSession!
    private let requestTimeout: TimeInterval
    private let stallLimit: Duration
    private let clock = ContinuousClock()
    private let delegateQueue: OperationQueue

    private let lock = NSLock()
    private var transfer: ActiveTransfer?
    private var pauseWaiter: PauseWaiter?
    private var transferReserved = false
    private var generation: UInt64 = 0

    public init(gate: NetworkSessionGate = NetworkSessionGate(),
                configuration: URLSessionConfiguration? = nil,
                requestTimeout: TimeInterval = 60,
                stallLimit: Duration = .seconds(30)) {
        self.gate = gate
        self.requestTimeout = requestTimeout
        self.stallLimit = stallLimit
        let config = configuration ?? .ephemeral
        config.timeoutIntervalForRequest = requestTimeout
        delegateQueue = OperationQueue()
        delegateQueue.maxConcurrentOperationCount = 1
        super.init()
        session = URLSession(configuration: config, delegate: self, delegateQueue: delegateQueue)
    }

    deinit {
        let pending = lock.withLock { () -> (CheckedContinuation<Void, any Error>?, CheckedContinuation<Data?, Never>?) in
            let pending = (transfer?.completion, pauseWaiter?.continuation)
            transfer = nil
            pauseWaiter = nil
            return pending
        }
        session.invalidateAndCancel()
        pending.0?.resume(throwing: NetworkTransportError.cancelled)
        pending.1?.resume(returning: nil)
    }

    public func download(_ url: URL, to destination: URL,
                         progress: @escaping @Sendable (Int64) -> Void) async throws {
        guard gate.allowsNewNetworkWork else { throw NetworkTransportError.blockedByActiveSession }
        let request = URLRequest(url: url, timeoutInterval: requestTimeout)
        try await run(destination: destination, progress: progress) {
            self.session.downloadTask(with: request)
        }
    }

    public func resume(with resumeData: Data, to destination: URL,
                       progress: @escaping @Sendable (Int64) -> Void) async throws {
        guard gate.allowsNewNetworkWork else { throw NetworkTransportError.blockedByActiveSession }
        try await run(destination: destination, progress: progress) {
            self.session.downloadTask(withResumeData: resumeData)
        }
    }

    public func pause() async -> Data? {
        let pending = lock.withLock { () -> (URLSessionDownloadTask, UInt64)? in
            guard let active = transfer, pauseWaiter == nil else { return nil }
            return (active.task, active.generation)
        }
        guard let (task, generation) = pending else { return nil }
        return await withCheckedContinuation { continuation in
            let armed = lock.withLock { () -> Bool in
                guard transfer?.generation == generation, pauseWaiter == nil else { return false }
                pauseWaiter = PauseWaiter(generation: generation, continuation: continuation)
                return true
            }
            guard armed else {
                continuation.resume(returning: nil)
                return
            }
            task.cancel(byProducingResumeData: { [weak self] data in
                self?.settlePauseWaiter(with: data, generation: generation)
            })
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(5))
                self?.settlePauseWaiter(with: nil, generation: generation)
            }
        }
    }

    public func cancel() {
        dropTransfer()
    }

    public func invalidate() {
        dropTransfer()
        session.invalidateAndCancel()
    }

    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                           didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                           totalBytesExpectedToWrite: Int64) {
        let progress = lock.withLock { () -> (@Sendable (Int64) -> Void)? in
            guard var active = transfer, active.task === downloadTask else { return nil }
            active.deadline = clock.now.advanced(by: stallLimit)
            transfer = active
            return active.progress
        }
        progress?(totalBytesWritten)
    }

    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                           didFinishDownloadingTo location: URL) {
        let taken = lock.withLock { () -> ActiveTransfer? in
            guard let active = transfer, active.task === downloadTask else { return nil }
            transfer = nil
            return active
        }
        guard let taken else { return }
        do {
            let manager = FileManager.default
            try manager.createDirectory(at: taken.destination.deletingLastPathComponent(),
                                        withIntermediateDirectories: true)
            if manager.fileExists(atPath: taken.destination.path) {
                try manager.removeItem(at: taken.destination)
            }
            try manager.moveItem(at: location, to: taken.destination)
            taken.completion.resume()
        } catch {
            taken.completion.resume(throwing: NetworkTransportError.relocationFailed(underlying: error))
        }
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask,
                           didCompleteWithError error: (any Error)?) {
        let taken = lock.withLock { () -> ActiveTransfer? in
            guard let active = transfer, active.task === task else { return nil }
            transfer = nil
            return active
        }
        guard let taken else { return }
        switch error {
        case .none:
            taken.completion.resume(throwing: NetworkTransportError.missingDownloadedFile)
        case .some(let failure) where (failure as? URLError)?.code == .cancelled:
            taken.completion.resume(throwing: NetworkTransportError.cancelled)
        case .some(let failure):
            taken.completion.resume(throwing: NetworkTransportError.downloadFailed(underlying: failure))
        }
    }

    private func run(destination: URL, progress: @escaping @Sendable (Int64) -> Void,
                     makeTask: () -> URLSessionDownloadTask) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let reservation = lock.withLock { () -> NetworkTransportError? in
                    if Task.isCancelled { return .cancelled }
                    guard transfer == nil, !transferReserved else { return .alreadyActive }
                    transferReserved = true
                    return nil
                }
                if let failure = reservation {
                    continuation.resume(throwing: failure)
                    return
                }

                let task = makeTask()

                enum Outcome { case started(UInt64), failed(any Error) }
                let outcome = lock.withLock { () -> Outcome in
                    transferReserved = false
                    if let stale = pauseWaiter {
                        pauseWaiter = nil
                        stale.continuation.resume(returning: nil)
                    }
                    if Task.isCancelled { return .failed(NetworkTransportError.cancelled) }
                    let started = gate.performStart { task.resume() }
                    guard started else { return .failed(NetworkTransportError.blockedByActiveSession) }
                    generation &+= 1
                    transfer = ActiveTransfer(
                        task: task, destination: destination, progress: progress,
                        completion: continuation,
                        deadline: clock.now.advanced(by: stallLimit),
                        generation: generation)
                    return .started(generation)
                }
                switch outcome {
                case .started(let startedGeneration):
                    watchDeadline(generation: startedGeneration)
                case .failed(let failure):
                    task.cancel()
                    continuation.resume(throwing: failure)
                }
            }
        } onCancel: {
            dropTransfer()
        }
    }

    private func dropTransfer() {
        let taken = lock.withLock { () -> (ActiveTransfer?, PauseWaiter?) in
            guard let active = transfer else { return (nil, nil) }
            transfer = nil
            let waiter = pauseWaiter
            pauseWaiter = nil
            return (active, waiter)
        }
        taken.0?.task.cancel()
        taken.1?.continuation.resume(returning: nil)
        taken.0?.completion.resume(throwing: NetworkTransportError.cancelled)
    }

    private func settlePauseWaiter(with data: Data?, generation: UInt64) {
        let waiter = lock.withLock { () -> CheckedContinuation<Data?, Never>? in
            guard let pending = pauseWaiter, pending.generation == generation else { return nil }
            pauseWaiter = nil
            return pending.continuation
        }
        waiter?.resume(returning: data)
    }

    private func watchDeadline(generation watched: UInt64) {
        let milliseconds = stallLimit.components.seconds * 1_000
            + stallLimit.components.attoseconds / 1_000_000_000_000_000
        let poll = Duration.milliseconds(min(max(milliseconds / 4, 50), 5_000))
        Task { [weak self] in
            while let self {
                try? await Task.sleep(for: poll)
                enum Step { case exit, wait, fire(URLSessionDownloadTask, CheckedContinuation<Void, any Error>) }
                let step = self.lock.withLock { () -> Step in
                    guard let active = self.transfer, active.generation == watched else { return .exit }
                    guard self.clock.now >= active.deadline else { return .wait }
                    self.transfer = nil
                    return .fire(active.task, active.completion)
                }
                switch step {
                case .exit:
                    return
                case .wait:
                    continue
                case .fire(let task, let completion):
                    task.cancel()
                    settlePauseWaiter(with: nil, generation: watched)
                    completion.resume(throwing: NetworkTransportError.stalled)
                    return
                }
            }
        }
    }
}
