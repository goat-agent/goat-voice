import CoreGraphics
import XCTest
@testable import GoatVoicePlatform

final class ModifierEventTests: XCTestCase {
    private let rightOption: UInt16 = 0x3D
    private let leftOption: UInt16 = 0x3A
    private let leftControl: UInt16 = 0x3B
    private let rightControl: UInt16 = 0x3E
    private let leftCommand: UInt16 = 0x37
    private let rightCommand: UInt16 = 0x36
    private let leftShift: UInt16 = 0x38
    private let rightShift: UInt16 = 0x3C
    private let function: UInt16 = 0x3F
    private let capsLock: UInt16 = 0x39
    private let keyL: UInt16 = 0x25
    private let keyK: UInt16 = 0x28
    private let f13: UInt16 = 0x69

    private let genericOption: UInt64 = 0x0008_0000
    private let genericControl: UInt64 = 0x0004_0000
    private let genericShift: UInt64 = 0x0002_0000
    private let genericCommand: UInt64 = 0x0010_0000
    private let genericFunction: UInt64 = 0x0080_0000
    private let deviceLeftOption: UInt64 = 0x0020
    private let deviceRightOption: UInt64 = 0x0040
    private let deviceLeftControl: UInt64 = 0x0001
    private let deviceRightControl: UInt64 = 0x2000
    private let deviceLeftShift: UInt64 = 0x0002
    private let deviceRightShift: UInt64 = 0x0004
    private let deviceLeftCommand: UInt64 = 0x0008
    private let deviceRightCommand: UInt64 = 0x0010

    private func flagsEvent(keyCode: UInt16, rawFlags: UInt64, keyDown: Bool = true) -> CGEvent {
        let event = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(keyCode), keyDown: keyDown)!
        event.flags = CGEventFlags(rawValue: rawFlags)
        return event
    }

    private func translated(keyCode: UInt16, rawFlags: UInt64, keyDown: Bool = true) -> InputEvent? {
        let event = flagsEvent(keyCode: keyCode, rawFlags: rawFlags, keyDown: keyDown)
        return CGEventTapMonitor.translate(type: event.type, event: event)
    }

    func testRightOptionPressDecodesAsModifierDown() {
        XCTAssertEqual(
            translated(keyCode: rightOption, rawFlags: genericOption | deviceRightOption),
            .modifierDown(.rightOption, keyCode: rightOption))
    }

    func testRightOptionReleaseWhileLeftHeldDecodesAsUp() {
        XCTAssertEqual(
            translated(keyCode: rightOption, rawFlags: genericOption | deviceLeftOption, keyDown: false),
            .modifierUp(.rightOption, keyCode: rightOption))
    }

    func testLeftOptionReleaseWhileRightHeldDecodesAsUp() {
        XCTAssertEqual(
            translated(keyCode: leftOption, rawFlags: genericOption | deviceRightOption, keyDown: false),
            .modifierUp(.leftOption, keyCode: leftOption))
    }

    func testLeftOptionPressDecodesAsLeft() {
        XCTAssertEqual(
            translated(keyCode: leftOption, rawFlags: genericOption | deviceLeftOption),
            .modifierDown(.leftOption, keyCode: leftOption))
    }

    func testReleaseWithNoHeldFlagsDecodesAsUp() {
        XCTAssertEqual(
            translated(keyCode: rightOption, rawFlags: 0, keyDown: false),
            .modifierUp(.rightOption, keyCode: rightOption))
    }

    func testGenericOnlyFlagsFallBackToFamilyBit() {
        XCTAssertEqual(
            translated(keyCode: rightOption, rawFlags: genericOption),
            .modifierDown(.rightOption, keyCode: rightOption))
        XCTAssertEqual(
            translated(keyCode: leftOption, rawFlags: 0, keyDown: false),
            .modifierUp(.leftOption, keyCode: leftOption))
    }

    func testRightControlUsesItsDeviceBit() {
        XCTAssertEqual(
            translated(keyCode: rightControl, rawFlags: genericControl | deviceRightControl),
            .modifierDown(.rightControl, keyCode: rightControl))
        XCTAssertEqual(
            translated(keyCode: rightControl, rawFlags: genericControl | deviceLeftControl, keyDown: false),
            .modifierUp(.rightControl, keyCode: rightControl))
    }

    func testShiftAndCommandSidesDecode() {
        XCTAssertEqual(
            translated(keyCode: rightShift, rawFlags: genericShift | deviceRightShift),
            .modifierDown(.rightShift, keyCode: rightShift))
        XCTAssertEqual(
            translated(keyCode: leftShift, rawFlags: genericShift | deviceRightShift, keyDown: false),
            .modifierUp(.leftShift, keyCode: leftShift))
        XCTAssertEqual(
            translated(keyCode: leftCommand, rawFlags: genericCommand | deviceLeftCommand),
            .modifierDown(.leftCommand, keyCode: leftCommand))
        XCTAssertEqual(
            translated(keyCode: rightCommand, rawFlags: genericCommand | deviceLeftCommand, keyDown: false),
            .modifierUp(.rightCommand, keyCode: rightCommand))
    }

    func testFunctionKeyDecodesFromSecondaryFnBit() {
        XCTAssertEqual(
            translated(keyCode: function, rawFlags: genericFunction),
            .modifierDown(.function, keyCode: function))
        XCTAssertEqual(
            translated(keyCode: function, rawFlags: 0, keyDown: false),
            .modifierUp(.function, keyCode: function))
    }

    func testNonModifierKeyProducesNoModifierEvent() {
        XCTAssertNil(translated(keyCode: capsLock, rawFlags: 0, keyDown: false))
        XCTAssertNil(ModifierTransition(keyCode: keyL, rawFlags: genericOption | deviceRightOption))
    }

    func testOrdinaryKeyTranslationUnchanged() {
        let down = flagsEvent(keyCode: keyL, rawFlags: genericOption | deviceRightOption)
        XCTAssertEqual(
            CGEventTapMonitor.translate(type: down.type, event: down),
            .keyDown(keyCode: keyL, modifiers: [.option], isRepeat: false))

        let f13Event = flagsEvent(keyCode: f13, rawFlags: 0)
        XCTAssertEqual(
            CGEventTapMonitor.translate(type: f13Event.type, event: f13Event),
            .keyDown(keyCode: f13, modifiers: [], isRepeat: false))

        let repeatEvent = flagsEvent(keyCode: keyL, rawFlags: 0)
        repeatEvent.setIntegerValueField(.keyboardEventAutorepeat, value: 1)
        XCTAssertEqual(
            CGEventTapMonitor.translate(type: repeatEvent.type, event: repeatEvent),
            .keyDown(keyCode: keyL, modifiers: [], isRepeat: true))

        let up = flagsEvent(keyCode: keyL, rawFlags: 0, keyDown: false)
        XCTAssertEqual(
            CGEventTapMonitor.translate(type: up.type, event: up),
            .keyUp(keyCode: keyL, modifiers: []))
    }

    func testStaleProbeFalseOnGenuineModifierDownDoesNotEndSession() {
        let engine = TriggerEngine(spec: .modifier(.rightOption))
        engine.keyStateProbe = { _ in false }

        let down = engine.handle(.modifierDown(.rightOption, keyCode: rightOption))
        XCTAssertEqual(down.effects, [.began])
        XCTAssertTrue(down.consume)
        XCTAssertTrue(engine.isActive)

        XCTAssertEqual(engine.handle(.scrollWheel).effects, [])
        XCTAssertTrue(engine.isActive)

        let up = engine.handle(.modifierUp(.rightOption, keyCode: rightOption))
        XCTAssertEqual(up.effects, [.ended])
        XCTAssertTrue(engine.isArmed)
    }

    func testRemappedEventSourceKeepsSessionUntilEventRelease() {
        let engine = TriggerEngine(spec: .modifier(.rightOption))
        engine.keyStateProbe = { _ in false }

        XCTAssertEqual(engine.handle(.modifierDown(.rightOption, keyCode: rightOption)).effects, [.began])
        XCTAssertEqual(engine.handle(.modifierDown(.rightOption, keyCode: rightOption)).effects, [])
        XCTAssertEqual(engine.handle(.scrollWheel).effects, [])
        XCTAssertTrue(engine.isActive)

        XCTAssertEqual(engine.handle(.modifierUp(.rightOption, keyCode: rightOption)).effects, [.ended])
        XCTAssertFalse(engine.isActive)
        XCTAssertTrue(engine.isArmed)
    }

    func testDisarmWhileProbeUnconfirmedTriggerHeldStaysDisarmed() {
        let engine = TriggerEngine(spec: .modifier(.rightOption))
        engine.keyStateProbe = { _ in false }

        _ = engine.handle(.modifierDown(.rightOption, keyCode: rightOption))
        engine.disarmUntilTriggerFullyReleased()
        XCTAssertFalse(engine.isArmed)

        let repress = engine.handle(.modifierDown(.rightOption, keyCode: rightOption))
        XCTAssertEqual(repress.effects, [])
        XCTAssertFalse(engine.isActive)

        _ = engine.handle(.modifierUp(.rightOption, keyCode: rightOption))
        let fresh = engine.handle(.modifierDown(.rightOption, keyCode: rightOption))
        XCTAssertEqual(fresh.effects, [.began])
    }

    func testLaggingProbeConfirmsThenHealsMissedRelease() {
        let physical = KeyStateBox()
        let engine = TriggerEngine(spec: .modifier(.rightOption))
        engine.keyStateProbe = { physical.down.contains($0) }

        XCTAssertEqual(engine.handle(.modifierDown(.rightOption, keyCode: rightOption)).effects, [.began])
        XCTAssertTrue(engine.isActive)

        physical.down.insert(rightOption)
        XCTAssertEqual(engine.handle(.scrollWheel).effects, [])
        XCTAssertTrue(engine.isActive)

        physical.down.removeAll()
        let healed = engine.handle(.scrollWheel)
        XCTAssertEqual(healed.effects, [.ended])
        XCTAssertTrue(engine.isArmed)
    }

    func testLostKeyupRecoveryStillWorksAfterConfirmation() {
        let physical = KeyStateBox()
        physical.down.insert(rightOption)
        let engine = TriggerEngine(spec: .modifier(.rightOption))
        engine.keyStateProbe = { physical.down.contains($0) }

        _ = engine.handle(.modifierDown(.rightOption, keyCode: rightOption))
        XCTAssertTrue(engine.isActive)

        physical.down.removeAll()
        let result = engine.handle(.keyUp(keyCode: keyK, modifiers: []))
        XCTAssertEqual(result.effects, [.ended])
        XCTAssertFalse(engine.isActive)
    }

    func testLeftRightSimultaneitySideReleaseEndsOnlyMatchingTrigger() {
        let engine = TriggerEngine(spec: .modifier(.rightOption))

        XCTAssertEqual(engine.handle(.modifierDown(.leftOption, keyCode: leftOption)).effects, [])
        XCTAssertEqual(engine.handle(.modifierDown(.rightOption, keyCode: rightOption)).effects, [.began])
        XCTAssertTrue(engine.isActive)

        let releaseRight = engine.handle(.modifierUp(.rightOption, keyCode: rightOption))
        XCTAssertEqual(releaseRight.effects, [.ended])
        XCTAssertTrue(engine.isArmed)

        XCTAssertEqual(engine.handle(.modifierUp(.leftOption, keyCode: leftOption)).effects, [])
        XCTAssertEqual(engine.handle(.modifierDown(.rightOption, keyCode: rightOption)).effects, [.began])
    }

    func testReleaseOfOppositeSideWhileTriggerHeldKeepsSession() {
        let engine = TriggerEngine(spec: .modifier(.rightOption))

        _ = engine.handle(.modifierDown(.leftOption, keyCode: leftOption))
        _ = engine.handle(.modifierDown(.rightOption, keyCode: rightOption))
        let releaseLeft = engine.handle(.modifierUp(.leftOption, keyCode: leftOption))
        XCTAssertEqual(releaseLeft.effects, [])
        XCTAssertTrue(engine.isActive)

        XCTAssertEqual(engine.handle(.modifierUp(.rightOption, keyCode: rightOption)).effects, [.ended])
    }

    func testRepeatedFlagsChangedDoesNotDuplicateEffects() {
        let engine = TriggerEngine(spec: .modifier(.rightOption))

        XCTAssertEqual(engine.handle(.modifierDown(.rightOption, keyCode: rightOption)).effects, [.began])
        XCTAssertEqual(engine.handle(.modifierDown(.rightOption, keyCode: rightOption)).effects, [])
        XCTAssertTrue(engine.isActive)

        XCTAssertEqual(engine.handle(.modifierUp(.rightOption, keyCode: rightOption)).effects, [.ended])
        XCTAssertEqual(engine.handle(.modifierUp(.rightOption, keyCode: rightOption)).effects, [])
        XCTAssertTrue(engine.isArmed)
    }

    func testFunctionModifierTriggerBeginsAndEnds() {
        let engine = TriggerEngine(spec: .modifier(.function))

        XCTAssertEqual(engine.handle(.modifierDown(.function, keyCode: function)).effects, [.began])
        XCTAssertTrue(engine.isActive)
        XCTAssertEqual(engine.handle(.modifierUp(.function, keyCode: function)).effects, [.ended])
    }

    func testBusyPressReleaseCyclesRearmEachTime() {
        let engine = TriggerEngine(spec: .modifier(.rightOption))

        for _ in 0..<3 {
            XCTAssertEqual(engine.handle(.modifierDown(.rightOption, keyCode: rightOption)).effects, [.began])
            XCTAssertEqual(engine.handle(.modifierUp(.rightOption, keyCode: rightOption)).effects, [.ended])
            XCTAssertTrue(engine.isArmed)
        }
    }

    func testExtraKeyCancelThenFullCycleRearms() {
        let engine = TriggerEngine(spec: .modifier(.rightOption))

        _ = engine.handle(.modifierDown(.rightOption, keyCode: rightOption))
        let extra = engine.handle(.keyDown(keyCode: keyK, modifiers: [.option], isRepeat: false))
        XCTAssertEqual(extra.effects, [.cancelledByExtraKey])
        XCTAssertFalse(extra.consume)

        _ = engine.handle(.keyUp(keyCode: keyK, modifiers: []))
        _ = engine.handle(.modifierUp(.rightOption, keyCode: rightOption))
        XCTAssertEqual(engine.handle(.modifierDown(.rightOption, keyCode: rightOption)).effects, [.began])
    }

    func testChordTriggersUnaffected() {
        let engine = TriggerEngine(spec: .chord(keyCode: keyL, modifiers: [.option]))

        _ = engine.handle(.modifierDown(.rightOption, keyCode: rightOption))
        let began = engine.handle(.keyDown(keyCode: keyL, modifiers: [.option], isRepeat: false))
        XCTAssertEqual(began.effects, [.began])

        XCTAssertEqual(engine.handle(.keyUp(keyCode: keyL, modifiers: [.option])).effects, [.ended])
    }

    func testMonitorWiredProbeDoesNotSynthesizeEndOnFreshPress() throws {
        final class FakeMonitor: SystemInputEventMonitoring {
            var handler: (@Sendable (InputEvent) -> Bool)?
            func start() throws {}
            func stop() {}
            @discardableResult
            func feed(_ event: InputEvent) -> Bool { handler?(event) ?? false }
        }

        let fake = FakeMonitor()
        let engine = TriggerEngine(spec: .modifier(.rightOption))
        let monitor = InputTriggerMonitor(monitor: fake, engine: engine)
        let recorder = CallbackRecorder()
        _ = monitor.addSynchronousObserver { recorder.append($0) }
        try monitor.start()

        XCTAssertTrue(fake.feed(.modifierDown(.rightOption, keyCode: rightOption)))
        XCTAssertEqual(recorder.observations.map(\.effects), [[.began]])
        XCTAssertTrue(monitor.isSessionActive())
    }
}
