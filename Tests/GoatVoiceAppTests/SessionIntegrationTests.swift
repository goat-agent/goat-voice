import CoreGraphics
import Foundation
import GoatVoiceCore
import GoatVoicePlatform
import XCTest
@testable import GoatVoiceApp

final class FakeInputMonitor: SystemInputEventMonitoring {
    var handler: (@Sendable (InputEvent) -> Bool)?
    private(set) var started = false

    func start() throws { started = true }
    func stop() { started = false }

    @discardableResult
    func send(_ event: InputEvent) -> Bool {
        handler?(event) ?? false
    }
}

final class FakeCapture: AudioCapturing, @unchecked Sendable {
    var onChunk: (@Sendable (CapturedAudioChunk) -> Void)?
    var onLevel: (@Sendable (AudioLevelUpdate) -> Void)?
    var onEvent: (@Sendable (AudioCaptureEvent) -> Void)?

    private(set) var capturing = false
    private(set) var startedDevices: [AudioInputDevice] = []

    func start(device: AudioInputDevice) throws {
        capturing = true
        startedDevices.append(device)
    }

    func stop() { capturing = false }

    func stopAndDrain(until deadline: ContinuousClock.Instant) async -> Bool {
        capturing = false
        return true
    }

    var isCapturing: Bool { capturing }

    func emitChunk(byteCount: Int) {
        onChunk?(CapturedAudioChunk(
            pcm16: Data(repeating: 0x11, count: byteCount), frameCount: byteCount / 2))
    }
}

struct FakeDeviceResolver: AudioDeviceResolving {
    let device = AudioInputDevice(objectID: 7, uid: "fake-mic", name: "Fake Mic")

    func inputDevices() throws -> [AudioInputDevice] { [device] }
    func resolve(_ selection: MicrophoneSelection) throws -> AudioInputDevice { device }
}

final class FakePasteboard: PasteboardBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var storedItems: [[String: Data]] = [["public.utf8-plain-text": Data("seed".utf8)]]
    private var storedCount = 1
    private var storedWrites: [[[String: Data]]] = []

    var items: [[String: Data]] {
        get { lock.withLock { storedItems } }
        set { lock.withLock { storedItems = newValue } }
    }
    var changeCount: Int { lock.withLock { storedCount } }
    var writeLog: [[[String: Data]]] { lock.withLock { storedWrites } }
    var itemCount: Int { lock.withLock { storedItems.count } }

    func typeIdentifiers(ofItemAt index: Int) -> [String] {
        lock.withLock { Array(storedItems[index].keys) }
    }

    func materializeData(itemAt index: Int, typeIdentifier: String) -> Data? {
        lock.withLock { storedItems[index][typeIdentifier] }
    }

    func replaceItems(_ newItems: [[String: Data]]) -> PasteboardWriteResult {
        lock.withLock {
            storedItems = newItems
            storedCount += 1
            storedWrites.append(newItems)
            return .success(changeCount: storedCount)
        }
    }

    func plainText() -> String? {
        lock.withLock {
            storedItems.first?["public.utf8-plain-text"].flatMap {
                String(data: $0, encoding: .utf8)
            }
        }
    }
}

final class FakeAccessibility: AccessibilityBackend, @unchecked Sendable {
    let token = AXElementToken(element: NSObject(), pid: 4242)
    private let lock = NSLock()
    private var targetMatches = true
    private var context: (before: String, after: String)? = ("", "")
    var sameTarget: Bool {
        get { lock.withLock { targetMatches } }
        set { lock.withLock { targetMatches = newValue } }
    }
    var adjacent: (before: String, after: String)? {
        get { lock.withLock { context } }
        set { lock.withLock { context = newValue } }
    }

    func isProcessTrusted() -> Bool { true }
    func focusedEditableElement() throws -> AXElementToken { token }
    func element(_ token: AXElementToken, isSameAs other: AXElementToken) -> Bool { sameTarget }
    func windowID(of token: AXElementToken) -> CGWindowID? { 42 }
    func windowBounds(of token: AXElementToken) -> CGRect? {
        CGRect(x: 0, y: 0, width: 100, height: 100)
    }
    func bundleIdentifier(of token: AXElementToken) -> String? { "com.example.fake" }
    func observeMutations(of token: AXElementToken,
                          onMutation: @escaping @Sendable (AXMutationEvent) -> Void) throws -> AXObservation {
        AXObservation {}
    }
    func adjacentContext(of token: AXElementToken,
                         radius: Int) -> (before: String, after: String)? { adjacent }
}

struct FakeDisplayLookup: DisplayLookingUp {
    func displayID(containing bounds: CGRect) -> CGDirectDisplayID? { 3 }
}

final class FakePermissionProbe: PermissionProbing, @unchecked Sendable {
    private let lock = NSLock()
    private var microphoneValue: MicrophonePermission = .granted
    private var accessibilityValue: AccessibilityPermission = .trusted

    var microphone: MicrophonePermission {
        get { lock.withLock { microphoneValue } }
        set { lock.withLock { microphoneValue = newValue } }
    }

    var accessibility: AccessibilityPermission {
        get { lock.withLock { accessibilityValue } }
        set { lock.withLock { accessibilityValue = newValue } }
    }

    func microphoneStatus() -> MicrophonePermission { microphone }
    func requestMicrophoneAccess() async -> Bool { true }
    func accessibilityStatus() -> AccessibilityPermission { accessibility }
    func promptForAccessibility() -> Bool { true }
}

final class FakePoster: PasteEventPosting, @unchecked Sendable {
    private let lock = NSLock()
    private var targets: [pid_t] = []
    private var successful = true
    var postedPIDs: [pid_t] { lock.withLock { targets } }
    var succeeds: Bool {
        get { lock.withLock { successful } }
        set { lock.withLock { successful = newValue } }
    }

    func postPaste(to pid: pid_t) -> Bool {
        lock.withLock {
            targets.append(pid)
            return successful
        }
    }
}

final class FakeServiceProxy: NSObject, GoatVoiceServiceXPCProtocol {
    var transcript: NSString = "hello world"
    var retryableFailuresBeforeSuccess = 0
    private(set) var finishCalls = 0
    private(set) var finishCanonicalSizes: [Int] = []
    private(set) var beganSessions: [String] = []
    private(set) var pushedBytes = 0

    func handshake(reply: @escaping (NSDictionary) -> Void) {
        reply([
            "protocolVersion": GoatVoiceServiceWire.protocolVersion,
            "serviceInstanceID": "fake-service",
            "modelState": "loaded",
        ] as NSDictionary)
    }

    func loadModel(_ modelID: NSString, modelDirectory: NSURL,
                   reply: @escaping (NSError?) -> Void) {
        reply(nil)
    }

    func unloadModel(reply: @escaping () -> Void) { reply() }

    func beginSession(_ sessionID: NSString, reply: @escaping (NSError?) -> Void) {
        beganSessions.append(sessionID as String)
        reply(nil)
    }

    func pushAudio(_ chunk: NSData, sessionID: NSString, offset: UInt64,
                   reply: @escaping (NSError?) -> Void) {
        pushedBytes += chunk.length
        reply(nil)
    }

    func previewSession(_ sessionID: NSString,
                        reply: @escaping (NSString?, NSError?) -> Void) {
        reply("", nil)
    }

    func finishSession(_ sessionID: NSString, canonicalAudio: NSData?, deadline: NSDate,
                       reply: @escaping (NSString?, NSError?) -> Void) {
        finishCalls += 1
        finishCanonicalSizes.append(canonicalAudio?.length ?? -1)
        if retryableFailuresBeforeSuccess > 0 {
            retryableFailuresBeforeSuccess -= 1
            reply(nil, NSError(
                domain: GoatVoiceServiceWire.errorDomain,
                code: GoatVoiceServiceErrorKind.inferenceFailed.rawValue,
                userInfo: ["retryable": true]))
            return
        }
        reply(transcript, nil)
    }

    func cancelSession(_ sessionID: NSString) {}
}

final class FakeXPCBackend: XPCConnectionBackend, @unchecked Sendable {
    let proxy = FakeServiceProxy()

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
final class FakeSettings: SessionSettingsPort {
    var shortcut: TriggerShortcut = .default
    var selectedModelID: String? = "fake-model"
    var selectedMicrophoneID: String?
    var launchAtLogin = false
    var models: [ModelItem] = [
        ModelItem(id: "fake-model", title: "Fake Model", isRecommended: true, state: .ready)
    ]
    var microphones: [MicrophoneItem] = [
        MicrophoneItem(id: "fake-mic", name: "Fake Mic")
    ]
    var microphonePermission: PermissionState = .allowed
    var accessibilityPermission: PermissionState = .allowed
    var onChange: (() -> Void)?

    var configuredTrigger: TriggerSpec = .default
    var microphoneSelection: MicrophoneSelection = .systemDefault
    var selectedModelLocation: LiveModelLocation? =
        LiveModelLocation(id: "fake-model", directory: URL(fileURLWithPath: "/tmp/fake-model"))
    var onTriggerChanged: (() -> Void)?
    private(set) var sessionActive = false

    func setSessionActive(_ active: Bool) { sessionActive = active }
    func refreshPermissionsAndDevices() {}
    func requestMicrophonePermission() async -> Bool { true }
    func openMicrophoneSettings() {}
    func openAccessibilitySettings() {}
    func downloadModel(id: String) {}
    func loadModel(id: String) {}
}

@MainActor
final class FakeSink: SessionPresenting {
    private(set) var presentations: [SessionPresentation] = []
    private(set) var levels: [Double] = []

    func apply(presentation: SessionPresentation) { presentations.append(presentation) }
    func apply(audioLevel: Double) { levels.append(audioLevel) }

    var lastContent: IndicatorContent? { presentations.last?.content }
}

@MainActor
final class FakeUpdater: UpdateChecking {
    var canCheckForUpdates = true
    var sessionIsActive = false
    func checkForUpdates() {}
}

final class ManualClockSource: @unchecked Sendable {
    let epoch = ContinuousClock.now
    private let lock = NSLock()
    private var offset: Duration = .zero

    var instant: ContinuousClock.Instant {
        lock.withLock { epoch.advanced(by: offset) }
    }

    func advance(by delta: Duration) {
        lock.withLock { offset += delta }
    }
}

@MainActor
final class SessionIntegrationTests: XCTestCase {
    @MainActor
    final class Harness {
        let input = FakeInputMonitor()
        let capture = FakeCapture()
        let pasteboard = FakePasteboard()
        let ax = FakeAccessibility()
        let poster = FakePoster()
        let xpc = FakeXPCBackend()
        let settings = FakeSettings()
        let sink = FakeSink()
        let updater = FakeUpdater()
        let permissionProbe = FakePermissionProbe()
        let clockSource = ManualClockSource()
        let latch = InterruptibilityLatch()
        let pressed = PressedKeys()
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

        final class PressedKeys: @unchecked Sendable {
            private let lock = NSLock()
            private var codes = Set<UInt16>()
            func insert(_ code: UInt16) { _ = lock.withLock { codes.insert(code) } }
            func remove(_ code: UInt16) { _ = lock.withLock { codes.remove(code) } }
            func contains(_ code: UInt16) -> Bool { lock.withLock { codes.contains(code) } }
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

    func testHoldReleasePastesTranscriptThenRestoresClipboard() async throws {
        let harness = Harness()
        harness.driver.start()
        harness.press(.rightOption, keyCode: 0x3D)

        let listening = await settle { harness.sink.lastContent == .strip(.listening) }
        XCTAssertTrue(listening)
        XCTAssertTrue(harness.capture.isCapturing)
        XCTAssertTrue(harness.settings.sessionActive)
        XCTAssertTrue(harness.updater.sessionIsActive)

        harness.capture.emitChunk(byteCount: 6400)
        harness.release(.rightOption, keyCode: 0x3D)

        let delivered = await settle { harness.sink.lastContent == .exiting(.delivered) }
        XCTAssertTrue(delivered)
        XCTAssertEqual(harness.poster.postedPIDs, [4242])
        XCTAssertEqual(harness.xpc.proxy.beganSessions.count, 1)
        XCTAssertEqual(harness.xpc.proxy.finishCalls, 1)
        XCTAssertEqual(harness.xpc.proxy.finishCanonicalSizes, [6400])
        XCTAssertTrue(harness.pasteboard.writeLog.contains { items in
            items.first?["public.utf8-plain-text"].flatMap {
                String(data: $0, encoding: .utf8)
            } == "hello world"
        })

        let restored = await settle { harness.pasteboard.plainText() == "seed" }
        XCTAssertTrue(restored)
        XCTAssertFalse(harness.settings.sessionActive)
        XCTAssertFalse(harness.updater.sessionIsActive)
        harness.driver.stop()
    }

    func testEscapeCancelsSessionWithoutPaste() async throws {
        let harness = Harness()
        harness.driver.start()
        harness.press(.rightOption, keyCode: 0x3D)
        let listening = await settle { harness.sink.lastContent == .strip(.listening) }
        XCTAssertTrue(listening)

        harness.pressed.remove(0x3D)
        harness.input.send(.keyDown(keyCode: 0x35, modifiers: [], isRepeat: false))

        let cancelled = await settle { harness.sink.lastContent == .exiting(.cancelled) }
        XCTAssertTrue(cancelled)
        XCTAssertTrue(harness.poster.postedPIDs.isEmpty)
        XCTAssertEqual(harness.xpc.proxy.finishCalls, 0)
        harness.driver.stop()
    }

    func testTransientFailureRetriesOnceWithCanonicalReplay() async throws {
        let harness = Harness()
        harness.xpc.proxy.retryableFailuresBeforeSuccess = 1
        harness.driver.start()
        harness.press(.rightOption, keyCode: 0x3D)
        let listening = await settle { harness.sink.lastContent == .strip(.listening) }
        XCTAssertTrue(listening)

        harness.capture.emitChunk(byteCount: 3200)
        harness.release(.rightOption, keyCode: 0x3D)

        let delivered = await settle { harness.sink.lastContent == .exiting(.delivered) }
        XCTAssertTrue(delivered)
        XCTAssertEqual(harness.xpc.proxy.finishCalls, 2)
        XCTAssertEqual(harness.xpc.proxy.finishCanonicalSizes, [3200, 3200])
        XCTAssertEqual(harness.poster.postedPIDs, [4242])
        harness.driver.stop()
    }

    func testTargetMismatchRecoversWithoutPaste() async throws {
        let harness = Harness()
        harness.ax.sameTarget = false
        harness.driver.start()
        harness.press(.rightOption, keyCode: 0x3D)
        let listening = await settle { harness.sink.lastContent == .strip(.listening) }
        XCTAssertTrue(listening)

        harness.release(.rightOption, keyCode: 0x3D)

        let recovered = await settle {
            if case .notice(let notice) = harness.sink.lastContent {
                return notice.message == .couldntInsert || notice.message == .copiedToClipboard
            }
            return false
        }
        XCTAssertTrue(recovered)
        XCTAssertTrue(harness.poster.postedPIDs.isEmpty)
        harness.driver.stop()
    }

    func testRecordingHardCapForcesRecovery() async throws {
        let harness = Harness()
        harness.driver.start()
        harness.press(.rightOption, keyCode: 0x3D)
        let listening = await settle { harness.sink.lastContent == .strip(.listening) }
        XCTAssertTrue(listening)

        harness.clockSource.advance(by: .seconds(1201))

        let recovered = await settle {
            if case .notice(let notice) = harness.sink.lastContent {
                return notice.message == .couldntInsert || notice.message == .copiedToClipboard
            }
            return false
        }
        XCTAssertTrue(recovered)
        XCTAssertTrue(harness.poster.postedPIDs.isEmpty)
        harness.driver.stop()
    }

    func testPartialChordReleaseDoesNotRearmUntilAllKeysUp() async throws {
        let spec = TriggerSpec.chord(keyCode: 0x25, modifiers: [.rightOption])
        let harness = Harness(spec: spec)
        harness.driver.start()

        harness.press(.rightOption, keyCode: 0x3D)
        harness.pressed.insert(0x25)
        harness.input.send(.keyDown(keyCode: 0x25, modifiers: [.option], isRepeat: false))
        let listening = await settle { harness.sink.lastContent == .strip(.listening) }
        XCTAssertTrue(listening)

        harness.pressed.remove(0x25)
        harness.input.send(.keyUp(keyCode: 0x25, modifiers: [.option]))

        let delivered = await settle { harness.sink.lastContent == .exiting(.delivered) }
        XCTAssertTrue(delivered)

        harness.pressed.insert(0x25)
        harness.input.send(.keyDown(keyCode: 0x25, modifiers: [.option], isRepeat: false))
        try? await Task.sleep(for: .milliseconds(200))
        XCTAssertFalse(harness.capture.isCapturing)

        harness.release(.rightOption, keyCode: 0x3D)
        harness.pressed.remove(0x25)
        harness.input.send(.keyUp(keyCode: 0x25, modifiers: []))
        try? await Task.sleep(for: .milliseconds(200))

        harness.press(.rightOption, keyCode: 0x3D)
        harness.pressed.insert(0x25)
        harness.input.send(.keyDown(keyCode: 0x25, modifiers: [.option], isRepeat: false))

        let rearmed = await settle { harness.sink.lastContent == .strip(.listening) }
        XCTAssertTrue(rearmed)
        harness.driver.stop()
    }

    func testMissingMicrophonePermissionBlocksSession() async throws {
        let harness = Harness()
        harness.permissionProbe.microphone = .denied
        harness.driver.start()
        harness.press(.rightOption, keyCode: 0x3D)

        let blocked = await settle {
            if case .notice(let notice) = harness.sink.lastContent {
                return notice.message == .microphoneAccessRequired
            }
            return false
        }
        XCTAssertTrue(blocked)
        XCTAssertFalse(harness.capture.isCapturing)
        harness.driver.stop()
    }
}
