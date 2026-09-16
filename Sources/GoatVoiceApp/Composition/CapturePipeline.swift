import Foundation
import GoatVoiceCore
import GoatVoicePlatform

final class CapturePipeline: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = CanonicalAudioBuffer()
    private var sessionID: SessionID?
    private var accepting = false

    private let forwarder: PushForwarder
    var onFull: (@Sendable () -> Void)?

    init(client: TranscriptionXPCClient, forwarderQueueLimit: Int = 4 * 1024 * 1024) {
        forwarder = PushForwarder(client: client, byteLimit: forwarderQueueLimit)
    }

    func begin(session id: SessionID) {
        lock.withLock {
            buffer = CanonicalAudioBuffer()
            sessionID = id
            accepting = true
        }
        forwarder.reset(session: id.rawValue.uuidString)
    }

    func serviceSessionReady() {
        forwarder.markReady()
    }

    func serviceSessionFailed() {
        forwarder.markFailed()
    }

    func append(_ chunk: CapturedAudioChunk) {
        let outcome = lock.withLock { () -> CanonicalAudioBuffer.AppendOutcome? in
            guard accepting else { return nil }
            let outcome = buffer.append(chunk.pcm16)
            if outcome == .accepted || outcome == .acceptedReachingLimit {
                forwarder.push(chunk.pcm16)
            }
            return outcome
        }
        guard let outcome else { return }
        if outcome == .acceptedReachingLimit || outcome == .rejectedFull {
            onFull?()
        }
    }

    func stopAccepting() {
        lock.withLock { accepting = false }
    }

    func canonicalPCM16() -> Data {
        lock.withLock { buffer.pcm16 }
    }

    func discard() {
        lock.withLock {
            buffer.discard()
            accepting = false
            sessionID = nil
        }
        forwarder.reset(session: nil)
    }
}

final class PushForwarder: @unchecked Sendable {
    private let client: TranscriptionXPCClient
    private let byteLimit: Int
    private let lock = NSLock()
    private var sessionID: String?
    private var generation: UInt64 = 0
    private var ready = false
    private var failed = false
    private var queued: [Data] = []
    private var queuedBytes = 0
    private var draining = false

    init(client: TranscriptionXPCClient, byteLimit: Int) {
        self.client = client
        self.byteLimit = byteLimit
    }

    func reset(session id: String?) {
        lock.withLock {
            generation &+= 1
            sessionID = id
            ready = false
            failed = false
            queued.removeAll()
            queuedBytes = 0
        }
    }

    func markReady() {
        lock.withLock {
            guard sessionID != nil, !failed else { return }
            ready = true
        }
        kickDrain()
    }

    func markFailed() {
        lock.withLock {
            failed = true
            queued.removeAll()
            queuedBytes = 0
        }
    }

    func push(_ data: Data) {
        lock.withLock {
            guard sessionID != nil, !failed,
                  queuedBytes + data.count <= byteLimit else { return }
            queued.append(data)
            queuedBytes += data.count
        }
        kickDrain()
    }

    private func kickDrain() {
        let shouldStart = lock.withLock { () -> Bool in
            guard !draining, ready, sessionID != nil, !queued.isEmpty else { return false }
            draining = true
            return true
        }
        if shouldStart {
            Task { await drain() }
        }
    }

    private func drain() async {
        while true {
            let next = lock.withLock { () -> (String, Data, UInt64)? in
                guard ready, let id = sessionID, !queued.isEmpty else { return nil }
                let data = queued.removeFirst()
                queuedBytes -= data.count
                return (id, data, generation)
            }
            guard let next else { break }
            do {
                try await client.push(next.1, sessionID: next.0)
            } catch XPCClientError.backpressureLimit {
                continue
            } catch {
                failGeneration(next.2)
                break
            }
        }
        lock.withLock { draining = false }
        kickDrain()
    }

    private func failGeneration(_ generation: UInt64) {
        lock.withLock {
            guard self.generation == generation else { return }
            failed = true
            queued.removeAll()
            queuedBytes = 0
        }
    }
}
