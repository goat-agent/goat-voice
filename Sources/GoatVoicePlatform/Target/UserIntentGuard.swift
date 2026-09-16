import ApplicationServices
import Carbon
import Foundation

public enum MutationGuardVerdict: Sendable, Equatable {
    case clean
    case mutated
    case untrusted
}

public enum MutationSource: String, Sendable, Equatable {
    case secureInput
    case observationUnavailable
    case accessibilitySignal
    case accessibilityMutation
    case keyboard
    case pointer
}

public enum SecureEventInput {
    public static var isEnabled: Bool { IsSecureEventInputEnabled() }
}

public final class UserIntentGuard: @unchecked Sendable {
    private let backend: AccessibilityBackend
    private let secureInputProbe: @Sendable () -> Bool
    private let lock = NSLock()

    private var observation: AXObservation?
    private var observedToken: AXElementToken?
    private var baselineFingerprint: AXMutationFingerprint?
    private var verdictValue: MutationGuardVerdict = .untrusted
    private var source: MutationSource?
    private var armed = false
    private var generation: UInt64 = 0

    public init(backend: AccessibilityBackend,
                secureInputProbe: @escaping @Sendable () -> Bool = { SecureEventInput.isEnabled }) {
        self.backend = backend
        self.secureInputProbe = secureInputProbe
    }

    public func begin(target: TargetDescriptor) {
        let setup = lock.withLock { () -> (UInt64, AXObservation?) in
            generation &+= 1
            let previous = observation
            observation = nil
            observedToken = target.elementToken
            baselineFingerprint = nil
            armed = true
            verdictValue = secureInputProbe() ? .untrusted : .clean
            source = verdictValue == .untrusted ? .secureInput : nil
            return (generation, previous)
        }
        setup.1?.invalidate()
        let fingerprint = backend.mutationFingerprint(of: target.elementToken)
        lock.withLock {
            if generation == setup.0, armed { baselineFingerprint = fingerprint }
        }
        do {
            let installed = try backend.observeMutations(of: target.elementToken) { [weak self] event in
                self?.noteAccessibilitySignal(event, generation: setup.0)
            }
            let retained = lock.withLock { () -> Bool in
                guard generation == setup.0, armed else { return false }
                observation = installed
                return true
            }
            if !retained { installed.invalidate() }
        } catch {
            lock.withLock {
                guard generation == setup.0, armed else { return }
                verdictValue = .untrusted
                source = .observationUnavailable
            }
        }
    }

    public func observe(_ event: InputEvent) {
        lock.lock()
        defer { lock.unlock() }
        guard armed, verdictValue == .clean else { return }
        if secureInputProbe() {
            verdictValue = .untrusted
            source = .secureInput
            return
        }
        if UserIntentGuard.isMutationEvent(event) {
            verdictValue = .mutated
            source = UserIntentGuard.isPointerEvent(event) ? .pointer : .keyboard
        }
    }

    public func verdict() -> MutationGuardVerdict {
        verdictDetail().verdict
    }

    public func verdictDetail() -> (verdict: MutationGuardVerdict, source: MutationSource?) {
        lock.lock()
        defer { lock.unlock() }
        guard armed else { return (.untrusted, nil) }
        if verdictValue == .clean, secureInputProbe() {
            verdictValue = .untrusted
            source = .secureInput
        }
        return (verdictValue, source)
    }

    public func end() {
        let previous = lock.withLock { () -> AXObservation? in
            generation &+= 1
            let previous = observation
            observation = nil
            observedToken = nil
            baselineFingerprint = nil
            armed = false
            verdictValue = .untrusted
            source = nil
            return previous
        }
        previous?.invalidate()
    }

    private func noteAccessibilitySignal(_ event: AXMutationEvent, generation signalGeneration: UInt64) {
        lock.lock()
        guard armed, signalGeneration == generation,
              verdictValue == .clean, let token = observedToken
        else {
            lock.unlock()
            return
        }
        if secureInputProbe() {
            verdictValue = .untrusted
            source = .secureInput
            lock.unlock()
            return
        }
        let baseline = baselineFingerprint
        lock.unlock()
        let current = backend.mutationFingerprint(of: token)
        lock.lock()
        defer { lock.unlock() }
        guard armed, signalGeneration == generation, verdictValue == .clean else { return }
        switch (baseline, current) {
        case (.some(let before), .some(let after)) where event == .selectionChanged && before == after:
            return
        case (.none, _):
            verdictValue = .mutated
            source = .accessibilitySignal
        default:
            verdictValue = .mutated
            source = .accessibilityMutation
        }
    }

    private static func isPointerEvent(_ event: InputEvent) -> Bool {
        switch event {
        case .pointerDown, .pointerDrag: return true
        default: return false
        }
    }

    private static func isMutationEvent(_ event: InputEvent) -> Bool {
        switch event {
        case .keyDown(let keyCode, let modifiers, _):
            if keyCode == 0x35 { return false }
            if keyCode == 0x08 && modifiers == [.command] { return false }
            return true
        case .pointerDown, .pointerDrag:
            return true
        case .keyUp, .modifierDown, .modifierUp, .scrollWheel, .tapDisabledByTimeout:
            return false
        }
    }
}
