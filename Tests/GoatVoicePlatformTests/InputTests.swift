import XCTest
@testable import GoatVoicePlatform

final class TriggerEngineTests: XCTestCase {
    private var engine: TriggerEngine!

    private let rightOption: UInt16 = 0x3D
    private let leftOption: UInt16 = 0x3A
    private let leftControl: UInt16 = 0x3B
    private let rightControl: UInt16 = 0x3E
    private let leftShift: UInt16 = 0x38
    private let space: UInt16 = 0x31
    private let esc: UInt16 = 0x35
    private let keyK: UInt16 = 0x28

    override func setUp() {
        engine = TriggerEngine(spec: .modifier(.rightOption))
    }

    private func feed(_ event: InputEvent) -> (Bool, [TriggerEffect]) {
        engine.handle(event)
    }

    func testRightOptionHoldAndRelease() {
        var result = feed(.modifierDown(.rightOption, keyCode: rightOption))
        XCTAssertTrue(result.0)
        XCTAssertEqual(result.1, [.began])
        XCTAssertTrue(engine.isActive)

        result = feed(.modifierUp(.rightOption, keyCode: rightOption))
        XCTAssertTrue(result.0)
        XCTAssertEqual(result.1, [.ended])
        XCTAssertFalse(engine.isActive)
    }

    func testLeftOptionDoesNotSatisfyRightOptionSpec() {
        let result = feed(.modifierDown(.leftOption, keyCode: leftOption))
        XCTAssertFalse(result.0)
        XCTAssertEqual(result.1, [])
        XCTAssertFalse(engine.isActive)
    }

    func testChordStartsOnlyWhenAllRequiredKeysDown() {
        engine = TriggerEngine(spec: .chord(keyCode: space, modifiers: [.control]))

        var result = feed(.modifierDown(.leftControl, keyCode: leftControl))
        XCTAssertFalse(result.0)
        XCTAssertEqual(result.1, [])
        XCTAssertFalse(engine.isActive)

        result = feed(.keyDown(keyCode: space, modifiers: [.control], isRepeat: false))
        XCTAssertTrue(result.0)
        XCTAssertEqual(result.1, [.began])
    }

    func testChordEndsOnAnyRequiredKeyRelease() {
        engine = TriggerEngine(spec: .chord(keyCode: space, modifiers: [.control]))
        _ = feed(.modifierDown(.leftControl, keyCode: leftControl))
        _ = feed(.keyDown(keyCode: space, modifiers: [.control], isRepeat: false))

        var result = feed(.keyUp(keyCode: space, modifiers: [.control]))
        XCTAssertTrue(result.0)
        XCTAssertEqual(result.1, [.ended])

        _ = feed(.modifierUp(.leftControl, keyCode: leftControl))
        _ = feed(.modifierDown(.leftControl, keyCode: leftControl))
        result = feed(.keyDown(keyCode: space, modifiers: [.control], isRepeat: false))
        XCTAssertEqual(result.1, [.began])
    }

    func testPartialReleaseDoesNotRearm() {
        engine = TriggerEngine(spec: .chord(keyCode: space, modifiers: [.control]))
        _ = feed(.modifierDown(.leftControl, keyCode: leftControl))
        _ = feed(.keyDown(keyCode: space, modifiers: [.control], isRepeat: false))
        _ = feed(.keyUp(keyCode: space, modifiers: [.control]))

        var result = feed(.keyDown(keyCode: space, modifiers: [.control], isRepeat: false))
        XCTAssertFalse(result.0)
        XCTAssertEqual(result.1, [])
        XCTAssertFalse(engine.isActive)

        _ = feed(.keyUp(keyCode: space, modifiers: [.control]))
        _ = feed(.modifierUp(.leftControl, keyCode: leftControl))

        _ = feed(.modifierDown(.leftControl, keyCode: leftControl))
        result = feed(.keyDown(keyCode: space, modifiers: [.control], isRepeat: false))
        XCTAssertEqual(result.1, [.began])
    }

    func testHeldTriggerCannotStartSecondSession() {
        _ = feed(.modifierDown(.rightOption, keyCode: rightOption))
        _ = feed(.modifierUp(.rightOption, keyCode: rightOption))

        _ = feed(.modifierDown(.rightOption, keyCode: rightOption))
        engine.disarmUntilTriggerFullyReleased()

        _ = feed(.modifierUp(.rightOption, keyCode: rightOption))
        let result = feed(.modifierDown(.rightOption, keyCode: rightOption))
        XCTAssertEqual(result.1, [.began])
    }

    func testDisarmWhileHeldSuppressesPressUntilFullRelease() {
        _ = feed(.modifierDown(.rightOption, keyCode: rightOption))
        _ = feed(.modifierUp(.rightOption, keyCode: rightOption))
        _ = feed(.modifierDown(.rightOption, keyCode: rightOption))
        engine.disarmUntilTriggerFullyReleased()

        var result = feed(.modifierDown(.rightOption, keyCode: rightOption))
        XCTAssertFalse(result.0)
        XCTAssertEqual(result.1, [])
        XCTAssertFalse(engine.isActive)

        _ = feed(.modifierUp(.rightOption, keyCode: rightOption))
        _ = feed(.modifierUp(.rightOption, keyCode: rightOption))

        result = feed(.modifierDown(.rightOption, keyCode: rightOption))
        XCTAssertEqual(result.1, [.began])
    }

    func testExtraKeyCancelsAndPassesThrough() {
        _ = feed(.modifierDown(.rightOption, keyCode: rightOption))

        var result = feed(.keyDown(keyCode: keyK, modifiers: [.option], isRepeat: false))
        XCTAssertFalse(result.0)
        XCTAssertEqual(result.1, [.cancelledByExtraKey])
        XCTAssertFalse(engine.isActive)

        result = feed(.modifierUp(.rightOption, keyCode: rightOption))
        XCTAssertFalse(result.0)
        XCTAssertEqual(result.1, [])

        result = feed(.modifierDown(.rightOption, keyCode: rightOption))
        XCTAssertEqual(result.1, [.began])
    }

    func testStrayModifierCancelsActiveSession() {
        _ = feed(.modifierDown(.rightOption, keyCode: rightOption))
        let result = feed(.modifierDown(.leftShift, keyCode: leftShift))
        XCTAssertFalse(result.0)
        XCTAssertEqual(result.1, [.cancelledByExtraKey])
    }

    func testEscapeWhileActiveIsConsumedAndCancels() {
        _ = feed(.modifierDown(.rightOption, keyCode: rightOption))
        let result = feed(.keyDown(keyCode: esc, modifiers: [], isRepeat: false))
        XCTAssertTrue(result.0)
        XCTAssertEqual(result.1, [.cancelledByEscape])
        XCTAssertFalse(engine.isActive)
    }

    func testEscapeWhileInterruptibleSessionIsConsumed() {
        engine.escapeInterruptsSession = { true }
        let result = feed(.keyDown(keyCode: esc, modifiers: [], isRepeat: false))
        XCTAssertTrue(result.0)
        XCTAssertEqual(result.1, [.cancelledByEscape])
    }

    func testEscapeWhileIdlePassesThrough() {
        let result = feed(.keyDown(keyCode: esc, modifiers: [], isRepeat: false))
        XCTAssertFalse(result.0)
        XCTAssertEqual(result.1, [])
    }

    func testTriggerKeyRepeatDoesNotCancelChord() {
        engine = TriggerEngine(spec: .chord(keyCode: space, modifiers: [.control]))
        _ = feed(.modifierDown(.leftControl, keyCode: leftControl))
        _ = feed(.keyDown(keyCode: space, modifiers: [.control], isRepeat: false))
        let result = feed(.keyDown(keyCode: space, modifiers: [.control], isRepeat: true))
        XCTAssertTrue(result.0)
        XCTAssertEqual(result.1, [])
        XCTAssertTrue(engine.isActive)
    }

    func testRepeatOfKeyHeldBeforeSessionStartDoesNotCancel() {
        let keyA: UInt16 = 0x00
        _ = feed(.keyDown(keyCode: keyA, modifiers: [], isRepeat: false))
        _ = feed(.modifierDown(.rightOption, keyCode: rightOption))
        let result = feed(.keyDown(keyCode: keyA, modifiers: [.option], isRepeat: true))
        XCTAssertFalse(result.0)
        XCTAssertEqual(result.1, [])
        XCTAssertTrue(engine.isActive)
    }

    func testRepressOfAlreadyHeldKeyDoesNotCancel() {
        let keyA: UInt16 = 0x00
        _ = feed(.keyDown(keyCode: keyA, modifiers: [], isRepeat: false))
        _ = feed(.modifierDown(.rightOption, keyCode: rightOption))
        let result = feed(.keyDown(keyCode: keyA, modifiers: [.option], isRepeat: false))
        XCTAssertFalse(result.0)
        XCTAssertEqual(result.1, [])
        XCTAssertTrue(engine.isActive)
    }

    func testDeliveredChordMemberReleaseReachesForeground() {
        engine = TriggerEngine(spec: .chord(keyCode: space, modifiers: [.control]))
        _ = feed(.keyDown(keyCode: space, modifiers: [], isRepeat: false))
        _ = feed(.modifierDown(.leftControl, keyCode: leftControl))
        let result = feed(.keyUp(keyCode: space, modifiers: [.control]))
        XCTAssertFalse(result.0)
        XCTAssertEqual(result.1, [.ended])
    }

    func testConsumedTriggerKeyReleaseIsConsumed() {
        _ = feed(.modifierDown(.rightOption, keyCode: rightOption))
        let result = feed(.modifierUp(.rightOption, keyCode: rightOption))
        XCTAssertTrue(result.0)
        XCTAssertEqual(result.1, [.ended])
        XCTAssertTrue(engine.triggerIsFullyReleased)
        XCTAssertTrue(engine.isArmed)
    }

    func testProbeSelfHealsAfterConfirmedPressAndLostRelease() {
        let keys = KeyStateBox()
        keys.down = [rightOption]
        engine.keyStateProbe = { keys.down.contains($0) }
        let pressed = feed(.modifierDown(.rightOption, keyCode: rightOption))
        XCTAssertEqual(pressed.1, [.began])
        XCTAssertTrue(engine.isActive)
        keys.down = []
        let reconciled = feed(.scrollWheel)
        XCTAssertEqual(reconciled.1, [.ended])
        XCTAssertFalse(engine.isActive)
        XCTAssertTrue(engine.isArmed)
    }

    func testNonTriggerKeyUpWhileActivePassesThrough() {
        _ = feed(.modifierDown(.rightOption, keyCode: rightOption))
        let result = feed(.keyUp(keyCode: keyK, modifiers: [.option]))
        XCTAssertFalse(result.0)
        XCTAssertTrue(engine.isActive)
    }

    func testBothControlSidesDownThenOneReleaseEndsChord() {
        engine = TriggerEngine(spec: .chord(keyCode: space, modifiers: [.control]))
        _ = feed(.modifierDown(.leftControl, keyCode: leftControl))
        _ = feed(.modifierDown(.rightControl, keyCode: rightControl))
        _ = feed(.keyDown(keyCode: space, modifiers: [.control], isRepeat: false))
        let result = feed(.modifierUp(.leftControl, keyCode: leftControl))
        XCTAssertFalse(result.0)
        XCTAssertEqual(result.1, [.ended])
        XCTAssertFalse(engine.isActive)
    }

    func testKeyStateProbeReconcilesMissedRelease() {
        let physical = KeyStateBox()
        physical.down.insert(rightOption)
        engine.keyStateProbe = { physical.down.contains($0) }

        _ = feed(.modifierDown(.rightOption, keyCode: rightOption))
        XCTAssertTrue(engine.isActive)

        physical.down.removeAll()
        let result = feed(.keyUp(keyCode: keyK, modifiers: []))
        XCTAssertEqual(result.1, [.ended])
        XCTAssertFalse(engine.isActive)
    }

    func testKeyStateProbeRearmsDisarmedTrigger() {
        let physical = KeyStateBox()
        physical.down.insert(rightOption)
        engine.keyStateProbe = { physical.down.contains($0) }

        _ = feed(.modifierDown(.rightOption, keyCode: rightOption))
        _ = feed(.modifierUp(.rightOption, keyCode: rightOption))
        _ = feed(.modifierDown(.rightOption, keyCode: rightOption))
        engine.disarmUntilTriggerFullyReleased()

        physical.down.removeAll()
        _ = feed(.scrollWheel)

        physical.down.insert(rightOption)
        let result = feed(.modifierDown(.rightOption, keyCode: rightOption))
        XCTAssertEqual(result.1, [.began])
        XCTAssertTrue(engine.isActive)
    }

    func testTapDisabledEmitsEffectWithoutConsuming() {
        _ = feed(.modifierDown(.rightOption, keyCode: rightOption))
        let result = feed(.tapDisabledByTimeout)
        XCTAssertFalse(result.0)
        XCTAssertEqual(result.1, [.tapDisabled])
    }

    func testResetClearsState() {
        _ = feed(.modifierDown(.rightOption, keyCode: rightOption))
        engine.reset()
        XCTAssertFalse(engine.isActive)
        _ = feed(.modifierUp(.rightOption, keyCode: rightOption))
        let result = feed(.modifierDown(.rightOption, keyCode: rightOption))
        XCTAssertEqual(result.1, [.began])
    }

    func testSpecSwapDisarmsUntilRelease() {
        _ = feed(.modifierDown(.rightOption, keyCode: rightOption))
        _ = feed(.modifierUp(.rightOption, keyCode: rightOption))
        engine.spec = .chord(keyCode: space, modifiers: [.control])
        engine.reset()
        _ = feed(.modifierDown(.leftControl, keyCode: leftControl))
        let result = feed(.keyDown(keyCode: space, modifiers: [.control], isRepeat: false))
        XCTAssertEqual(result.1, [.began])
    }
}

final class KeyStateBox: @unchecked Sendable {
    private var stored = Set<UInt16>()
    private let lock = NSLock()

    var down: Set<UInt16> {
        get {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }
        set {
            lock.lock()
            stored = newValue
            lock.unlock()
        }
    }
}

final class CallbackRecorder: @unchecked Sendable {
    private var recordedEffects: [TriggerEffect] = []
    private var recordedEvents: [InputEvent] = []
    private var recordedObservations: [InputTriggerMonitor.SyncObservation] = []
    private let lock = NSLock()

    var effects: [TriggerEffect] {
        lock.lock()
        defer { lock.unlock() }
        return recordedEffects
    }

    var events: [InputEvent] {
        lock.lock()
        defer { lock.unlock() }
        return recordedEvents
    }

    var observations: [InputTriggerMonitor.SyncObservation] {
        lock.lock()
        defer { lock.unlock() }
        return recordedObservations
    }

    func append(_ effect: TriggerEffect) {
        lock.lock()
        recordedEffects.append(effect)
        lock.unlock()
    }

    func append(_ event: InputEvent) {
        lock.lock()
        recordedEvents.append(event)
        lock.unlock()
    }

    func append(_ observation: InputTriggerMonitor.SyncObservation) {
        lock.lock()
        recordedObservations.append(observation)
        lock.unlock()
    }
}

final class InputTriggerMonitorTests: XCTestCase {
    final class FakeMonitor: SystemInputEventMonitoring {
        var handler: (@Sendable (InputEvent) -> Bool)?
        var started = false
        var startError: Error?
        func start() throws {
            if let startError { throw startError }
            started = true
        }
        func stop() { started = false }
        @discardableResult
        func feed(_ event: InputEvent) -> Bool { handler?(event) ?? false }
    }

    private func makeMonitor(
        callbackQueue: DispatchQueue? = nil,
        latch: InterruptibilityLatch? = nil,
        physical: KeyStateBox? = nil
    ) -> (FakeMonitor, InputTriggerMonitor) {
        let fake = FakeMonitor()
        let engine = TriggerEngine(spec: .modifier(.rightOption))
        let monitor: InputTriggerMonitor
        if let callbackQueue {
            monitor = InputTriggerMonitor(
                monitor: fake, engine: engine,
                interruptibilityLatch: latch, callbackQueue: callbackQueue)
        } else {
            monitor = InputTriggerMonitor(
                monitor: fake, engine: engine, interruptibilityLatch: latch)
        }
        if let physical {
            monitor.setKeyStateProbe { physical.down.contains($0) }
        }
        return (fake, monitor)
    }

    func testEffectsAndDeliveredEventsFlowThroughCallbacks() throws {
        let physical = KeyStateBox()
        let (fake, monitor) = makeMonitor(physical: physical)
        let recorder = CallbackRecorder()
        monitor.onEffect = { recorder.append($0) }
        monitor.onEvent = { recorder.append($0) }
        try monitor.start()

        physical.down.insert(0x3D)
        XCTAssertTrue(fake.feed(.modifierDown(.rightOption, keyCode: 0x3D)))
        physical.down.remove(0x3D)
        XCTAssertTrue(fake.feed(.modifierUp(.rightOption, keyCode: 0x3D)))
        XCTAssertFalse(fake.feed(.keyDown(keyCode: 0x28, modifiers: [], isRepeat: false)))

        let deadline = Date().addingTimeInterval(2)
        while recorder.effects.count < 2 || recorder.events.count < 1, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertEqual(recorder.effects, [.began, .ended])
        XCTAssertEqual(recorder.events.count, 1)
    }

    func testConsumedEventsAreNotReportedToObservers() throws {
        let physical = KeyStateBox()
        let (fake, monitor) = makeMonitor(physical: physical)
        let recorder = CallbackRecorder()
        monitor.onEvent = { recorder.append($0) }
        try monitor.start()

        physical.down.insert(0x3D)
        XCTAssertTrue(fake.feed(.modifierDown(.rightOption, keyCode: 0x3D)))
        XCTAssertTrue(fake.feed(.keyDown(keyCode: 0x35, modifiers: [], isRepeat: false)))

        RunLoop.current.run(until: Date().addingTimeInterval(0.15))
        XCTAssertEqual(recorder.events, [])
    }

    func testStartPropagatesMonitorFailure() {
        let (fake, monitor) = makeMonitor()
        fake.startError = EventTapError.creationFailed
        XCTAssertThrowsError(try monitor.start())
    }

    func testStaleCallbacksFromBeforeStopAreDropped() throws {
        let queue = DispatchQueue(label: "test.input.callback")
        queue.suspend()
        let (fake, monitor) = makeMonitor(callbackQueue: queue)
        let recorder = CallbackRecorder()
        monitor.onEffect = { recorder.append($0) }
        monitor.onEvent = { recorder.append($0) }
        try monitor.start()

        XCTAssertTrue(fake.feed(.modifierDown(.rightOption, keyCode: 0x3D)))
        _ = fake.feed(.keyDown(keyCode: 0x28, modifiers: [], isRepeat: false))
        monitor.stop()
        queue.resume()
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        XCTAssertEqual(recorder.effects, [])
        XCTAssertEqual(recorder.events, [])
    }

    func testStaleCallbacksCannotReachNewSessionAfterRestart() throws {
        let queue = DispatchQueue(label: "test.input.callback")
        queue.suspend()
        let physical = KeyStateBox()
        let (fake, monitor) = makeMonitor(callbackQueue: queue, physical: physical)
        let recorder = CallbackRecorder()
        monitor.onEffect = { recorder.append($0) }
        try monitor.start()
        physical.down.insert(0x3D)
        XCTAssertTrue(fake.feed(.modifierDown(.rightOption, keyCode: 0x3D)))
        monitor.stop()
        try monitor.start()
        physical.down.remove(0x3D)
        XCTAssertTrue(fake.feed(.modifierUp(.rightOption, keyCode: 0x3D)))
        queue.resume()
        let deadline = Date().addingTimeInterval(2)
        while recorder.effects.count < 1, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertEqual(recorder.effects, [.ended])
        XCTAssertTrue(monitor.isArmed())
        XCTAssertTrue(monitor.triggerIsFullyReleased())
    }

    func testSynchronousObserverSeesObservationBeforeFeedReturns() throws {
        let physical = KeyStateBox()
        let (fake, monitor) = makeMonitor(physical: physical)
        let recorder = CallbackRecorder()
        _ = monitor.addSynchronousObserver { recorder.append($0) }
        try monitor.start()
        physical.down.insert(0x3D)
        XCTAssertTrue(fake.feed(.modifierDown(.rightOption, keyCode: 0x3D)))
        let observations = recorder.observations
        XCTAssertEqual(observations.count, 1)
        XCTAssertTrue(observations[0].consumed)
        XCTAssertEqual(observations[0].effects, [.began])
    }

    func testInterruptibilityLatchControlsIdleEscape() throws {
        let latch = InterruptibilityLatch(initiallyInterruptible: false)
        let (fake, monitor) = makeMonitor(latch: latch)
        try monitor.start()

        XCTAssertFalse(fake.feed(.keyDown(keyCode: 0x35, modifiers: [], isRepeat: false)))
        latch.setInterruptible(true)
        XCTAssertTrue(fake.feed(.keyDown(keyCode: 0x35, modifiers: [], isRepeat: false)))
    }

    func testPendingObservationBoundDropsExcess() throws {
        let queue = DispatchQueue(label: "test.input.callback")
        queue.suspend()
        let (fake, monitor) = makeMonitor(callbackQueue: queue)
        monitor.onEvent = { _ in }
        try monitor.start()
        for _ in 0..<70 {
            _ = fake.feed(.keyDown(keyCode: 0x00, modifiers: [], isRepeat: false))
        }
        XCTAssertEqual(monitor.droppedObservationCount, 6)
        monitor.stop()
        queue.resume()
    }
}
