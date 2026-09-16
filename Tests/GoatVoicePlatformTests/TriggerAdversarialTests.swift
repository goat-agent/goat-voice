import XCTest
import GoatVoicePlatform

final class TriggerAdversarialTests: XCTestCase {
    private let rightOption: UInt16 = 0x3D
    private let leftOption: UInt16 = 0x3A
    private let leftControl: UInt16 = 0x3B
    private let leftShift: UInt16 = 0x38
    private let space: UInt16 = 0x31
    private let esc: UInt16 = 0x35
    private let f13: UInt16 = 0x69
    private let keyA: UInt16 = 0x00
    private let keyK: UInt16 = 0x28

    private var controlSpace: TriggerSpec { .chord(keyCode: space, modifiers: [.control]) }

    func testModifierOnlyRightOptionBeginsOnPress() {
        let engine = TriggerEngine(spec: .modifier(.rightOption))
        let result = engine.handle(.modifierDown(.rightOption, keyCode: rightOption))
        XCTAssertEqual(result.effects, [.began])
        XCTAssertTrue(result.consume)
        XCTAssertTrue(engine.isActive)
    }

    func testLeftOptionDoesNotStartRightOptionTrigger() {
        let engine = TriggerEngine(spec: .modifier(.rightOption))
        let result = engine.handle(.modifierDown(.leftOption, keyCode: leftOption))
        XCTAssertTrue(result.effects.isEmpty)
        XCTAssertFalse(result.consume)
        XCTAssertFalse(engine.isActive)
    }

    func testChordStartsOnFinalKeyDown() {
        let engine = TriggerEngine(spec: controlSpace)
        let first = engine.handle(.modifierDown(.leftControl, keyCode: leftControl))
        XCTAssertTrue(first.effects.isEmpty)
        XCTAssertFalse(engine.isActive)
        let result = engine.handle(.keyDown(keyCode: space, modifiers: [.leftControl], isRepeat: false))
        XCTAssertEqual(result.effects, [.began])
        XCTAssertTrue(result.consume)
        XCTAssertTrue(engine.isActive)
    }

    func testFunctionKeyTriggerStartsOnKeyDown() {
        let engine = TriggerEngine(spec: .chord(keyCode: f13, modifiers: []))
        let result = engine.handle(.keyDown(keyCode: f13, modifiers: [], isRepeat: false))
        XCTAssertEqual(result.effects, [.began])
        XCTAssertTrue(engine.isActive)
    }

    func testReleasingOnlyTriggerKeyEndsSession() {
        let engine = TriggerEngine(spec: .modifier(.rightOption))
        _ = engine.handle(.modifierDown(.rightOption, keyCode: rightOption))
        let result = engine.handle(.modifierUp(.rightOption, keyCode: rightOption))
        XCTAssertEqual(result.effects, [.ended])
        XCTAssertTrue(result.consume)
        XCTAssertFalse(engine.isActive)
    }

    func testChordEndsWhenEitherRequiredKeyIsReleased() {
        let engine = TriggerEngine(spec: controlSpace)
        _ = engine.handle(.keyDown(keyCode: space, modifiers: [], isRepeat: false))
        _ = engine.handle(.modifierDown(.leftControl, keyCode: leftControl))
        XCTAssertTrue(engine.isActive)
        let byKey = engine.handle(.keyUp(keyCode: space, modifiers: [.leftControl]))
        XCTAssertEqual(byKey.effects, [.ended])
        XCTAssertFalse(engine.isActive)

        _ = engine.handle(.modifierUp(.leftControl, keyCode: leftControl))
        _ = engine.handle(.keyDown(keyCode: space, modifiers: [], isRepeat: false))
        _ = engine.handle(.modifierDown(.leftControl, keyCode: leftControl))
        XCTAssertTrue(engine.isActive)
        let byModifier = engine.handle(.modifierUp(.leftControl, keyCode: leftControl))
        XCTAssertEqual(byModifier.effects, [.ended])
        XCTAssertFalse(engine.isActive)
    }

    func testExtraNonTriggerKeyCancelsAndOriginalEventPasses() {
        let engine = TriggerEngine(spec: .modifier(.rightOption))
        _ = engine.handle(.modifierDown(.rightOption, keyCode: rightOption))
        let result = engine.handle(.keyDown(keyCode: keyK, modifiers: [], isRepeat: false))
        XCTAssertEqual(result.effects, [.cancelledByExtraKey])
        XCTAssertFalse(result.consume)
        XCTAssertFalse(engine.isActive)
    }

    func testTriggerReleaseAfterExtraKeyCancelIsIgnoredThenFullCycleRearms() {
        let engine = TriggerEngine(spec: .modifier(.rightOption))
        _ = engine.handle(.modifierDown(.rightOption, keyCode: rightOption))
        _ = engine.handle(.keyDown(keyCode: keyK, modifiers: [], isRepeat: false))
        let release = engine.handle(.modifierUp(.rightOption, keyCode: rightOption))
        XCTAssertTrue(release.effects.isEmpty)
        XCTAssertFalse(release.consume)
        let repress = engine.handle(.modifierDown(.rightOption, keyCode: rightOption))
        XCTAssertEqual(repress.effects, [.began])
    }

    func testExtraModifierWhileRecordingCancelsAndPasses() {
        let engine = TriggerEngine(spec: .modifier(.rightOption))
        _ = engine.handle(.modifierDown(.rightOption, keyCode: rightOption))
        let result = engine.handle(.modifierDown(.leftShift, keyCode: leftShift))
        XCTAssertEqual(result.effects, [.cancelledByExtraKey])
        XCTAssertFalse(result.consume)
        XCTAssertFalse(engine.isActive)
    }

    func testPartialChordReleaseThenRepressDoesNotRearm() {
        let engine = TriggerEngine(spec: controlSpace)
        _ = engine.handle(.keyDown(keyCode: space, modifiers: [], isRepeat: false))
        _ = engine.handle(.modifierDown(.leftControl, keyCode: leftControl))
        XCTAssertTrue(engine.isActive)
        let end = engine.handle(.modifierUp(.leftControl, keyCode: leftControl))
        XCTAssertEqual(end.effects, [.ended])
        let repress = engine.handle(.modifierDown(.leftControl, keyCode: leftControl))
        XCTAssertTrue(repress.effects.isEmpty)
        XCTAssertFalse(repress.consume)
        XCTAssertFalse(engine.isActive)

        _ = engine.handle(.keyUp(keyCode: space, modifiers: [.leftControl]))
        _ = engine.handle(.modifierUp(.leftControl, keyCode: leftControl))
        _ = engine.handle(.keyDown(keyCode: space, modifiers: [], isRepeat: false))
        let fresh = engine.handle(.modifierDown(.leftControl, keyCode: leftControl))
        XCTAssertEqual(fresh.effects, [.began])
    }

    func testDisarmWhileTriggerHeldBlocksUntilFullRelease() {
        let engine = TriggerEngine(spec: .modifier(.rightOption))
        _ = engine.handle(.modifierDown(.rightOption, keyCode: rightOption))
        engine.disarmUntilTriggerFullyReleased()
        XCTAssertFalse(engine.isActive)
        _ = engine.handle(.modifierUp(.rightOption, keyCode: rightOption))
        let repress = engine.handle(.modifierDown(.rightOption, keyCode: rightOption))
        XCTAssertEqual(repress.effects, [.began])
    }

    func testDisarmWhileChordHeldBlocksRepressOfReleasedMember() {
        let engine = TriggerEngine(spec: controlSpace)
        _ = engine.handle(.keyDown(keyCode: space, modifiers: [], isRepeat: false))
        _ = engine.handle(.modifierDown(.leftControl, keyCode: leftControl))
        XCTAssertTrue(engine.isActive)
        engine.disarmUntilTriggerFullyReleased()
        _ = engine.handle(.keyUp(keyCode: space, modifiers: [.leftControl]))
        let repress = engine.handle(.keyDown(keyCode: space, modifiers: [.leftControl], isRepeat: false))
        XCTAssertFalse(repress.effects.contains(.began))
        XCTAssertFalse(engine.isActive)
    }

    func testRepeatKeyDownWhileDisarmedDoesNotRestart() {
        let engine = TriggerEngine(spec: controlSpace)
        _ = engine.handle(.keyDown(keyCode: space, modifiers: [], isRepeat: false))
        _ = engine.handle(.modifierDown(.leftControl, keyCode: leftControl))
        _ = engine.handle(.keyDown(keyCode: keyK, modifiers: [.leftControl], isRepeat: false))
        let repeated = engine.handle(.keyDown(keyCode: space, modifiers: [.leftControl], isRepeat: true))
        XCTAssertFalse(repeated.effects.contains(.began))
        XCTAssertFalse(engine.isActive)
    }

    func testEscapeConsumedWhileRecording() {
        let engine = TriggerEngine(spec: .modifier(.rightOption))
        _ = engine.handle(.modifierDown(.rightOption, keyCode: rightOption))
        let result = engine.handle(.keyDown(keyCode: esc, modifiers: [], isRepeat: false))
        XCTAssertEqual(result.effects, [.cancelledByEscape])
        XCTAssertTrue(result.consume)
        XCTAssertFalse(engine.isActive)
    }

    func testEscapeConsumedWhileSessionInterruptible() {
        let engine = TriggerEngine(spec: .modifier(.rightOption))
        engine.escapeInterruptsSession = { true }
        let result = engine.handle(.keyDown(keyCode: esc, modifiers: [], isRepeat: false))
        XCTAssertEqual(result.effects, [.cancelledByEscape])
        XCTAssertTrue(result.consume)
    }

    func testEscapePassesThroughAfterPaste() {
        let engine = TriggerEngine(spec: .modifier(.rightOption))
        engine.escapeInterruptsSession = { false }
        let result = engine.handle(.keyDown(keyCode: esc, modifiers: [], isRepeat: false))
        XCTAssertTrue(result.effects.isEmpty)
        XCTAssertFalse(result.consume)
    }

    func testKeyHeldBeforeTriggerDoesNotPreventStart() {
        let engine = TriggerEngine(spec: .modifier(.rightOption))
        _ = engine.handle(.keyDown(keyCode: keyA, modifiers: [], isRepeat: false))
        let result = engine.handle(.modifierDown(.rightOption, keyCode: rightOption))
        XCTAssertEqual(result.effects, [.began])
        XCTAssertTrue(engine.isActive)
    }

    func testRepeatOfKeyHeldBeforeSessionStartDoesNotCancel() {
        let engine = TriggerEngine(spec: .modifier(.rightOption))
        _ = engine.handle(.keyDown(keyCode: keyA, modifiers: [], isRepeat: false))
        _ = engine.handle(.modifierDown(.rightOption, keyCode: rightOption))
        XCTAssertTrue(engine.isActive)
        let repeated = engine.handle(.keyDown(keyCode: keyA, modifiers: [], isRepeat: true))
        XCTAssertFalse(repeated.effects.contains(.cancelledByExtraKey))
        XCTAssertTrue(engine.isActive)
    }

    func testReleaseOfKeyHeldBeforeTriggerReachesForegroundApp() {
        let engine = TriggerEngine(spec: .modifier(.rightOption))
        _ = engine.handle(.keyDown(keyCode: keyA, modifiers: [], isRepeat: false))
        _ = engine.handle(.modifierDown(.rightOption, keyCode: rightOption))
        let result = engine.handle(.keyUp(keyCode: keyA, modifiers: []))
        XCTAssertFalse(result.consume)
        XCTAssertTrue(engine.isActive)
    }

    func testReleaseOfModifierHeldBeforeTriggerReachesForegroundApp() {
        let engine = TriggerEngine(spec: .modifier(.rightOption))
        _ = engine.handle(.modifierDown(.leftShift, keyCode: leftShift))
        _ = engine.handle(.modifierDown(.rightOption, keyCode: rightOption))
        XCTAssertTrue(engine.isActive)
        let result = engine.handle(.modifierUp(.leftShift, keyCode: leftShift))
        XCTAssertFalse(result.consume)
        XCTAssertTrue(engine.isActive)
    }
}
