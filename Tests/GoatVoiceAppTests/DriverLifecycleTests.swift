import AppKit
import CoreGraphics
import Foundation
import GoatVoiceCore
import GoatVoicePlatform
import XCTest
@testable import GoatVoiceApp

final class StubInputMonitor: SystemInputEventMonitoring {
    var handler: (@Sendable (InputEvent) -> Bool)?
    var startError: Error?
    private(set) var started = false
    private(set) var startCalls = 0

    func start() throws {
        startCalls += 1
        if let startError { throw startError }
        started = true
    }

    func stop() { started = false }

    @discardableResult
    func send(_ event: InputEvent) -> Bool {
        handler?(event) ?? false
    }
}

final class StubCapture: AudioCapturing, @unchecked Sendable {
    private struct State {
        var onChunk: (@Sendable (CapturedAudioChunk) -> Void)?
        var onLevel: (@Sendable (AudioLevelUpdate) -> Void)?
        var onEvent: (@Sendable (AudioCaptureEvent) -> Void)?
        var capturing = false
        var callOrder: [String] = []
        var drainResult = true
    }

    private let lock = NSLock()
    private var state = State()

    var onChunk: (@Sendable (CapturedAudioChunk) -> Void)? {
        get { lock.withLock { state.onChunk } }
        set { lock.withLock { state.onChunk = newValue } }
    }

    var onLevel: (@Sendable (AudioLevelUpdate) -> Void)? {
        get { lock.withLock { state.onLevel } }
        set { lock.withLock { state.onLevel = newValue } }
    }

    var onEvent: (@Sendable (AudioCaptureEvent) -> Void)? {
        get { lock.withLock { state.onEvent } }
        set { lock.withLock { state.onEvent = newValue } }
    }

    var capturing: Bool { lock.withLock { state.capturing } }
    var callOrder: [String] { lock.withLock { state.callOrder } }
    var drainResult: Bool {
        get { lock.withLock { state.drainResult } }
        set { lock.withLock { state.drainResult = newValue } }
    }

    func start(device: AudioInputDevice) throws {
        lock.withLock {
            state.capturing = true
            state.callOrder.append("start")
        }
    }

    func stop() {
        lock.withLock {
            state.callOrder.append("stop")
            state.capturing = false
        }
    }

    func stopAndDrain(until deadline: ContinuousClock.Instant) async -> Bool {
        lock.withLock {
            state.callOrder.append("drain")
            state.capturing = false
            return state.drainResult
        }
    }

    var isCapturing: Bool { capturing }

    func emitChunk(byteCount: Int) {
        onChunk?(CapturedAudioChunk(
            pcm16: Data(repeating: 0x11, count: byteCount), frameCount: byteCount / 2))
    }
}

final class StubServiceProxy: NSObject, GoatVoiceServiceXPCProtocol {
    var transcript: NSString = "hello world"
    var beginFailures = 0
    var loadModelError: NSError?
    var deferBeginReplies = false
    private(set) var callOrder: [String] = []
    private(set) var finishCalls = 0
    private(set) var cancelledSessions: [String] = []
    private var pendingBegins: [(String, (NSError?) -> Void)] = []

    var pendingBeginIDs: [String] { pendingBegins.map(\.0) }

    func handshake(reply: @escaping (NSDictionary) -> Void) {
        reply([
            "protocolVersion": GoatVoiceServiceWire.protocolVersion,
            "serviceInstanceID": "stub-service",
            "modelState": "loaded",
        ] as NSDictionary)
    }

    func loadModel(_ modelID: NSString, modelDirectory: NSURL,
                   reply: @escaping (NSError?) -> Void) {
        callOrder.append("loadModel")
        reply(loadModelError)
    }

    func unloadModel(reply: @escaping () -> Void) { reply() }

    func beginSession(_ sessionID: NSString, reply: @escaping (NSError?) -> Void) {
        callOrder.append("begin")
        if deferBeginReplies {
            pendingBegins.append((sessionID as String, reply))
            return
        }
        if beginFailures > 0 {
            beginFailures -= 1
            reply(Self.beginFailure)
            return
        }
        reply(nil)
    }

    func flushBegins(error: NSError? = nil) {
        let pending = pendingBegins
        pendingBegins.removeAll()
        for (_, reply) in pending { reply(error) }
    }

    func pushAudio(_ chunk: NSData, sessionID: NSString, offset: UInt64,
                   reply: @escaping (NSError?) -> Void) {
        reply(nil)
    }

    func previewSession(_ sessionID: NSString,
                        reply: @escaping (NSString?, NSError?) -> Void) {
        reply("", nil)
    }

    func finishSession(_ sessionID: NSString, canonicalAudio: NSData?, deadline: NSDate,
                       reply: @escaping (NSString?, NSError?) -> Void) {
        callOrder.append("finish")
        finishCalls += 1
        reply(transcript, nil)
    }

    func cancelSession(_ sessionID: NSString) {
        cancelledSessions.append(sessionID as String)
    }

    static let beginFailure = NSError(
        domain: GoatVoiceServiceWire.errorDomain,
        code: GoatVoiceServiceErrorKind.modelNotSelected.rawValue,
        userInfo: ["retryable": true])

    static let loadFailure = NSError(
        domain: GoatVoiceServiceWire.errorDomain,
        code: GoatVoiceServiceErrorKind.modelLoadFailed.rawValue,
        userInfo: ["retryable": false])
}

final class StubXPCBackend: XPCConnectionBackend, @unchecked Sendable {
    let proxy = StubServiceProxy()

    func remoteObjectProxy(
        errorHandler: @escaping @Sendable (Error) -> Void
    ) throws -> any GoatVoiceServiceXPCProtocol {
        proxy
    }
    func onInterruption(_ handler: @escaping @Sendable () -> Void) {}
    func onInvalidation(_ handler: @escaping @Sendable () -> Void) {}
    func resume() {}
    func invalidate() {}
}

@MainActor
final class DriverLifecycleTests: XCTestCase {
    @MainActor
    final class Harness {
        let input = StubInputMonitor()
        let capture = StubCapture()
        let pasteboard = FakePasteboard()
        let ax = FakeAccessibility()
        let poster = FakePoster()
        let xpc = StubXPCBackend()
        let settings = FakeSettings()
        let sink = FakeSink()
        let updater = FakeUpdater()
        let permissionProbe = FakePermissionProbe()
        let clockSource = ManualClockSource()
        let latch = InterruptibilityLatch()
        let pressed = SessionIntegrationTests.Harness.PressedKeys()
        let driver: SessionDriver
        let recovery: RecoveryController
        let monitor: InputTriggerMonitor

        init(spec: TriggerSpec = .default) {
            let clipboard = ClipboardCoordinator(backend: pasteboard)
            let resolver = TargetResolver(backend: ax, displayLookup: FakeDisplayLookup())
            let guard_ = UserIntentGuard(backend: ax, secureInputProbe: { false })
            let client = TranscriptionXPCClient(backend: xpc)
            let network = NetworkActivityCoordinator()
            let clock = MonotonicClock(epoch: clockSource.epoch) { [clockSource] in
                clockSource.instant
            }
            settings.configuredTrigger = spec
            let engine = TriggerEngine(spec: spec)
            monitor = InputTriggerMonitor(
                monitor: input, engine: engine, interruptibilityLatch: latch)
            monitor.setKeyStateProbe { [pressed] code in pressed.contains(code) }
            recovery = RecoveryController(clipboard: clipboard, clock: clock)
            driver = SessionDriver(deps: SessionDriver.Dependencies(
                settings: settings,
                sink: sink,
                capture: capture,
                devices: FakeDeviceResolver(),
                monitor: monitor,
                latch: latch,
                clipboard: clipboard,
                pasteboard: pasteboard,
                accessibility: ax,
                targetResolver: resolver,
                intentGuard: guard_,
                permissions: PermissionCenter(probe: permissionProbe),
                client: client,
                network: network,
                updater: updater,
                recovery: recovery,
                clock: clock,
                makeInserter: { [poster] in TextInserter(poster: poster) },
                isAppActive: { false }))
            recovery.presentNotice = { [weak driver] notice, displayID in
                driver?.presentExternalNotice(notice, displayID: displayID)
            }
            recovery.noticeResolved = { [weak driver] notice in
                driver?.noticeResolved(notice)
            }
        }

        func press(_ modifier: KeyboardModifier, keyCode: UInt16) {
            pressed.insert(keyCode)
            input.send(.modifierDown(modifier, keyCode: keyCode))
        }

        func release(_ modifier: KeyboardModifier, keyCode: UInt16) {
            pressed.remove(keyCode)
            input.send(.modifierUp(modifier, keyCode: keyCode))
        }
    }

    private func settle(timeout: TimeInterval = 4,
                        until predicate: @escaping @MainActor () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return true }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return predicate()
    }

    func testDisabledInputTapIsNotReportedAsMissingMicrophone() async throws {
        let harness = Harness()
        harness.driver.start()
        defer { harness.driver.stop() }
        harness.press(.rightOption, keyCode: 0x3D)
        let listening = await settle { harness.sink.lastContent == .strip(.listening) }
        XCTAssertTrue(listening)
        harness.input.send(.tapDisabledByTimeout)
        let reported = await settle {
            if case .notice(let notice) = harness.sink.lastContent {
                return notice.message == .shortcutUnavailable
            }
            return false
        }
        XCTAssertTrue(reported)
        XCTAssertFalse(harness.capture.isCapturing)
    }

    func testReleaseStopsHardwareBeforeDraining() async throws {
        let harness = Harness()
        harness.driver.start()
        harness.press(.rightOption, keyCode: 0x3D)
        let listening = await settle { harness.sink.lastContent == .strip(.listening) }
        XCTAssertTrue(listening)

        harness.capture.emitChunk(byteCount: 6400)
        harness.release(.rightOption, keyCode: 0x3D)

        let delivered = await settle { harness.sink.lastContent == .exiting(.delivered) }
        XCTAssertTrue(delivered)
        XCTAssertEqual(harness.capture.callOrder, ["start", "stop", "drain"])
        XCTAssertFalse(harness.capture.isCapturing)
        harness.driver.stop()
    }

    func testFailedDrainNeverPastesTruncatedTranscript() async throws {
        let harness = Harness()
        harness.capture.drainResult = false
        harness.driver.start()
        harness.press(.rightOption, keyCode: 0x3D)
        let listening = await settle { harness.sink.lastContent == .strip(.listening) }
        XCTAssertTrue(listening)

        harness.capture.emitChunk(byteCount: 6400)
        harness.release(.rightOption, keyCode: 0x3D)

        let failed = await settle {
            if case .notice(let notice) = harness.sink.lastContent {
                return notice.message == .transcriptionFailed
            }
            return false
        }
        XCTAssertTrue(failed)
        XCTAssertEqual(harness.xpc.proxy.finishCalls, 0)
        XCTAssertTrue(harness.poster.postedPIDs.isEmpty)
        XCTAssertFalse(harness.sink.presentations.contains {
            $0.content == .exiting(.delivered)
        })
        harness.driver.stop()
    }

    func testServiceSessionReloadIsBoundedByOriginalDeadline() async throws {
        let harness = Harness()
        harness.xpc.proxy.beginFailures = 2
        harness.driver.start()
        harness.press(.rightOption, keyCode: 0x3D)
        let listening = await settle { harness.sink.lastContent == .strip(.listening) }
        XCTAssertTrue(listening)

        harness.capture.emitChunk(byteCount: 3200)
        harness.release(.rightOption, keyCode: 0x3D)

        let delivered = await settle { harness.sink.lastContent == .exiting(.delivered) }
        XCTAssertTrue(delivered)
        XCTAssertEqual(
            harness.xpc.proxy.callOrder,
            ["begin", "begin", "loadModel", "begin", "finish"])
        XCTAssertEqual(harness.xpc.proxy.finishCalls, 1)
        harness.driver.stop()
    }

    func testLoadModelFailurePropagatesInsteadOfBlindRetry() async throws {
        let harness = Harness()
        harness.xpc.proxy.beginFailures = 2
        harness.xpc.proxy.loadModelError = StubServiceProxy.loadFailure
        harness.driver.start()
        harness.press(.rightOption, keyCode: 0x3D)
        let listening = await settle { harness.sink.lastContent == .strip(.listening) }
        XCTAssertTrue(listening)

        harness.capture.emitChunk(byteCount: 3200)
        harness.release(.rightOption, keyCode: 0x3D)

        let failed = await settle {
            if case .notice(let notice) = harness.sink.lastContent {
                return notice.message == .transcriptionFailed
            }
            return false
        }
        XCTAssertTrue(failed)
        XCTAssertEqual(
            harness.xpc.proxy.callOrder,
            ["begin", "begin", "loadModel"])
        XCTAssertEqual(harness.xpc.proxy.finishCalls, 0)
        harness.driver.stop()
    }

    func testLateServiceBeginIsCancelledAfterInvalidation() async throws {
        let harness = Harness()
        harness.xpc.proxy.deferBeginReplies = true
        harness.driver.start()
        harness.press(.rightOption, keyCode: 0x3D)
        let listening = await settle { harness.sink.lastContent == .strip(.listening) }
        XCTAssertTrue(listening)
        let pendingIDs = harness.xpc.proxy.pendingBeginIDs
        XCTAssertEqual(pendingIDs.count, 1)

        harness.driver.handleLifecycle(.willSleep)
        let cancelled = await settle { harness.sink.lastContent == .exiting(.cancelled) }
        XCTAssertTrue(cancelled)

        harness.xpc.proxy.flushBegins()
        let tornDown = await settle {
            harness.xpc.proxy.cancelledSessions.contains(pendingIDs[0])
        }
        XCTAssertTrue(tornDown)
        harness.driver.stop()
    }

    func testMonitorStartFailureRetriesOnWakeAndActivation() async throws {
        let harness = Harness()
        harness.input.startError = EventTapError.accessibilityMissing
        harness.driver.start()
        XCTAssertFalse(harness.input.started)
        XCTAssertEqual(harness.input.startCalls, 1)

        harness.driver.handleLifecycle(.didWake)
        XCTAssertEqual(harness.input.startCalls, 2)
        XCTAssertFalse(harness.input.started)

        harness.input.startError = nil
        NotificationCenter.default.post(
            name: NSApplication.didBecomeActiveNotification, object: nil)
        let restarted = await settle { harness.input.started }
        XCTAssertTrue(restarted)
        XCTAssertEqual(harness.input.startCalls, 3)
        harness.driver.stop()
    }

    func testEarlyCaptureLimitFinishesIntoRecoveryNotNormalRelease() async throws {
        let harness = Harness()
        harness.driver.start()
        harness.press(.rightOption, keyCode: 0x3D)
        let listening = await settle { harness.sink.lastContent == .strip(.listening) }
        XCTAssertTrue(listening)

        harness.capture.emitChunk(byteCount: 6400)
        harness.capture.onEvent?(.captureLimitReached)

        let recovered = await settle {
            if case .notice(let notice) = harness.sink.lastContent {
                return notice.message == .copiedToClipboard
                    || notice.message == .couldntInsert
            }
            return false
        }
        XCTAssertTrue(recovered)
        XCTAssertFalse(harness.capture.isCapturing)
        XCTAssertEqual(harness.xpc.proxy.finishCalls, 1)
        XCTAssertTrue(harness.poster.postedPIDs.isEmpty)
        XCTAssertFalse(harness.sink.presentations.contains {
            $0.content == .exiting(.delivered)
        })
        harness.driver.stop()
    }

    func testSystemInterruptionDropsLatchBeforeHop() async throws {
        let harness = Harness()
        harness.driver.start()
        harness.press(.rightOption, keyCode: 0x3D)
        let listening = await settle { harness.sink.lastContent == .strip(.listening) }
        XCTAssertTrue(listening)
        XCTAssertTrue(harness.latch.isInterruptible)

        harness.driver.noteSystemInterruption(.willSleep)
        XCTAssertFalse(harness.latch.isInterruptible)

        harness.driver.handleLifecycle(.willSleep)
        let cancelled = await settle { harness.sink.lastContent == .exiting(.cancelled) }
        XCTAssertTrue(cancelled)
        let consumed = harness.input.send(
            .keyDown(keyCode: 0x35, modifiers: [], isRepeat: false))
        XCTAssertFalse(consumed)
        harness.driver.stop()
    }

    func testEscapeDismissesRecoveryHUDWhileIdle() async throws {
        let harness = Harness()
        harness.pasteboard.items = [["com.apple.filepromise": Data("x".utf8)]]
        harness.driver.start()
        harness.press(.rightOption, keyCode: 0x3D)
        let listening = await settle { harness.sink.lastContent == .strip(.listening) }
        XCTAssertTrue(listening)

        harness.capture.emitChunk(byteCount: 3200)
        harness.release(.rightOption, keyCode: 0x3D)

        let recovered = await settle {
            if case .notice(let notice) = harness.sink.lastContent {
                return notice.message == .couldntInsert
            }
            return false
        }
        XCTAssertTrue(recovered)
        XCTAssertTrue(harness.latch.isInterruptible)

        let consumed = harness.input.send(
            .keyDown(keyCode: 0x35, modifiers: [], isRepeat: false))
        XCTAssertTrue(consumed)

        let hidden = await settle { harness.sink.lastContent == .hidden }
        XCTAssertTrue(hidden)
        XCTAssertFalse(harness.latch.isInterruptible)
        harness.driver.stop()
    }

    func testEscapePassesToForegroundAfterDeliveredPaste() async throws {
        let harness = Harness()
        harness.driver.start()
        harness.press(.rightOption, keyCode: 0x3D)
        let listening = await settle { harness.sink.lastContent == .strip(.listening) }
        XCTAssertTrue(listening)

        harness.capture.emitChunk(byteCount: 3200)
        harness.release(.rightOption, keyCode: 0x3D)

        let delivered = await settle { harness.sink.lastContent == .exiting(.delivered) }
        XCTAssertTrue(delivered)
        XCTAssertFalse(harness.latch.isInterruptible)

        let consumed = harness.input.send(
            .keyDown(keyCode: 0x35, modifiers: [], isRepeat: false))
        XCTAssertFalse(consumed)
        harness.driver.stop()
    }
}
