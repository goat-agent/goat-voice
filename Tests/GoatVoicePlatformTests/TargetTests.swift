import XCTest
@testable import GoatVoicePlatform

final class FakeAccessibilityBackend: AccessibilityBackend, @unchecked Sendable {
    private struct State {
        var trusted = true
        var focusedToken: AXElementToken?
        var throwOnFocus: Error?
        var windowIDs: [ObjectIdentifier: CGWindowID] = [:]
        var boundsByWindow: [ObjectIdentifier: CGRect] = [:]
        var bundleID = "com.example.editor"
        var observationError: Error?
        var mutationCallback: (@Sendable (AXMutationEvent) -> Void)?
        var activeObservations = 0
        var adjacent: (before: String, after: String)? = ("", "")
        var windowTokens: [ObjectIdentifier: AXElementToken] = [:]
        var fingerprint: AXMutationFingerprint?
    }

    private var state = State()
    private let lock = NSLock()

    private func withState<T>(_ body: (inout State) throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body(&state)
    }

    var trusted: Bool {
        get { withState { $0.trusted } }
        set { withState { $0.trusted = newValue } }
    }

    var focusedToken: AXElementToken? {
        get { withState { $0.focusedToken } }
        set { withState { $0.focusedToken = newValue } }
    }

    var throwOnFocus: Error? {
        get { withState { $0.throwOnFocus } }
        set { withState { $0.throwOnFocus = newValue } }
    }

    var windowIDs: [ObjectIdentifier: CGWindowID] {
        get { withState { $0.windowIDs } }
        set { withState { $0.windowIDs = newValue } }
    }

    var boundsByWindow: [ObjectIdentifier: CGRect] {
        get { withState { $0.boundsByWindow } }
        set { withState { $0.boundsByWindow = newValue } }
    }

    var bundleID: String {
        get { withState { $0.bundleID } }
        set { withState { $0.bundleID = newValue } }
    }

    var observationError: Error? {
        get { withState { $0.observationError } }
        set { withState { $0.observationError = newValue } }
    }

    var mutationCallback: (@Sendable (AXMutationEvent) -> Void)? {
        withState { $0.mutationCallback }
    }

    var activeObservations: Int {
        withState { $0.activeObservations }
    }

    var adjacent: (before: String, after: String)? {
        get { withState { $0.adjacent } }
        set { withState { $0.adjacent = newValue } }
    }

    var windowTokens: [ObjectIdentifier: AXElementToken] {
        get { withState { $0.windowTokens } }
        set { withState { $0.windowTokens = newValue } }
    }

    var fingerprint: AXMutationFingerprint? {
        get { withState { $0.fingerprint } }
        set { withState { $0.fingerprint = newValue } }
    }

    func isProcessTrusted() -> Bool { withState { $0.trusted } }

    func focusedEditableElement() throws -> AXElementToken {
        try withState { state in
            if let error = state.throwOnFocus { throw error }
            guard state.trusted else { throw TargetResolutionError.accessibilityUnavailable }
            guard let token = state.focusedToken else { throw TargetResolutionError.noFocusedElement }
            return token
        }
    }

    func element(_ token: AXElementToken, isSameAs other: AXElementToken) -> Bool {
        token == other
    }

    func windowID(of token: AXElementToken) -> CGWindowID? {
        withState { $0.windowIDs[ObjectIdentifier(token.element)] }
    }

    func windowToken(of token: AXElementToken) -> AXElementToken? {
        withState { $0.windowTokens[ObjectIdentifier(token.element)] }
    }

    func mutationFingerprint(of token: AXElementToken) -> AXMutationFingerprint? {
        withState { $0.fingerprint }
    }

    func windowBounds(of token: AXElementToken) -> CGRect? {
        withState { $0.boundsByWindow[ObjectIdentifier(token.element)] }
    }

    func bundleIdentifier(of token: AXElementToken) -> String? {
        withState { $0.bundleID }
    }

    func observeMutations(of token: AXElementToken,
                          onMutation: @escaping @Sendable (AXMutationEvent) -> Void) throws -> AXObservation {
        try withState { state in
            if let error = state.observationError { throw error }
            state.mutationCallback = onMutation
            state.activeObservations += 1
        }
        return AXObservation { [weak self] in
            self?.withState { $0.activeObservations -= 1 }
        }
    }

    func adjacentContext(of token: AXElementToken,
                         radius: Int) -> (before: String, after: String)? {
        withState { $0.adjacent }
    }
}

final class FakeDisplayLookup: DisplayLookingUp, @unchecked Sendable {
    private var stored: CGDirectDisplayID?
    private let lock = NSLock()

    var result: CGDirectDisplayID? {
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

    func displayID(containing bounds: CGRect) -> CGDirectDisplayID? { result }
}

final class TargetResolverTests: XCTestCase {
    private var backend: FakeAccessibilityBackend!
    private var displays: FakeDisplayLookup!
    private var resolver: TargetResolver!
    private var fieldA: AXElementToken!
    private var fieldB: AXElementToken!

    override func setUp() {
        backend = FakeAccessibilityBackend()
        displays = FakeDisplayLookup()
        resolver = TargetResolver(backend: backend, displayLookup: displays)
        fieldA = AXElementToken(element: NSObject(), pid: 4242)
        fieldB = AXElementToken(element: NSObject(), pid: 4242)
    }

    private func attachWindow(_ token: AXElementToken, id: CGWindowID,
                            bounds: CGRect = CGRect(x: 0, y: 0, width: 800, height: 600)) {
        backend.windowIDs[ObjectIdentifier(token.element)] = id
        backend.boundsByWindow[ObjectIdentifier(token.element)] = bounds
    }

    func testCaptureTargetBuildsStrongDescriptor() throws {
        backend.focusedToken = fieldA
        attachWindow(fieldA, id: 77)
        displays.result = 5

        let target = try resolver.captureTarget()
        XCTAssertEqual(target.elementToken, fieldA)
        XCTAssertEqual(target.windowID, 77)
        XCTAssertEqual(target.bundleIdentifier, "com.example.editor")
        XCTAssertEqual(target.displayID, 5)
    }

    func testCaptureFailsWithoutFocusedElement() {
        backend.focusedToken = nil
        XCTAssertThrowsError(try resolver.captureTarget()) { error in
            XCTAssertEqual(error as? TargetResolutionError, .noFocusedElement)
        }
    }

    func testCaptureFailsWhenUntrusted() {
        backend.trusted = false
        backend.focusedToken = fieldA
        XCTAssertThrowsError(try resolver.captureTarget()) { error in
            XCTAssertEqual(error as? TargetResolutionError, .accessibilityUnavailable)
        }
    }

    func testCaptureFailsWithoutAnyWindowIdentity() {
        backend.focusedToken = fieldA
        XCTAssertThrowsError(try resolver.captureTarget()) { error in
            XCTAssertEqual(error as? TargetResolutionError, .windowIdentityUnavailable)
        }
    }

    func testCaptureSucceedsWithBoundsOnly() throws {
        backend.focusedToken = fieldA
        backend.boundsByWindow[ObjectIdentifier(fieldA.element)] = CGRect(x: 1, y: 2, width: 3, height: 4)
        displays.result = 9
        let target = try resolver.captureTarget()
        XCTAssertNil(target.windowID)
        XCTAssertEqual(target.displayID, 9)
    }

    func testVerifySameEditableTarget() throws {
        backend.focusedToken = fieldA
        attachWindow(fieldA, id: 77)
        let target = try resolver.captureTarget()
        XCTAssertTrue(resolver.verifySameEditableTarget(target))
    }

    func testVerifyRejectsSiblingFieldSameWindow() throws {
        backend.focusedToken = fieldA
        attachWindow(fieldA, id: 77)
        let target = try resolver.captureTarget()

        backend.focusedToken = fieldB
        attachWindow(fieldB, id: 77)
        XCTAssertFalse(resolver.verifySameEditableTarget(target))
    }

    func testVerifyRejectsDifferentProcess() throws {
        backend.focusedToken = fieldA
        attachWindow(fieldA, id: 77)
        let target = try resolver.captureTarget()

        let foreignField = AXElementToken(element: fieldA.element, pid: 9999)
        backend.focusedToken = foreignField
        XCTAssertFalse(resolver.verifySameEditableTarget(target))
    }

    func testVerifyRejectsWhenFocusUnresolvable() throws {
        backend.focusedToken = fieldA
        attachWindow(fieldA, id: 77)
        let target = try resolver.captureTarget()

        backend.focusedToken = nil
        XCTAssertFalse(resolver.verifySameEditableTarget(target))

        backend.throwOnFocus = TargetResolutionError.noFocusedElement
        backend.focusedToken = fieldA
        XCTAssertFalse(resolver.verifySameEditableTarget(target))
    }

    func testVerifyRejectsChangedWindow() throws {
        backend.focusedToken = fieldA
        attachWindow(fieldA, id: 77)
        let target = try resolver.captureTarget()

        backend.windowIDs[ObjectIdentifier(fieldA.element)] = 88
        XCTAssertFalse(resolver.verifySameEditableTarget(target))
    }

    func testVerificationMapsResolutionFailures() throws {
        backend.focusedToken = fieldA
        attachWindow(fieldA, id: 77)
        let target = try resolver.captureTarget()

        backend.trusted = false
        XCTAssertEqual(resolver.verify(target), .accessibilityUnavailable)
        backend.trusted = true

        backend.focusedToken = nil
        XCTAssertEqual(resolver.verify(target), .noFocusedElement)

        backend.throwOnFocus = TargetResolutionError.focusedElementNotEditable
        backend.focusedToken = fieldA
        XCTAssertEqual(resolver.verify(target), .focusedNotEditable)
        backend.throwOnFocus = nil
    }

    func testWindowTokenVerificationIgnoresIDChange() throws {
        let window = AXElementToken(element: NSObject(), pid: 4242)
        backend.focusedToken = fieldA
        attachWindow(fieldA, id: 77)
        backend.windowTokens[ObjectIdentifier(fieldA.element)] = window
        let target = try resolver.captureTarget()
        XCTAssertEqual(target.windowToken, window)

        backend.windowIDs[ObjectIdentifier(fieldA.element)] = 88
        XCTAssertEqual(resolver.verify(target), .same)
        XCTAssertTrue(resolver.verifySameEditableTarget(target))
    }

    func testWindowTokenVerificationRejectsDifferentWindow() throws {
        backend.focusedToken = fieldA
        attachWindow(fieldA, id: 77)
        backend.windowTokens[ObjectIdentifier(fieldA.element)] =
            AXElementToken(element: NSObject(), pid: 4242)
        let target = try resolver.captureTarget()

        backend.windowTokens[ObjectIdentifier(fieldA.element)] =
            AXElementToken(element: NSObject(), pid: 4242)
        XCTAssertEqual(resolver.verify(target), .differentWindow)
        XCTAssertFalse(resolver.verifySameEditableTarget(target))
    }

    func testWindowTokenMissingAtVerifyRejects() throws {
        backend.focusedToken = fieldA
        attachWindow(fieldA, id: 77)
        backend.windowTokens[ObjectIdentifier(fieldA.element)] =
            AXElementToken(element: NSObject(), pid: 4242)
        let target = try resolver.captureTarget()

        backend.windowTokens.removeAll()
        XCTAssertEqual(resolver.verify(target), .differentWindow)
    }
}

final class SecureInputFlag: @unchecked Sendable {
    private var enabled = false
    private let lock = NSLock()

    var isEnabled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return enabled
    }

    func set(_ value: Bool) {
        lock.lock()
        enabled = value
        lock.unlock()
    }
}

final class UserIntentGuardTests: XCTestCase {
    private var backend: FakeAccessibilityBackend!
    private var guard_: UserIntentGuard!
    private var target: TargetDescriptor!
    private var secureInput: SecureInputFlag!

    override func setUp() {
        backend = FakeAccessibilityBackend()
        backend.focusedToken = AXElementToken(element: NSObject(), pid: 4242)
        backend.windowIDs[ObjectIdentifier(backend.focusedToken!.element)] = 7
        let resolver = TargetResolver(backend: backend, displayLookup: FakeDisplayLookup())
        target = try! resolver.captureTarget()
        secureInput = SecureInputFlag()
        let flag = secureInput!
        guard_ = UserIntentGuard(backend: backend, secureInputProbe: { flag.isEnabled })
    }

    override func tearDown() {
        guard_.end()
    }

    func testCleanWhenNoMutation() {
        guard_.begin(target: target)
        guard_.observe(.modifierDown(.shift, keyCode: 0x38))
        guard_.observe(.keyUp(keyCode: 0x7B, modifiers: []))
        guard_.observe(.scrollWheel)
        XCTAssertEqual(guard_.verdict(), .clean)
    }

    func testPrintableKeyIsMutation() {
        guard_.begin(target: target)
        guard_.observe(.keyDown(keyCode: 0x00, modifiers: [], isRepeat: false))
        XCTAssertEqual(guard_.verdict(), .mutated)
    }

    func testCaretNavigationIsMutation() {
        guard_.begin(target: target)
        guard_.observe(.keyDown(keyCode: 0x7B, modifiers: [], isRepeat: false))
        XCTAssertEqual(guard_.verdict(), .mutated)
    }

    func testDeleteIsMutation() {
        guard_.begin(target: target)
        guard_.observe(.keyDown(keyCode: 0x33, modifiers: [], isRepeat: false))
        XCTAssertEqual(guard_.verdict(), .mutated)
    }

    func testPointerInteractionIsMutation() {
        guard_.begin(target: target)
        guard_.observe(.pointerDown)
        XCTAssertEqual(guard_.verdict(), .mutated)
    }

    func testCopyChordAloneIsNotMutation() {
        guard_.begin(target: target)
        guard_.observe(.keyDown(keyCode: 0x08, modifiers: [.command], isRepeat: false))
        XCTAssertEqual(guard_.verdict(), .clean)
    }

    func testOtherCommandChordsAreMutations() {
        guard_.begin(target: target)
        guard_.observe(.keyDown(keyCode: 0x09, modifiers: [.command], isRepeat: false))
        XCTAssertEqual(guard_.verdict(), .mutated)
    }

    func testEscapeIsNotClassifiedAsMutation() {
        guard_.begin(target: target)
        guard_.observe(.keyDown(keyCode: 0x35, modifiers: [], isRepeat: false))
        XCTAssertEqual(guard_.verdict(), .clean)
    }

    func testAXMutationCallbackFlagsMutation() {
        guard_.begin(target: target)
        backend.mutationCallback?(.valueChanged)
        XCTAssertEqual(guard_.verdict(), .mutated)
    }

    func testObservationInstallFailureIsUntrusted() {
        backend.observationError = TargetResolutionError.noFocusedElement
        guard_.begin(target: target)
        XCTAssertEqual(guard_.verdict(), .untrusted)
    }

    func testSecureInputIsUntrusted() {
        guard_.begin(target: target)
        secureInput.set(true)
        guard_.observe(.modifierUp(.option, keyCode: 0x3A))
        XCTAssertEqual(guard_.verdict(), .untrusted)
    }

    func testSecureInputAtVerdictIsUntrusted() {
        guard_.begin(target: target)
        secureInput.set(true)
        XCTAssertEqual(guard_.verdict(), .untrusted)
    }

    func testVerdictBeforeBeginIsUntrusted() {
        XCTAssertEqual(guard_.verdict(), .untrusted)
    }

    func testEndDisarmsAndInvalidates() {
        guard_.begin(target: target)
        XCTAssertEqual(backend.activeObservations, 1)
        guard_.end()
        XCTAssertEqual(backend.activeObservations, 0)
        guard_.observe(.keyDown(keyCode: 0x00, modifiers: [], isRepeat: false))
        XCTAssertEqual(guard_.verdict(), .untrusted)
    }

    func testBeginReplacesPriorObservation() {
        guard_.begin(target: target)
        guard_.begin(target: target)
        XCTAssertEqual(backend.activeObservations, 1)
        XCTAssertEqual(guard_.verdict(), .clean)
    }

    func testStaleGenerationCallbackDoesNotMutate() {
        guard_.begin(target: target)
        let staleCallback = backend.mutationCallback
        guard_.begin(target: target)
        staleCallback?(.valueChanged)
        XCTAssertEqual(guard_.verdict(), .clean)
        backend.mutationCallback?(.valueChanged)
        XCTAssertEqual(guard_.verdict(), .mutated)
    }

    func testCallbackAfterEndDoesNotMutate() {
        guard_.begin(target: target)
        let callback = backend.mutationCallback
        guard_.end()
        callback?(.valueChanged)
        XCTAssertEqual(guard_.verdict(), .untrusted)
    }

    func testSelectionSignalWithUnchangedFingerprintIsIgnored() {
        backend.fingerprint = AXMutationFingerprint(
            selectionLocation: 3, selectionLength: 0, characterCount: 10)
        guard_.begin(target: target)
        backend.mutationCallback?(.selectionChanged)
        XCTAssertEqual(guard_.verdict(), .clean)
        XCTAssertEqual(guard_.verdictDetail().source, nil)
    }

    func testValueChangeWithSameLengthAndSelectionIsStillMutation() {
        backend.fingerprint = AXMutationFingerprint(
            selectionLocation: 3, selectionLength: 0, characterCount: 10)
        guard_.begin(target: target)
        backend.mutationCallback?(.valueChanged)
        XCTAssertEqual(guard_.verdict(), .mutated)
    }

    func testSignalWithChangedFingerprintIsMutation() {
        backend.fingerprint = AXMutationFingerprint(
            selectionLocation: 3, selectionLength: 0, characterCount: 10)
        guard_.begin(target: target)
        backend.fingerprint = AXMutationFingerprint(
            selectionLocation: 4, selectionLength: 0, characterCount: 11)
        backend.mutationCallback?(.valueChanged)
        XCTAssertEqual(guard_.verdict(), .mutated)
        XCTAssertEqual(guard_.verdictDetail().source, .accessibilityMutation)
    }

    func testSignalWithUnverifiableFingerprintIsMutation() {
        backend.fingerprint = nil
        guard_.begin(target: target)
        backend.mutationCallback?(.valueChanged)
        XCTAssertEqual(guard_.verdict(), .mutated)
        XCTAssertEqual(guard_.verdictDetail().source, .accessibilitySignal)
    }

    func testFingerprintLostAfterBaselineIsMutation() {
        backend.fingerprint = AXMutationFingerprint(
            selectionLocation: 0, selectionLength: 0, characterCount: 5)
        guard_.begin(target: target)
        backend.fingerprint = nil
        backend.mutationCallback?(.valueChanged)
        XCTAssertEqual(guard_.verdict(), .mutated)
        XCTAssertEqual(guard_.verdictDetail().source, .accessibilityMutation)
    }

    func testMutationSourcesAreRecorded() {
        guard_.begin(target: target)
        guard_.observe(.keyDown(keyCode: 0x00, modifiers: [], isRepeat: false))
        XCTAssertEqual(guard_.verdictDetail().source, .keyboard)

        guard_.end()
        backend.observationError = nil
        guard_.begin(target: target)
        guard_.observe(.pointerDrag)
        XCTAssertEqual(guard_.verdictDetail().source, .pointer)

        guard_.end()
        backend.observationError = TargetResolutionError.noFocusedElement
        guard_.begin(target: target)
        XCTAssertEqual(guard_.verdictDetail().source, .observationUnavailable)
        backend.observationError = nil
    }

    func testSecureInputSourceRecorded() {
        secureInput.set(true)
        guard_.begin(target: target)
        XCTAssertEqual(guard_.verdictDetail().source, .secureInput)
    }
}
