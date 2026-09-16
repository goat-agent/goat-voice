import XCTest
@testable import GoatVoicePlatform

final class FakeGoatVoiceService: @unchecked Sendable {
    private let lock = NSLock()

    var serviceInstanceID = "service-instance-A"
    var sendError: Error?

    var onHandshake: ((@escaping (NSDictionary) -> Void) -> Void)?
    var onLoadModel: ((NSString, NSURL, @escaping (NSError?) -> Void) -> Void)?
    var onUnloadModel: ((@escaping () -> Void) -> Void)?
    var onBeginSession: ((NSString, @escaping (NSError?) -> Void) -> Void)?
    var onPushAudio: ((NSData, NSString, UInt64, @escaping (NSError?) -> Void) -> Void)?
    var onPreviewSession: ((NSString, @escaping (NSString?, NSError?) -> Void) -> Void)?
    var onFinishSession: ((NSString, NSData?, NSDate, @escaping (NSString?, NSError?) -> Void) -> Void)?
    var onCancelSession: ((NSString) -> Void)?

    private var _handshakeCalls = 0
    private var _begins: [String] = []
    private var _pushes: [(chunk: Data, sessionID: String, offset: UInt64)] = []
    private var _finishes: [(sessionID: String, canonical: Data?, deadline: Date)] = []
    private var _cancelled: [String] = []
    private var _loads: [(modelID: String, directory: URL)] = []

    var handshakeCallCount: Int { lock.withLock { _handshakeCalls } }
    var beganSessions: [String] { lock.withLock { _begins } }
    var pushedChunks: [(chunk: Data, sessionID: String, offset: UInt64)] { lock.withLock { _pushes } }
    var finishedSessions: [(sessionID: String, canonical: Data?, deadline: Date)] { lock.withLock { _finishes } }
    var cancelledSessions: [String] { lock.withLock { _cancelled } }
    var loadedModels: [(modelID: String, directory: URL)] { lock.withLock { _loads } }

    private func gate(_ errorHandler: @Sendable (Error) -> Void) -> Bool {
        let error = lock.withLock { sendError }
        if let error {
            errorHandler(error)
            return false
        }
        return true
    }

    func handshake(proxy: FakeRemoteProxy, reply: @escaping (NSDictionary) -> Void) {
        guard gate(proxy.errorHandler) else { return }
        lock.withLock { _handshakeCalls += 1 }
        if let onHandshake { onHandshake(reply); return }
        reply([
            "protocolVersion": NSNumber(value: GoatVoiceServiceWire.protocolVersion),
            "serviceInstanceID": serviceInstanceID as NSString,
            "modelID": "whisper-large-v3-turbo" as NSString,
            "modelState": "loaded" as NSString,
            "engines": ["whisper-large-v3-turbo": "available"] as NSDictionary,
        ])
    }

    func loadModel(_ modelID: NSString, modelDirectory: NSURL,
                   proxy: FakeRemoteProxy, reply: @escaping (NSError?) -> Void) {
        guard gate(proxy.errorHandler) else { return }
        lock.withLock { _loads.append((modelID as String, modelDirectory as URL)) }
        if let onLoadModel { onLoadModel(modelID, modelDirectory, reply); return }
        reply(nil)
    }

    func unloadModel(proxy: FakeRemoteProxy, reply: @escaping () -> Void) {
        guard gate(proxy.errorHandler) else { return }
        if let onUnloadModel { onUnloadModel(reply); return }
        reply()
    }

    func beginSession(_ sessionID: NSString, proxy: FakeRemoteProxy,
                      reply: @escaping (NSError?) -> Void) {
        guard gate(proxy.errorHandler) else { return }
        lock.withLock { _begins.append(sessionID as String) }
        if let onBeginSession { onBeginSession(sessionID, reply); return }
        reply(nil)
    }

    func pushAudio(_ chunk: NSData, sessionID: NSString, offset: UInt64,
                   proxy: FakeRemoteProxy, reply: @escaping (NSError?) -> Void) {
        guard gate(proxy.errorHandler) else { return }
        lock.withLock { _pushes.append((chunk as Data, sessionID as String, offset)) }
        if let onPushAudio { onPushAudio(chunk, sessionID, offset, reply); return }
        reply(nil)
    }

    func finishSession(_ sessionID: NSString, canonicalAudio: NSData?, deadline: NSDate,
                       proxy: FakeRemoteProxy, reply: @escaping (NSString?, NSError?) -> Void) {
        guard gate(proxy.errorHandler) else { return }
        lock.withLock {
            _finishes.append((sessionID as String, canonicalAudio as Data?, deadline as Date))
        }
        if let onFinishSession { onFinishSession(sessionID, canonicalAudio, deadline, reply); return }
        reply("fake transcript", nil)
    }

    func cancelSession(_ sessionID: NSString, proxy: FakeRemoteProxy) {
        guard gate(proxy.errorHandler) else { return }
        lock.withLock { _cancelled.append(sessionID as String) }
        onCancelSession?(sessionID)
    }
}

final class FakeRemoteProxy: NSObject, GoatVoiceServiceXPCProtocol {
    let service: FakeGoatVoiceService
    let errorHandler: @Sendable (Error) -> Void

    init(service: FakeGoatVoiceService, errorHandler: @escaping @Sendable (Error) -> Void) {
        self.service = service
        self.errorHandler = errorHandler
    }

    func handshake(reply: @escaping (NSDictionary) -> Void) {
        service.handshake(proxy: self, reply: reply)
    }

    func loadModel(_ modelID: NSString, modelDirectory: NSURL,
                   reply: @escaping (NSError?) -> Void) {
        service.loadModel(modelID, modelDirectory: modelDirectory, proxy: self, reply: reply)
    }

    func unloadModel(reply: @escaping () -> Void) {
        service.unloadModel(proxy: self, reply: reply)
    }

    func beginSession(_ sessionID: NSString, reply: @escaping (NSError?) -> Void) {
        service.beginSession(sessionID, proxy: self, reply: reply)
    }

    func pushAudio(_ chunk: NSData, sessionID: NSString, offset: UInt64,
                   reply: @escaping (NSError?) -> Void) {
        service.pushAudio(chunk, sessionID: sessionID, offset: offset, proxy: self, reply: reply)
    }

    func previewSession(_ sessionID: NSString,
                        reply: @escaping (NSString?, NSError?) -> Void) {
        if let handler = service.onPreviewSession { handler(sessionID, reply); return }
        reply("", nil)
    }

    func finishSession(_ sessionID: NSString, canonicalAudio: NSData?, deadline: NSDate,
                       reply: @escaping (NSString?, NSError?) -> Void) {
        service.finishSession(sessionID, canonicalAudio: canonicalAudio, deadline: deadline,
                              proxy: self, reply: reply)
    }

    func cancelSession(_ sessionID: NSString) {
        service.cancelSession(sessionID, proxy: self)
    }
}

final class FakeXPCBackend: XPCConnectionBackend, @unchecked Sendable {
    let service = FakeGoatVoiceService()

    private let lock = NSLock()
    private var interruptionHandler: (@Sendable () -> Void)?
    private var invalidationHandler: (@Sendable () -> Void)?
    private var _proxyRequests = 0
    private var _invalidated = false
    private var _resumed = false

    var proxyFactoryError: Error?

    var proxyRequestCount: Int { lock.withLock { _proxyRequests } }
    var wasInvalidated: Bool { lock.withLock { _invalidated } }
    var wasResumed: Bool { lock.withLock { _resumed } }

    func remoteObjectProxy(
        errorHandler: @escaping @Sendable (Error) -> Void
    ) throws -> any GoatVoiceServiceXPCProtocol {
        try lock.withLock {
            _proxyRequests += 1
            if let proxyFactoryError { throw proxyFactoryError }
        }
        return FakeRemoteProxy(service: service, errorHandler: errorHandler)
    }

    func onInterruption(_ handler: @escaping @Sendable () -> Void) {
        lock.withLock { interruptionHandler = handler }
    }

    func onInvalidation(_ handler: @escaping @Sendable () -> Void) {
        lock.withLock { invalidationHandler = handler }
    }

    func resume() {
        lock.withLock { _resumed = true }
    }

    func invalidate() {
        lock.withLock { _invalidated = true }
    }

    func simulateInterruption() {
        lock.withLock { interruptionHandler }?()
    }

    func simulateInvalidation() {
        lock.withLock { invalidationHandler }?()
    }
}

final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value?
    var value: Value? {
        get { lock.withLock { storage } }
        set { lock.withLock { storage = newValue } }
    }
}

final class XPCClientTests: XCTestCase {
    private func makeClient(
        limits: TranscriptionXPCClient.Limits = TranscriptionXPCClient.Limits(
            handshakeDeadline: .milliseconds(400),
            controlDeadline: .milliseconds(400),
            loadModelDeadline: .milliseconds(400),
            pushAckDeadline: .milliseconds(300))
    ) -> (TranscriptionXPCClient, FakeXPCBackend, FakeGoatVoiceService) {
        let backend = FakeXPCBackend()
        let client = TranscriptionXPCClient(backend: backend, limits: limits)
        return (client, backend, backend.service)
    }

    private func waitUntil(_ timeout: Duration = .seconds(3),
                           _ condition: () async -> Bool) async -> Bool {
        let clock = ContinuousClock()
        let end = clock.now.advanced(by: timeout)
        while clock.now < end {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return await condition()
    }

    private func serviceError(_ code: Int, retryable: Bool = false) -> NSError {
        NSError(domain: GoatVoiceServiceWire.errorDomain, code: code,
                userInfo: [NSLocalizedDescriptionKey: "fake", "retryable": retryable])
    }

    func testHandshakeParsesServicePayload() async throws {
        let (client, _, _) = makeClient()
        let info = try await client.handshake()
        XCTAssertEqual(info.protocolVersion, 2)
        XCTAssertEqual(info.serviceInstanceID, "service-instance-A")
        XCTAssertEqual(info.modelID, "whisper-large-v3-turbo")
        XCTAssertEqual(info.modelState, .loaded)
        XCTAssertEqual(info.engines, ["whisper-large-v3-turbo": true])
    }

    func testPreviewReplyAfterFinalCannotEscape() async throws {
        let (client, _, service) = makeClient()
        let reply = LockedBox<(NSString?, NSError?) -> Void>()
        service.onPreviewSession = { _, callback in reply.value = callback }
        try await client.beginSession(id: "s")
        let pending = Task { try await client.preview(sessionID: "s") }
        let requested = await waitUntil { reply.value != nil }
        XCTAssertTrue(requested)
        _ = try await client.finish(sessionID: "s", canonicalAudio: Data(),
                                    deadline: .now + .seconds(1))
        reply.value?("late interim", nil)
        do {
            _ = try await pending.value
            XCTFail("Completed session must reject late preview")
        } catch {
            XCTAssertEqual(error as? XPCClientError, .staleResult)
        }
    }

    func testCancellingPreviewRequestKeepsSessionUsableForFinal() async throws {
        let (client, _, service) = makeClient()
        let reply = LockedBox<(NSString?, NSError?) -> Void>()
        service.onPreviewSession = { _, callback in reply.value = callback }
        try await client.beginSession(id: "s")
        let pending = Task { try await client.preview(sessionID: "s") }
        let requested = await waitUntil { reply.value != nil }
        XCTAssertTrue(requested)
        pending.cancel()
        do {
            _ = try await pending.value
            XCTFail("Preview cancellation must return")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        let final = try await client.finish(sessionID: "s", canonicalAudio: Data(),
                                            deadline: .now + .seconds(1))
        reply.value?("late interim", nil)
        XCTAssertEqual(final, "fake transcript")
        XCTAssertTrue(service.cancelledSessions.isEmpty)
    }

    func testHandshakeTimesOutOnServiceSilence() async {
        let (client, _, service) = makeClient()
        service.onHandshake = { _ in }
        do {
            _ = try await client.handshake()
            XCTFail("expected deadlineExceeded")
        } catch let error as XPCClientError {
            XCTAssertEqual(error, .deadlineExceeded)
        } catch { XCTFail("unexpected \(error)") }
    }

    func testHandshakeRejectsUnsupportedVersion() async {
        let (client, _, service) = makeClient()
        service.onHandshake = { reply in
            reply(["protocolVersion": NSNumber(value: 99),
                   "serviceInstanceID": "service-instance-A"])
        }
        do {
            _ = try await client.handshake()
            XCTFail("expected unsupportedProtocolVersion")
        } catch let error as XPCClientError {
            XCTAssertEqual(error, .unsupportedProtocolVersion(99))
        } catch { XCTFail("unexpected \(error)") }
    }

    func testLoadModelMapsServiceError() async {
        let (client, _, service) = makeClient()
        service.onLoadModel = { _, _, reply in reply(self.serviceError(8, retryable: true)) }
        do {
            try await client.loadModel(id: "m", directory: URL(fileURLWithPath: "/tmp/m"))
            XCTFail("expected serviceError")
        } catch let error as XPCClientError {
            guard case .serviceError(let code, let retryable, _) = error else {
                return XCTFail("unexpected \(error)")
            }
            XCTAssertEqual(code, 8)
            XCTAssertTrue(retryable)
            XCTAssertEqual(error.serviceErrorKind, .busyLoading)
        } catch { XCTFail("unexpected \(error)") }
    }

    func testLoadModelWatchdogFiresOnSilence() async {
        let (client, _, service) = makeClient()
        service.onLoadModel = { _, _, _ in }
        XCTAssertEqual(TranscriptionXPCClient.maxModelLoadDuration, .seconds(60))
        do {
            try await client.loadModel(id: "m", directory: URL(fileURLWithPath: "/tmp/m"))
            XCTFail("expected deadlineExceeded")
        } catch let error as XPCClientError {
            XCTAssertEqual(error, .deadlineExceeded)
        } catch { XCTFail("unexpected \(error)") }
    }

    func testLoadModelHonorsEarlierCallerDeadline() async {
        let (client, _, service) = makeClient()
        service.onLoadModel = { _, _, _ in }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .milliseconds(120))
        do {
            try await client.loadModel(id: "m", directory: URL(fileURLWithPath: "/tmp/m"),
                                       deadline: deadline)
            XCTFail("expected deadlineExceeded")
        } catch let error as XPCClientError {
            XCTAssertEqual(error, .deadlineExceeded)
            XCTAssertLessThan(clock.now, deadline.advanced(by: .milliseconds(400)))
        } catch { XCTFail("unexpected \(error)") }
    }

    func testLoadModelPastDeadlineFailsImmediately() async {
        let (client, _, service) = makeClient()
        service.onLoadModel = { _, _, _ in XCTFail("must not reach service") }
        do {
            try await client.loadModel(id: "m", directory: URL(fileURLWithPath: "/tmp/m"),
                                       deadline: ContinuousClock().now)
            XCTFail("expected deadlineExceeded")
        } catch let error as XPCClientError {
            XCTAssertEqual(error, .deadlineExceeded)
        } catch { XCTFail("unexpected \(error)") }
    }

    func testBeginSessionSendsClientGeneratedID() async throws {
        let (client, _, service) = makeClient()
        try await client.beginSession(id: "session-1")
        XCTAssertEqual(service.beganSessions, ["session-1"])
    }

    func testSecondConcurrentSessionRejected() async throws {
        let (client, _, _) = makeClient()
        try await client.beginSession(id: "session-1")
        do {
            try await client.beginSession(id: "session-2")
            XCTFail("expected sessionLimitExceeded")
        } catch let error as XPCClientError {
            XCTAssertEqual(error, .sessionLimitExceeded)
        } catch { XCTFail("unexpected \(error)") }
    }

    func testDuplicateBeginRejected() async throws {
        let (client, _, _) = makeClient()
        try await client.beginSession(id: "session-1")
        do {
            try await client.beginSession(id: "session-1")
            XCTFail("expected sessionExists")
        } catch let error as XPCClientError {
            XCTAssertEqual(error, .sessionExists)
        } catch { XCTFail("unexpected \(error)") }
    }

    func testPushTracksContiguousOffsets() async throws {
        let (client, _, service) = makeClient()
        try await client.beginSession(id: "s")
        try await client.push(Data(repeating: 1, count: 4), sessionID: "s")
        try await client.push(Data(repeating: 2, count: 6), sessionID: "s")
        try await client.push(Data(repeating: 3, count: 2), sessionID: "s")
        XCTAssertEqual(service.pushedChunks.map(\.offset), [0, 4, 10])
        let drained = await waitUntil { await client.pendingPushBytes == 0 }
        XCTAssertTrue(drained)
    }

    func testPushValidatesChunkShapeAndSession() async throws {
        let (client, _, _) = makeClient()
        do {
            try await client.push(Data(repeating: 0, count: 4), sessionID: "ghost")
            XCTFail("expected sessionUnknown")
        } catch let error as XPCClientError {
            XCTAssertEqual(error, .sessionUnknown)
        } catch { XCTFail("unexpected \(error)") }
        try await client.beginSession(id: "s")
        do {
            try await client.push(Data(), sessionID: "s")
            XCTFail("expected invalidRequest")
        } catch let error as XPCClientError {
            guard case .invalidRequest = error else { return XCTFail("unexpected \(error)") }
        } catch { XCTFail("unexpected \(error)") }
        do {
            try await client.push(Data(repeating: 0, count: 3), sessionID: "s")
            XCTFail("expected invalidRequest")
        } catch let error as XPCClientError {
            guard case .invalidRequest = error else { return XCTFail("unexpected \(error)") }
        } catch { XCTFail("unexpected \(error)") }
        do {
            try await client.push(Data(repeating: 0, count: GoatVoiceServiceWire.maxChunkBytes + 2),
                                  sessionID: "s")
            XCTFail("expected chunkTooLarge")
        } catch let error as XPCClientError {
            XCTAssertEqual(error, .chunkTooLarge(limit: GoatVoiceServiceWire.maxChunkBytes))
        } catch { XCTFail("unexpected \(error)") }
    }

    func testPushEnforcesCumulativeSessionAudioBound() async throws {
        var limits = TranscriptionXPCClient.Limits(pushAckDeadline: .milliseconds(300))
        limits.maxSessionAudioBytes = 8
        let (client, _, _) = makeClient(limits: limits)
        try await client.beginSession(id: "s")
        try await client.push(Data(repeating: 0, count: 8), sessionID: "s")
        do {
            try await client.push(Data(repeating: 0, count: 2), sessionID: "s")
            XCTFail("expected audioLimitExceeded")
        } catch let error as XPCClientError {
            XCTAssertEqual(error, .audioLimitExceeded(limit: 8))
        } catch { XCTFail("unexpected \(error)") }
        let degraded = await client.streamRequiresCanonicalReplay("s")
        XCTAssertTrue(degraded)
    }

    func testPushBackpressureRequiresCanonicalReplay() async throws {
        var limits = TranscriptionXPCClient.Limits(pushAckDeadline: .seconds(30))
        limits.maxPendingPushBytes = 8
        let (client, _, service) = makeClient(limits: limits)
        service.onPushAudio = { _, _, _, _ in }
        try await client.beginSession(id: "s")
        try await client.push(Data(repeating: 0, count: 4), sessionID: "s")
        try await client.push(Data(repeating: 0, count: 4), sessionID: "s")
        do {
            try await client.push(Data(repeating: 0, count: 4), sessionID: "s")
            XCTFail("expected backpressureLimit")
        } catch let error as XPCClientError {
            XCTAssertEqual(error, .backpressureLimit)
        } catch { XCTFail("unexpected \(error)") }
        let dropped = await client.droppedPushBytes
        XCTAssertEqual(dropped, 4)
        let degraded = await client.streamRequiresCanonicalReplay("s")
        XCTAssertTrue(degraded)
        do {
            _ = try await client.finish(sessionID: "s",
                                        deadline: ContinuousClock().now.advanced(by: .seconds(5)))
            XCTFail("expected canonicalReplayRequired")
        } catch let error as XPCClientError {
            XCTAssertEqual(error, .canonicalReplayRequired)
        } catch { XCTFail("unexpected \(error)") }
        let canonical = Data(repeating: 7, count: 12)
        let transcript = try await client.finish(
            sessionID: "s", canonicalAudio: canonical,
            deadline: ContinuousClock().now.advanced(by: .seconds(5)))
        XCTAssertEqual(transcript, "fake transcript")
        XCTAssertEqual(service.finishedSessions.last?.canonical, canonical)
    }

    func testPushAckErrorDegradesStream() async throws {
        let (client, _, service) = makeClient()
        service.onPushAudio = { _, _, _, reply in reply(self.serviceError(15)) }
        try await client.beginSession(id: "s")
        try await client.push(Data(repeating: 0, count: 4), sessionID: "s")
        let degraded = await waitUntil { await client.streamRequiresCanonicalReplay("s") }
        XCTAssertTrue(degraded)
        let failure = await client.streamFailure("s")
        XCTAssertEqual(failure, .serviceError(code: 15, retryable: false, message: "fake"))
        let drained = await waitUntil { await client.pendingPushBytes == 0 }
        XCTAssertTrue(drained)
    }

    func testPushAckTimeoutReleasesPendingAndDegrades() async throws {
        var limits = TranscriptionXPCClient.Limits(pushAckDeadline: .milliseconds(150))
        limits.maxPendingPushBytes = 8
        let (client, _, service) = makeClient(limits: limits)
        service.onPushAudio = { _, _, _, _ in }
        try await client.beginSession(id: "s")
        try await client.push(Data(repeating: 0, count: 4), sessionID: "s")
        try await client.push(Data(repeating: 0, count: 4), sessionID: "s")
        let drained = await waitUntil { await client.pendingPushBytes == 0 }
        XCTAssertTrue(drained)
        let dropped = await client.droppedPushBytes
        XCTAssertEqual(dropped, 8)
        let degraded = await client.streamRequiresCanonicalReplay("s")
        XCTAssertTrue(degraded)
        let failure = await client.streamFailure("s")
        XCTAssertEqual(failure, .deadlineExceeded)
        do {
            try await client.push(Data(repeating: 0, count: 4), sessionID: "s")
        } catch { XCTFail("push after drain should be admitted: \(error)") }
    }

    func testAckedPushWatchdogDoesNotDegrade() async throws {
        let limits = TranscriptionXPCClient.Limits(pushAckDeadline: .milliseconds(200))
        let (client, _, _) = makeClient(limits: limits)
        try await client.beginSession(id: "s")
        try await client.push(Data(repeating: 0, count: 4), sessionID: "s")
        try? await Task.sleep(for: .milliseconds(450))
        let degraded = await client.streamRequiresCanonicalReplay("s")
        XCTAssertFalse(degraded)
        let dropped = await client.droppedPushBytes
        XCTAssertEqual(dropped, 0)
    }

    func testFinishReturnsTranscript() async throws {
        let (client, _, service) = makeClient()
        try await client.beginSession(id: "s")
        let transcript = try await client.finish(
            sessionID: "s", deadline: ContinuousClock().now.advanced(by: .seconds(5)))
        XCTAssertEqual(transcript, "fake transcript")
        XCTAssertEqual(service.finishedSessions.count, 1)
        XCTAssertNil(service.finishedSessions.first?.canonical)
        XCTAssertGreaterThan(service.finishedSessions.first!.deadline, Date())
        do {
            _ = try await client.finish(sessionID: "s",
                                        deadline: ContinuousClock().now.advanced(by: .seconds(5)))
            XCTFail("expected sessionUnknown")
        } catch let error as XPCClientError {
            XCTAssertEqual(error, .sessionUnknown)
        } catch { XCTFail("unexpected \(error)") }
    }

    func testFinishCompletesOnServiceSilence() async throws {
        let (client, _, service) = makeClient()
        service.onFinishSession = { _, _, _, _ in }
        try await client.beginSession(id: "s")
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .milliseconds(250))
        do {
            _ = try await client.finish(sessionID: "s", deadline: deadline)
            XCTFail("expected deadlineExceeded")
        } catch let error as XPCClientError {
            XCTAssertEqual(error, .deadlineExceeded)
        } catch { XCTFail("unexpected \(error)") }
        XCTAssertLessThan(clock.now, deadline.advanced(by: .seconds(2)))
        XCTAssertEqual(service.cancelledSessions, ["s"])
    }

    func testFinishPastDeadlineFailsFast() async throws {
        let (client, _, service) = makeClient()
        service.onFinishSession = { _, _, _, _ in XCTFail("must not reach service") }
        try await client.beginSession(id: "s")
        do {
            _ = try await client.finish(sessionID: "s",
                                        deadline: ContinuousClock().now)
            XCTFail("expected deadlineExceeded")
        } catch { XCTAssertEqual(error as? XPCClientError, .deadlineExceeded) }
        XCTAssertEqual(service.finishedSessions.count, 0)
        XCTAssertEqual(service.cancelledSessions, ["s"])
    }

    func testFinishDoubleReplyResumesOnce() async throws {
        let (client, _, service) = makeClient()
        service.onFinishSession = { _, _, _, reply in
            reply("first", nil)
            reply("second", nil)
        }
        try await client.beginSession(id: "s")
        let transcript = try await client.finish(
            sessionID: "s", deadline: ContinuousClock().now.advanced(by: .seconds(5)))
        XCTAssertEqual(transcript, "first")
    }

    func testCancelDuringFinishDropsLateReply() async throws {
        let (client, _, service) = makeClient()
        let captured = LockedBox<(NSString?, NSError?) -> Void>()
        service.onFinishSession = { _, _, _, reply in captured.value = reply }
        try await client.beginSession(id: "s")
        let finishing = Task<String?, Never> {
            try? await client.finish(sessionID: "s",
                                     deadline: ContinuousClock().now.advanced(by: .seconds(10)))
        }
        let sawFinish = await waitUntil { service.finishedSessions.count == 1 }
        XCTAssertTrue(sawFinish)
        await client.cancel(sessionID: "s")
        let outcome = await finishing.value
        XCTAssertNil(outcome)
        captured.value?("zombie", nil)
        service.onFinishSession = nil
        try? await Task.sleep(for: .milliseconds(50))
        try await client.beginSession(id: "s2")
        let next = try await client.finish(
            sessionID: "s2", deadline: ContinuousClock().now.advanced(by: .seconds(5)))
        XCTAssertEqual(next, "fake transcript")
        XCTAssertEqual(service.cancelledSessions, ["s"])
    }

    func testCallerTaskCancellationCancelsUnacknowledgedServiceSession() async throws {
        let (client, _, service) = makeClient()
        service.onBeginSession = { _, _ in }
        let beginning = Task { try await client.beginSession(id: "cancelled-begin") }
        let began = await waitUntil { service.beganSessions == ["cancelled-begin"] }
        XCTAssertTrue(began)
        beginning.cancel()
        do {
            try await beginning.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
        }
        XCTAssertEqual(service.cancelledSessions, ["cancelled-begin"])
    }

    func testCancelDuringBeginFailsCallAndSession() async throws {
        let (client, _, service) = makeClient()
        let captured = LockedBox<(NSError?) -> Void>()
        service.onBeginSession = { _, reply in captured.value = reply }
        let beginning = Task<XPCClientError?, Never> {
            do {
                try await client.beginSession(id: "s")
                return nil
            } catch let error as XPCClientError {
                return error
            } catch {
                return nil
            }
        }
        let sawBegin = await waitUntil { service.beganSessions == ["s"] }
        XCTAssertTrue(sawBegin)
        await client.cancel(sessionID: "s")
        let outcome = await beginning.value
        XCTAssertEqual(outcome, .cancelled)
        captured.value?(nil)
        try? await Task.sleep(for: .milliseconds(50))
        do {
            try await client.push(Data(repeating: 0, count: 4), sessionID: "s")
            XCTFail("expected sessionUnknown")
        } catch let error as XPCClientError {
            XCTAssertEqual(error, .sessionUnknown)
        } catch { XCTFail("unexpected \(error)") }
        XCTAssertEqual(service.cancelledSessions, ["s"])
    }

    func testInterruptionFailsInflightAndClearsSessions() async throws {
        let (client, backend, service) = makeClient()
        service.onFinishSession = { _, _, _, _ in }
        try await client.beginSession(id: "s")
        let finishing = Task<XPCClientError?, Never> {
            do {
                _ = try await client.finish(sessionID: "s",
                                            deadline: ContinuousClock().now.advanced(by: .seconds(30)))
                return nil
            } catch let error as XPCClientError {
                return error
            } catch {
                return nil
            }
        }
        let sawFinish = await waitUntil { service.finishedSessions.count == 1 }
        XCTAssertTrue(sawFinish)
        backend.simulateInterruption()
        let outcome = await finishing.value
        XCTAssertEqual(outcome, .interrupted)
        let generation = await client.currentGeneration
        XCTAssertEqual(generation, 1)
        do {
            try await client.push(Data(repeating: 0, count: 4), sessionID: "s")
            XCTFail("expected sessionUnknown")
        } catch let error as XPCClientError {
            XCTAssertEqual(error, .sessionUnknown)
        } catch { XCTFail("unexpected \(error)") }
        try await client.beginSession(id: "s")
        service.onFinishSession = nil
        let transcript = try await client.finish(
            sessionID: "s", deadline: ContinuousClock().now.advanced(by: .seconds(5)))
        XCTAssertEqual(transcript, "fake transcript")
    }

    func testStaleReplyAfterReconnectDropped() async throws {
        let (client, backend, service) = makeClient()
        let captured = LockedBox<(NSString?, NSError?) -> Void>()
        service.onFinishSession = { _, _, _, reply in captured.value = reply }
        try await client.beginSession(id: "s")
        let finishing = Task<XPCClientError?, Never> {
            do {
                _ = try await client.finish(sessionID: "s",
                                            deadline: ContinuousClock().now.advanced(by: .seconds(30)))
                return nil
            } catch let error as XPCClientError {
                return error
            } catch {
                return nil
            }
        }
        let sawFinish = await waitUntil { service.finishedSessions.count == 1 }
        XCTAssertTrue(sawFinish)
        backend.simulateInterruption()
        let outcome = await finishing.value
        XCTAssertEqual(outcome, .interrupted)
        captured.value?("stale transcript", nil)
        try? await Task.sleep(for: .milliseconds(50))
        try await client.beginSession(id: "s")
        service.onFinishSession = nil
        let transcript = try await client.finish(
            sessionID: "s", deadline: ContinuousClock().now.advanced(by: .seconds(5)))
        XCTAssertEqual(transcript, "fake transcript")
    }

    func testInvalidateFailsCallsAndTerminatesClient() async throws {
        let (client, backend, service) = makeClient()
        service.onFinishSession = { _, _, _, _ in }
        try await client.beginSession(id: "s")
        let finishing = Task<XPCClientError?, Never> {
            do {
                _ = try await client.finish(sessionID: "s",
                                            deadline: ContinuousClock().now.advanced(by: .seconds(30)))
                return nil
            } catch let error as XPCClientError {
                return error
            } catch {
                return nil
            }
        }
        let sawFinish = await waitUntil { service.finishedSessions.count == 1 }
        XCTAssertTrue(sawFinish)
        await client.invalidate()
        let outcome = await finishing.value
        XCTAssertEqual(outcome, .connectionInvalidated)
        XCTAssertTrue(backend.wasInvalidated)
        do {
            _ = try await client.handshake()
            XCTFail("expected connectionInvalidated")
        } catch let error as XPCClientError {
            XCTAssertEqual(error, .connectionInvalidated)
        } catch { XCTFail("unexpected \(error)") }
    }

    func testBackendInvalidationTerminatesClient() async throws {
        let (client, backend, service) = makeClient()
        service.onFinishSession = { _, _, _, _ in }
        try await client.beginSession(id: "s")
        let finishing = Task<XPCClientError?, Never> {
            do {
                _ = try await client.finish(sessionID: "s",
                                            deadline: ContinuousClock().now.advanced(by: .seconds(30)))
                return nil
            } catch let error as XPCClientError {
                return error
            } catch {
                return nil
            }
        }
        let sawFinish = await waitUntil { service.finishedSessions.count == 1 }
        XCTAssertTrue(sawFinish)
        backend.simulateInvalidation()
        let outcome = await finishing.value
        XCTAssertEqual(outcome, .connectionInvalidated)
        let generation = await client.currentGeneration
        XCTAssertEqual(generation, 1)
        do {
            _ = try await client.handshake()
            XCTFail("expected connectionInvalidated")
        } catch let error as XPCClientError {
            XCTAssertEqual(error, .connectionInvalidated)
        } catch { XCTFail("unexpected \(error)") }
    }

    func testHandshakeInstanceRolloverDropsServiceState() async throws {
        let (client, _, service) = makeClient()
        _ = try await client.handshake()
        try await client.beginSession(id: "s")
        service.serviceInstanceID = "service-instance-B"
        _ = try await client.handshake()
        do {
            try await client.push(Data(repeating: 0, count: 4), sessionID: "s")
            XCTFail("expected sessionUnknown")
        } catch let error as XPCClientError {
            XCTAssertEqual(error, .sessionUnknown)
        } catch { XCTFail("unexpected \(error)") }
    }

    func testInflightCallBound() async throws {
        var limits = TranscriptionXPCClient.Limits(handshakeDeadline: .seconds(30))
        limits.maxInflightCalls = 1
        let (client, _, service) = makeClient(limits: limits)
        service.onHandshake = { _ in }
        let pending = Task { try? await client.handshake() }
        let sawCall = await waitUntil { service.handshakeCallCount == 1 }
        XCTAssertTrue(sawCall)
        do {
            try await client.beginSession(id: "s")
            XCTFail("expected backpressureLimit")
        } catch let error as XPCClientError {
            XCTAssertEqual(error, .backpressureLimit)
        } catch { XCTFail("unexpected \(error)") }
        _ = await pending.value
    }

    func testSendFailureDegradesPushStream() async throws {
        let (client, _, service) = makeClient()
        try await client.beginSession(id: "s")
        service.sendError = NSError(domain: NSCocoaErrorDomain, code: NSXPCConnectionInterrupted)
        try await client.push(Data(repeating: 0, count: 4), sessionID: "s")
        let degraded = await waitUntil { await client.streamRequiresCanonicalReplay("s") }
        XCTAssertTrue(degraded)
        let failure = await client.streamFailure("s")
        XCTAssertEqual(failure, .interrupted)
        let drained = await waitUntil { await client.pendingPushBytes == 0 }
        XCTAssertTrue(drained)
        let dropped = await client.droppedPushBytes
        XCTAssertEqual(dropped, 4)
    }

    func testProxyFactoryFailureSurfacesTypedError() async throws {
        let (client, backend, _) = makeClient()
        backend.proxyFactoryError = XPCClientError.transportError("no proxy")
        do {
            _ = try await client.handshake()
            XCTFail("expected transportError")
        } catch let error as XPCClientError {
            XCTAssertEqual(error, .transportError("no proxy"))
        } catch { XCTFail("unexpected \(error)") }
        backend.proxyFactoryError = nil
        try await client.beginSession(id: "s")
        backend.proxyFactoryError = XPCClientError.transportError("no proxy")
        do {
            try await client.push(Data(repeating: 0, count: 4), sessionID: "s")
            XCTFail("expected transportError")
        } catch let error as XPCClientError {
            XCTAssertEqual(error, .transportError("no proxy"))
            let degraded = await client.streamRequiresCanonicalReplay("s")
            XCTAssertTrue(degraded)
        } catch { XCTFail("unexpected \(error)") }
    }

    func testSameIDSessionReusableAfterFinish() async throws {
        let (client, _, service) = makeClient()
        try await client.beginSession(id: "s")
        _ = try await client.finish(sessionID: "s",
                                    deadline: ContinuousClock().now.advanced(by: .seconds(5)))
        try await client.beginSession(id: "s")
        try await client.push(Data(repeating: 0, count: 4), sessionID: "s")
        XCTAssertEqual(service.pushedChunks.last?.offset, 0)
        let transcript = try await client.finish(
            sessionID: "s", deadline: ContinuousClock().now.advanced(by: .seconds(5)))
        XCTAssertEqual(transcript, "fake transcript")
    }

    func testCancelUnknownSessionIsIgnored() async throws {
        let (client, _, service) = makeClient()
        await client.cancel(sessionID: "never-seen")
        XCTAssertEqual(service.cancelledSessions, [])
    }

    func testCancelReleasesPendingPushBudget() async throws {
        var limits = TranscriptionXPCClient.Limits(pushAckDeadline: .seconds(30))
        limits.maxPendingPushBytes = 8
        let (client, _, service) = makeClient(limits: limits)
        service.onPushAudio = { _, _, _, _ in }
        try await client.beginSession(id: "s")
        try await client.push(Data(repeating: 0, count: 4), sessionID: "s")
        try await client.push(Data(repeating: 0, count: 4), sessionID: "s")
        await client.cancel(sessionID: "s")
        let pending = await client.pendingPushBytes
        XCTAssertEqual(pending, 0)
        let count = await client.pendingPushCount
        XCTAssertEqual(count, 0)
        XCTAssertEqual(service.cancelledSessions, ["s"])
    }

    func testReplyGateResumesOnce() async {
        let gate = ReplyGate<String>()
        let outcome = await withCheckedContinuation { continuation in
            gate.arm(continuation)
            gate.resume(with: .success("first"))
            gate.resume(with: .success("second"))
            gate.resume(with: .failure(XPCClientError.interrupted))
        }
        XCTAssertEqual(try? outcome.get(), "first")
    }

    func testReplyGateDeliversResultArrivingBeforeArm() async {
        let gate = ReplyGate<String>()
        gate.resume(with: .failure(XPCClientError.deadlineExceeded))
        let outcome = await withCheckedContinuation { continuation in
            gate.arm(continuation)
        }
        XCTAssertThrowsError(try outcome.get()) { error in
            XCTAssertEqual(error as? XPCClientError, .deadlineExceeded)
        }
    }

    func testFinishMapsServiceErrors() async throws {
        let (client, _, service) = makeClient()
        service.onFinishSession = { _, _, _, reply in reply(nil, self.serviceError(11)) }
        try await client.beginSession(id: "s")
        do {
            _ = try await client.finish(sessionID: "s",
                                        deadline: ContinuousClock().now.advanced(by: .seconds(5)))
            XCTFail("expected serviceError")
        } catch let error as XPCClientError {
            XCTAssertEqual(error.serviceErrorKind, .cancelled)
        } catch { XCTFail("unexpected \(error)") }
    }

    func testPushRejectedDuringFinish() async throws {
        let (client, _, service) = makeClient()
        service.onFinishSession = { _, _, _, _ in }
        try await client.beginSession(id: "s")
        let finishing = Task {
            try? await client.finish(sessionID: "s",
                                     deadline: ContinuousClock().now.advanced(by: .seconds(2)))
        }
        let sawFinish = await waitUntil { service.finishedSessions.count == 1 }
        XCTAssertTrue(sawFinish)
        do {
            try await client.push(Data(repeating: 0, count: 4), sessionID: "s")
            XCTFail("expected sessionClosed")
        } catch let error as XPCClientError {
            XCTAssertEqual(error, .sessionClosed)
        } catch { XCTFail("unexpected \(error)") }
        _ = await finishing.value
    }
}
