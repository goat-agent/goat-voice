import AppKit
import XCTest
@testable import GoatVoiceApp

final class ShortcutCaptureTests: XCTestCase {
    private var controller: ShortcutCaptureController!
    private var outcomes: [ShortcutCaptureController.Outcome] = []
    private var previews: [String?] = []

    private let rightOption: UInt16 = 0x3D
    private let leftOption: UInt16 = 0x3A
    private let function: UInt16 = 0x3F
    private let keyL: UInt16 = 0x25
    private let esc: UInt16 = 0x35
    private let tab: UInt16 = 0x30

    private let genericOption: UInt = 0x0008_0000
    private let genericFunction: UInt = 0x0080_0000
    private let deviceLeftOption: UInt = 0x0020
    private let deviceRightOption: UInt = 0x0040

    override func setUp() {
        controller = ShortcutCaptureController()
        outcomes = []
        previews = []
        controller.onOutcome = { [weak self] in self?.outcomes.append($0) }
        controller.onPreviewChange = { [weak self] in self?.previews.append($0) }
    }

    private func flagsEvent(keyCode: UInt16, rawFlags: UInt) -> NSEvent {
        NSEvent.keyEvent(
            with: .flagsChanged, location: .zero,
            modifierFlags: NSEvent.ModifierFlags(rawValue: rawFlags),
            timestamp: 0, windowNumber: 0, context: nil,
            characters: "", charactersIgnoringModifiers: "",
            isARepeat: false, keyCode: keyCode)!
    }

    private func keyDownEvent(keyCode: UInt16, rawFlags: UInt) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero,
            modifierFlags: NSEvent.ModifierFlags(rawValue: rawFlags),
            timestamp: 0, windowNumber: 0, context: nil,
            characters: "l", charactersIgnoringModifiers: "l",
            isARepeat: false, keyCode: keyCode)!
    }

    @discardableResult
    private func feed(_ event: NSEvent) -> NSEvent? {
        controller.handle(event)
    }

    private var committed: TriggerShortcut? {
        guard case .committed(let shortcut) = outcomes.last else { return nil }
        return shortcut
    }

    func testRightOptionPressReleaseCommitsRightOption() {
        feed(flagsEvent(keyCode: rightOption, rawFlags: genericOption | deviceRightOption))
        XCTAssertEqual(previews.last, "Right Option")
        feed(flagsEvent(keyCode: rightOption, rawFlags: 0))
        XCTAssertEqual(committed, TriggerShortcut(kind: .modifierOnly(ModifierKey(base: .option, side: .right))))
    }

    func testLeftOptionCommitsLeft() {
        feed(flagsEvent(keyCode: leftOption, rawFlags: genericOption | deviceLeftOption))
        feed(flagsEvent(keyCode: leftOption, rawFlags: 0))
        XCTAssertEqual(committed, TriggerShortcut(kind: .modifierOnly(ModifierKey(base: .option, side: .left))))
    }

    func testFunctionKeyCommitsFunction() {
        feed(flagsEvent(keyCode: function, rawFlags: genericFunction))
        feed(flagsEvent(keyCode: function, rawFlags: 0))
        XCTAssertEqual(committed, TriggerShortcut(kind: .modifierOnly(ModifierKey(base: .function, side: .either))))
    }

    func testRightReleaseWhileLeftHeldDoesNotCommitOrWedge() {
        feed(flagsEvent(keyCode: leftOption, rawFlags: genericOption | deviceLeftOption))
        feed(flagsEvent(keyCode: rightOption, rawFlags: genericOption | deviceLeftOption | deviceRightOption))
        XCTAssertEqual(previews.last, "Left Option + Right Option")

        feed(flagsEvent(keyCode: rightOption, rawFlags: genericOption | deviceLeftOption))
        XCTAssertNil(committed)
        XCTAssertEqual(previews.last, "Left Option")

        feed(flagsEvent(keyCode: leftOption, rawFlags: 0))
        XCTAssertEqual(committed, TriggerShortcut(kind: .modifierOnly(ModifierKey(base: .option, side: .left))))
    }

    func testLeftReleaseWhileRightHeldKeepsRightPreview() {
        feed(flagsEvent(keyCode: rightOption, rawFlags: genericOption | deviceRightOption))
        feed(flagsEvent(keyCode: leftOption, rawFlags: genericOption | deviceLeftOption | deviceRightOption))
        feed(flagsEvent(keyCode: leftOption, rawFlags: genericOption | deviceRightOption))
        XCTAssertEqual(previews.last, "Right Option")

        feed(flagsEvent(keyCode: rightOption, rawFlags: 0))
        XCTAssertEqual(committed, TriggerShortcut(kind: .modifierOnly(ModifierKey(base: .option, side: .right))))
    }

    func testGenericOnlyFlagsStillTrackPress() {
        feed(flagsEvent(keyCode: rightOption, rawFlags: genericOption))
        XCTAssertEqual(previews.last, "Right Option")
        feed(flagsEvent(keyCode: rightOption, rawFlags: 0))
        XCTAssertEqual(committed, TriggerShortcut(kind: .modifierOnly(ModifierKey(base: .option, side: .right))))
    }

    func testOrdinaryKeyWithModifierCommitsChord() {
        feed(flagsEvent(keyCode: rightOption, rawFlags: genericOption | deviceRightOption))
        feed(keyDownEvent(keyCode: keyL, rawFlags: genericOption | deviceRightOption))
        XCTAssertEqual(committed, TriggerShortcut(kind: .chord(Chord(keyCode: keyL, modifiers: [.option]))))
    }

    func testEscapeCancelsCapture() {
        feed(flagsEvent(keyCode: rightOption, rawFlags: genericOption | deviceRightOption))
        feed(keyDownEvent(keyCode: esc, rawFlags: genericOption))
        guard case .cancelled = outcomes.last else {
            return XCTFail("expected cancelled outcome")
        }
    }

    func testPlainTabPassesThrough() {
        let event = keyDownEvent(keyCode: tab, rawFlags: 0)
        XCTAssertNotNil(feed(event))
        XCTAssertTrue(outcomes.isEmpty)
    }

    func testRepeatedDownFlagsKeepSingleHeldEntry() {
        feed(flagsEvent(keyCode: rightOption, rawFlags: genericOption | deviceRightOption))
        feed(flagsEvent(keyCode: rightOption, rawFlags: genericOption | deviceRightOption))
        XCTAssertEqual(previews.last, "Right Option")
        feed(flagsEvent(keyCode: rightOption, rawFlags: 0))
        XCTAssertEqual(committed, TriggerShortcut(kind: .modifierOnly(ModifierKey(base: .option, side: .right))))
    }
}
