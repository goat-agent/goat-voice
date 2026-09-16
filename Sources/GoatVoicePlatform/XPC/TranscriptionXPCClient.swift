import Foundation

public enum XPCClientError: Error, Equatable, Sendable {
    case connectionInvalidated
    case interrupted
    case staleResult
    case cancelled
    case deadlineExceeded
    case backpressureLimit
    case chunkTooLarge(limit: Int)
    case audioLimitExceeded(limit: Int)
    case canonicalReplayRequired
    case sessionUnknown
    case sessionClosed
    case sessionExists
    case sessionLimitExceeded
    case unsupportedProtocolVersion(Int)
    case malformedReply(String)
    case invalidRequest(String)
    case serviceError(code: Int, retryable: Bool, message: String)
    case transportError(String)

    public var serviceErrorKind: GoatVoiceServiceErrorKind? {
        guard case .serviceError(let code, _, _) = self else { return nil }
        return GoatVoiceServiceErrorKind(rawValue: code)
    }
}

final class ReplyGate<Response>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Result<Response, Error>, Never>?
    private var result: Result<Response, Error>?

    func arm(_ continuation: CheckedContinuation<Result<Response, Error>, Never>) {
        lock.lock()
        self.continuation = continuation
        let result = self.result
        if result != nil { self.continuation = nil }
        lock.unlock()
        if let result { continuation.resume(returning: result) }
    }

    func resume(with result: Result<Response, Error>) {
        lock.lock()
        guard self.result == nil else {
            lock.unlock()
            return
        }
        self.result = result
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(returning: result)
    }
}

public actor TranscriptionXPCClient {
    public struct Limits: Sendable, Equatable {
        public var maxPendingPushBytes: Int
        public var maxPendingPushes: Int
        public var maxInflightCalls: Int
        public var maxSessions: Int
        public var maxChunkBytes: Int
        public var maxSessionAudioBytes: Int
        public var handshakeDeadline: Duration
        public var controlDeadline: Duration
        public var loadModelDeadline: Duration
        public var pushAckDeadline: Duration

        public init(maxPendingPushBytes: Int = 8 * 1024 * 1024,
                    maxPendingPushes: Int = 64,
                    maxInflightCalls: Int = 32,
                    maxSessions: Int = GoatVoiceServiceWire.maxSessions,
                    maxChunkBytes: Int = GoatVoiceServiceWire.maxChunkBytes,
                    maxSessionAudioBytes: Int = GoatVoiceServiceWire.maxSessionAudioBytes,
                    handshakeDeadline: Duration = .seconds(10),
                    controlDeadline: Duration = .seconds(10),
                    loadModelDeadline: Duration = GoatVoiceServiceWire.modelLoadWatchdog,
                    pushAckDeadline: Duration = .seconds(10)) {
            self.maxPendingPushBytes = maxPendingPushBytes
            self.maxPendingPushes = maxPendingPushes
            self.maxInflightCalls = maxInflightCalls
            self.maxSessions = maxSessions
            self.maxChunkBytes = maxChunkBytes
            self.maxSessionAudioBytes = maxSessionAudioBytes
            self.handshakeDeadline = handshakeDeadline
            self.controlDeadline = controlDeadline
            self.loadModelDeadline = loadModelDeadline
            self.pushAckDeadline = pushAckDeadline
        }
    }

    public static let maxModelLoadDuration = GoatVoiceServiceWire.modelLoadWatchdog

    private struct SessionState {
        var nextOffset: UInt64 = 0
        var requiresCanonicalReplay = false
        var finishing = false
        var streamError: XPCClientError?
    }

    private struct PendingPush {
        var sessionID: String
        var bytes: Int
        var watchdog: Task<Void, Never>?
    }

    private struct InflightCall {
        var sessionID: String?
        var resolved: XPCClientError?
        var fail: @Sendable (XPCClientError) -> Void
    }

    private let backend: any XPCConnectionBackend
    private let limits: Limits
    private let clock = ContinuousClock()

    private var generation: UInt64 = 0
    private var usable = true
    private var sessions: [String: SessionState] = [:]
    private var beginningSessions: Set<String> = []
    private var tombstonedSessions: Set<String> = []
    private var pendingPushes: [UUID: PendingPush] = [:]
    private var pendingPushByteCount = 0
    private var droppedByteCount = 0
    private var inflight: [UUID: InflightCall] = [:]
    private var serviceInstanceID: String?

    public init(backend: any XPCConnectionBackend, limits: Limits = Limits()) {
        self.backend = backend
        self.limits = limits
        backend.onInterruption { [weak self] in
            Task { await self?.connectionInterrupted() }
        }
        backend.onInvalidation { [weak self] in
            Task { await self?.connectionInvalidated() }
        }
    }

    public var droppedPushBytes: Int { droppedByteCount }
    public var pendingPushBytes: Int { pendingPushByteCount }
    public var pendingPushCount: Int { pendingPushes.count }
    public var inflightCallCount: Int { inflight.count }
    public var currentGeneration: UInt64 { generation }
    public var liveSessionCount: Int { sessions.count + beginningSessions.count }

    public func handshake() async throws -> ServiceHandshake {
        let payload = try await performCall(sessionID: nil, timeout: limits.handshakeDeadline) { proxy, gate in
            proxy.handshake { gate.resume(with: Self.parseHandshake($0)) }
        }
        if serviceInstanceID != payload.serviceInstanceID {
            if serviceInstanceID != nil { dropServiceState() }
            serviceInstanceID = payload.serviceInstanceID
        }
        return payload
    }

    public func loadModel(id: String, directory: URL,
                          deadline: ContinuousClock.Instant? = nil) async throws {
        var timeout = min(limits.loadModelDeadline, Self.maxModelLoadDuration)
        if let deadline {
            let remaining = clock.now.duration(to: deadline)
            guard remaining > .zero else { throw XPCClientError.deadlineExceeded }
            timeout = min(timeout, remaining)
        }
        try await performCall(sessionID: nil, timeout: timeout) { proxy, gate in
            proxy.loadModel(id as NSString, modelDirectory: directory as NSURL) { error in
                gate.resume(with: Self.mapErrorOnlyReply(error))
            }
        }
    }

    public func unloadModel() async throws {
        try await performCall(sessionID: nil, timeout: limits.controlDeadline) { proxy, gate in
            proxy.unloadModel { gate.resume(with: .success(())) }
        }
    }

    public func beginSession(id: String) async throws {
        try ensureUsable()
        guard sessions[id] == nil, !beginningSessions.contains(id) else {
            throw XPCClientError.sessionExists
        }
        if tombstonedSessions.contains(id) { throw XPCClientError.cancelled }
        guard sessions.count + beginningSessions.count < limits.maxSessions else {
            throw XPCClientError.sessionLimitExceeded
        }
        beginningSessions.insert(id)
        defer { beginningSessions.remove(id) }
        do {
            try await performCall(sessionID: id, timeout: limits.controlDeadline) { proxy, gate in
                proxy.beginSession(id as NSString) { error in
                    gate.resume(with: Self.mapErrorOnlyReply(error))
                }
            }
        } catch {
            tombstonedSessions.remove(id)
            sendCancelSession(id)
            throw error
        }
        if tombstonedSessions.remove(id) != nil {
            sendCancelSession(id)
            throw XPCClientError.cancelled
        }
        guard sessions[id] == nil else { throw XPCClientError.staleResult }
        sessions[id] = SessionState()
    }

    public func push(_ chunk: Data, sessionID: String) throws {
        try ensureUsable()
        guard var session = sessions[sessionID] else {
            throw XPCClientError.sessionUnknown
        }
        guard !session.finishing else { throw XPCClientError.sessionClosed }
        do {
            try validate(chunk, for: session)
        } catch {
            droppedByteCount += chunk.count
            session.requiresCanonicalReplay = true
            sessions[sessionID] = session
            throw error
        }
        let token = UUID()
        pendingPushes[token] = PendingPush(sessionID: sessionID, bytes: chunk.count)
        pendingPushByteCount += chunk.count
        let offset = session.nextOffset
        session.nextOffset += UInt64(chunk.count)
        sessions[sessionID] = session
        do {
            let proxy = try backend.remoteObjectProxy { [weak self] error in
                let mapped = Self.mapTransportError(error)
                Task { [weak self] in
                    await self?.pushFailed(token: token, error: mapped)
                }
            }
            proxy.pushAudio(chunk as NSData, sessionID: sessionID as NSString,
                            offset: offset) { [weak self] error in
                let mapped = error.map { Self.mapReplyError($0) }
                Task { await self?.pushAcknowledged(token: token, error: mapped) }
            }
            let ackDeadline = limits.pushAckDeadline
            let watchdog = Task { [weak self, clock] in
                try? await clock.sleep(for: ackDeadline)
                await self?.pushAckTimedOut(token: token)
            }
            pendingPushes[token]?.watchdog = watchdog
        } catch {
            pendingPushes.removeValue(forKey: token)
            pendingPushByteCount -= chunk.count
            droppedByteCount += chunk.count
            if var session = sessions[sessionID] {
                session.nextOffset = offset
                session.requiresCanonicalReplay = true
                sessions[sessionID] = session
            }
            throw Self.mapTransportError(error)
        }
    }

    public func preview(sessionID: String) async throws -> String {
        try ensureUsable()
        guard let session = sessions[sessionID] else { throw XPCClientError.sessionUnknown }
        guard !session.finishing else { throw XPCClientError.sessionClosed }
        let text = try await performCall(sessionID: sessionID, timeout: GoatVoiceServiceWire.previewDeadline) { proxy, gate in
            proxy.previewSession(sessionID as NSString) { text, error in
                gate.resume(with: Self.mapFinishReply(text: text, error: error))
            }
        }
        guard let current = sessions[sessionID], !current.finishing else {
            throw XPCClientError.staleResult
        }
        return text
    }

    public func finish(sessionID: String, canonicalAudio: Data? = nil,
                       deadline: ContinuousClock.Instant) async throws -> String {
        try ensureUsable()
        guard var session = sessions[sessionID] else {
            throw XPCClientError.sessionUnknown
        }
        guard !session.finishing else { throw XPCClientError.sessionClosed }
        if canonicalAudio == nil && session.requiresCanonicalReplay {
            throw XPCClientError.canonicalReplayRequired
        }
        if let canonicalAudio, canonicalAudio.count > limits.maxSessionAudioBytes {
            throw XPCClientError.audioLimitExceeded(limit: limits.maxSessionAudioBytes)
        }
        let remaining = clock.now.duration(to: deadline)
        guard remaining > .zero else {
            sessions.removeValue(forKey: sessionID)
            sendCancelSession(sessionID)
            throw XPCClientError.deadlineExceeded
        }
        session.finishing = true
        sessions[sessionID] = session
        let wireDeadline = Date(timeIntervalSinceNow: remaining.secondsAsTimeInterval)
        do {
            let transcript = try await performCall(sessionID: sessionID, timeout: remaining) { proxy, gate in
                proxy.finishSession(sessionID as NSString,
                                    canonicalAudio: canonicalAudio as NSData?,
                                    deadline: wireDeadline as NSDate) { text, error in
                    gate.resume(with: Self.mapFinishReply(text: text, error: error))
                }
            }
            sessions.removeValue(forKey: sessionID)
            return transcript
        } catch {
            if sessions.removeValue(forKey: sessionID) != nil {
                sendCancelSession(sessionID)
            }
            throw error
        }
    }

    public func cancel(sessionID: String) {
        let wasBeginning = beginningSessions.contains(sessionID)
        if wasBeginning { tombstonedSessions.insert(sessionID) }
        let wasLive = sessions.removeValue(forKey: sessionID) != nil
        guard wasLive || wasBeginning else { return }
        failSessionCalls(sessionID: sessionID, error: .cancelled)
        releaseSessionPushes(sessionID: sessionID)
        if wasLive { sendCancelSession(sessionID) }
    }

    public func invalidate() {
        connectionInvalidated()
        backend.invalidate()
    }

    public func streamRequiresCanonicalReplay(_ sessionID: String) -> Bool {
        sessions[sessionID]?.requiresCanonicalReplay ?? false
    }

    public func streamFailure(_ sessionID: String) -> XPCClientError? {
        sessions[sessionID]?.streamError
    }

    private func validate(_ chunk: Data, for session: SessionState) throws {
        if chunk.isEmpty {
            throw XPCClientError.invalidRequest("empty audio chunk")
        }
        if chunk.count % 2 != 0 {
            throw XPCClientError.invalidRequest("unaligned Int16 PCM chunk")
        }
        if chunk.count > limits.maxChunkBytes {
            throw XPCClientError.chunkTooLarge(limit: limits.maxChunkBytes)
        }
        if UInt64(chunk.count) + session.nextOffset > UInt64(limits.maxSessionAudioBytes) {
            throw XPCClientError.audioLimitExceeded(limit: limits.maxSessionAudioBytes)
        }
        if pendingPushByteCount + chunk.count > limits.maxPendingPushBytes
            || pendingPushes.count >= limits.maxPendingPushes {
            throw XPCClientError.backpressureLimit
        }
    }

    private func performCall<Response: Sendable>(
        sessionID: String?,
        timeout: Duration,
        send: @Sendable (any GoatVoiceServiceXPCProtocol, ReplyGate<Response>) -> Void
    ) async throws -> Response {
        try ensureUsable()
        guard inflight.count < limits.maxInflightCalls else {
            throw XPCClientError.backpressureLimit
        }
        let gate = ReplyGate<Response>()
        let token = UUID()
        inflight[token] = InflightCall(sessionID: sessionID) { error in
            gate.resume(with: .failure(error))
        }
        let watchdog = Task { [clock] in
            try? await clock.sleep(for: timeout)
            gate.resume(with: .failure(XPCClientError.deadlineExceeded))
        }
        let outcome: Result<Response, Error> = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                gate.arm(continuation)
                do {
                    let proxy = try backend.remoteObjectProxy { error in
                        gate.resume(with: .failure(Self.mapTransportError(error)))
                    }
                    send(proxy, gate)
                } catch {
                    gate.resume(with: .failure(Self.mapTransportError(error)))
                }
            }
        } onCancel: {
            gate.resume(with: .failure(CancellationError()))
        }
        watchdog.cancel()
        guard let entry = inflight.removeValue(forKey: token) else {
            throw XPCClientError.staleResult
        }
        if let resolved = entry.resolved, case .success = outcome { throw resolved }
        let response = try outcome.get()
        if Task<Never, Never>.isCancelled { throw CancellationError() }
        return response
    }

    private func pushAcknowledged(token: UUID, error: XPCClientError?) {
        guard let push = pendingPushes.removeValue(forKey: token) else { return }
        push.watchdog?.cancel()
        pendingPushByteCount -= push.bytes
        guard let error, var session = sessions[push.sessionID] else { return }
        droppedByteCount += push.bytes
        session.requiresCanonicalReplay = true
        session.streamError = error
        sessions[push.sessionID] = session
    }

    private func pushFailed(token: UUID, error: XPCClientError) {
        guard let push = pendingPushes.removeValue(forKey: token) else { return }
        push.watchdog?.cancel()
        pendingPushByteCount -= push.bytes
        droppedByteCount += push.bytes
        guard var session = sessions[push.sessionID] else { return }
        session.requiresCanonicalReplay = true
        session.streamError = error
        sessions[push.sessionID] = session
    }

    private func pushAckTimedOut(token: UUID) {
        guard let push = pendingPushes.removeValue(forKey: token) else { return }
        pendingPushByteCount -= push.bytes
        droppedByteCount += push.bytes
        guard var session = sessions[push.sessionID] else { return }
        session.requiresCanonicalReplay = true
        session.streamError = .deadlineExceeded
        sessions[push.sessionID] = session
    }

    private func connectionInterrupted() {
        generation &+= 1
        sweepCalls(error: .interrupted)
        releaseAllPushes()
        sessions.removeAll()
        beginningSessions.removeAll()
        tombstonedSessions.removeAll()
        serviceInstanceID = nil
    }

    private func connectionInvalidated() {
        guard usable else { return }
        usable = false
        generation &+= 1
        sweepCalls(error: .connectionInvalidated)
        releaseAllPushes()
        sessions.removeAll()
        beginningSessions.removeAll()
        tombstonedSessions.removeAll()
        serviceInstanceID = nil
    }

    private func dropServiceState() {
        sweepCalls(error: .staleResult)
        releaseAllPushes()
        sessions.removeAll()
    }

    private func sweepCalls(error: XPCClientError) {
        for token in inflight.keys {
            guard var entry = inflight[token], entry.resolved == nil else { continue }
            entry.resolved = error
            inflight[token] = entry
            entry.fail(error)
        }
    }

    private func failSessionCalls(sessionID: String, error: XPCClientError) {
        let tokens = inflight.compactMap { $0.value.sessionID == sessionID ? $0.key : nil }
        for token in tokens {
            guard var entry = inflight[token], entry.resolved == nil else { continue }
            entry.resolved = error
            inflight[token] = entry
            entry.fail(error)
        }
    }

    private func releaseSessionPushes(sessionID: String) {
        let tokens = pendingPushes.compactMap { $0.value.sessionID == sessionID ? $0.key : nil }
        for token in tokens {
            if let push = pendingPushes.removeValue(forKey: token) {
                push.watchdog?.cancel()
                pendingPushByteCount -= push.bytes
            }
        }
    }

    private func releaseAllPushes() {
        droppedByteCount += pendingPushByteCount
        for push in pendingPushes.values { push.watchdog?.cancel() }
        pendingPushes.removeAll()
        pendingPushByteCount = 0
    }

    private func sendCancelSession(_ sessionID: String) {
        guard usable else { return }
        guard let proxy = try? backend.remoteObjectProxy(errorHandler: { _ in }) else { return }
        proxy.cancelSession(sessionID as NSString)
    }

    private func ensureUsable() throws {
        guard usable else { throw XPCClientError.connectionInvalidated }
    }

    private static func parseHandshake(_ payload: NSDictionary) -> Result<ServiceHandshake, Error> {
        guard let parsed = ServiceHandshake(payload: payload) else {
            return .failure(XPCClientError.malformedReply("handshake"))
        }
        guard parsed.protocolVersion == GoatVoiceServiceWire.protocolVersion else {
            return .failure(XPCClientError.unsupportedProtocolVersion(parsed.protocolVersion))
        }
        return .success(parsed)
    }

    private static func mapErrorOnlyReply(_ error: NSError?) -> Result<Void, Error> {
        if let error { return .failure(mapReplyError(error)) }
        return .success(())
    }

    private static func mapFinishReply(text: NSString?, error: NSError?) -> Result<String, Error> {
        if let error { return .failure(mapReplyError(error)) }
        guard let text else {
            return .failure(XPCClientError.malformedReply("finishSession"))
        }
        return .success(text as String)
    }

    private static func mapReplyError(_ error: NSError) -> XPCClientError {
        error.domain == GoatVoiceServiceWire.errorDomain
            ? mapServiceError(error)
            : mapTransportError(error)
    }

    private static func mapServiceError(_ error: NSError) -> XPCClientError {
        let retryable = (error.userInfo["retryable"] as? Bool)
            ?? (error.userInfo["retryable"] as? NSNumber)?.boolValue
            ?? false
        return .serviceError(code: error.code, retryable: retryable,
                             message: error.localizedDescription)
    }

    private static func mapTransportError(_ error: Error) -> XPCClientError {
        if let clientError = error as? XPCClientError { return clientError }
        let nsError = error as NSError
        if nsError.domain == GoatVoiceServiceWire.errorDomain {
            return mapServiceError(nsError)
        }
        if nsError.domain == NSCocoaErrorDomain {
            switch nsError.code {
            case NSXPCConnectionInterrupted, NSXPCConnectionReplyInvalid:
                return .interrupted
            case NSXPCConnectionInvalid:
                return .connectionInvalidated
            default:
                break
            }
        }
        return .transportError(nsError.localizedDescription)
    }
}

extension Duration {
    var secondsAsTimeInterval: TimeInterval {
        TimeInterval(components.seconds) + TimeInterval(components.attoseconds) / 1e18
    }
}
