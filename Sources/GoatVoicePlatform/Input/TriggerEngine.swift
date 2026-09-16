import Foundation

public final class TriggerEngine {
    private enum State { case armed, active, disarmed }

    public var spec: TriggerSpec
    public var escapeInterruptsSession: @Sendable () -> Bool
    public var keyStateProbe: (@Sendable (UInt16) -> Bool)?

    private var state: State = .armed
    private var downKeyCodes = Set<UInt16>()
    private var deliveredKeyCodes = Set<UInt16>()
    private var probeConfirmedKeyCodes = Set<UInt16>()

    public init(spec: TriggerSpec) {
        self.spec = spec
        self.escapeInterruptsSession = { false }
    }

    public var isActive: Bool { state == .active }
    public var isArmed: Bool { state == .armed }
    public var triggerIsFullyReleased: Bool {
        spec.triggerKeyCodes.allSatisfy { keyCode in
            if downKeyCodes.contains(keyCode) { return false }
            if let keyStateProbe { return !keyStateProbe(keyCode) }
            return true
        }
    }

    public func handle(_ event: InputEvent) -> (consume: Bool, effects: [TriggerEffect]) {
        let result = route(event)
        let reconciled = reconcilePhysicalState()
        return (result.consume, result.effects + reconciled)
    }

    public func disarmUntilTriggerFullyReleased() {
        state = triggerIsFullyReleased ? .armed : .disarmed
    }

    public func reset() {
        state = .armed
        downKeyCodes.removeAll()
        deliveredKeyCodes.removeAll()
        probeConfirmedKeyCodes.removeAll()
    }

    private func isTriggerKey(_ keyCode: UInt16) -> Bool {
        spec.triggerKeyCodes.contains(keyCode)
    }

    private var satisfied: Bool {
        switch spec {
        case .modifier(let modifier):
            return !downKeyCodes.isDisjoint(with: modifier.keyCodes)
        case .chord(let keyCode, let modifiers):
            guard downKeyCodes.contains(keyCode) else { return false }
            return modifiers.allSatisfy { !downKeyCodes.isDisjoint(with: $0.keyCodes) }
        }
    }

    private func route(_ event: InputEvent) -> (consume: Bool, effects: [TriggerEffect]) {
        switch event {
        case .keyDown(let keyCode, _, let isRepeat):
            return handleKeyDown(keyCode, isRepeat: isRepeat)
        case .keyUp(let keyCode, _):
            let wasDelivered = deliveredKeyCodes.contains(keyCode)
            downKeyCodes.remove(keyCode)
            deliveredKeyCodes.remove(keyCode)
            probeConfirmedKeyCodes.remove(keyCode)
            return handleRelease(removedKeyCode: keyCode, wasDelivered: wasDelivered)
        case .modifierDown(_, let keyCode):
            return handlePress(addedKeyCode: keyCode)
        case .modifierUp(_, let keyCode):
            let wasDelivered = deliveredKeyCodes.contains(keyCode)
            downKeyCodes.remove(keyCode)
            deliveredKeyCodes.remove(keyCode)
            probeConfirmedKeyCodes.remove(keyCode)
            return handleRelease(removedKeyCode: keyCode, wasDelivered: wasDelivered)
        case .tapDisabledByTimeout:
            return (false, [.tapDisabled])
        case .pointerDown, .pointerDrag, .scrollWheel:
            return (false, [])
        }
    }

    private func handleKeyDown(_ keyCode: UInt16, isRepeat: Bool) -> (Bool, [TriggerEffect]) {
        if keyCode == 0x35 {
            if state == .active || escapeInterruptsSession() {
                if state == .active { state = .disarmed }
                return (true, [.cancelledByEscape])
            }
            downKeyCodes.insert(keyCode)
            return (false, [])
        }
        let alreadyDown = downKeyCodes.contains(keyCode)
        switch state {
        case .active:
            downKeyCodes.insert(keyCode)
            if isTriggerKey(keyCode) { return (true, []) }
            if alreadyDown || isRepeat { return (false, []) }
            state = .disarmed
            return (false, [.cancelledByExtraKey])
        case .armed:
            downKeyCodes.insert(keyCode)
            if satisfied {
                state = .active
                return (true, [.began])
            }
            if isTriggerKey(keyCode) { deliveredKeyCodes.insert(keyCode) }
            return (false, [])
        case .disarmed:
            downKeyCodes.insert(keyCode)
            return (false, [])
        }
    }

    private func handlePress(addedKeyCode: UInt16) -> (Bool, [TriggerEffect]) {
        let alreadyDown = downKeyCodes.contains(addedKeyCode)
        downKeyCodes.insert(addedKeyCode)
        switch state {
        case .armed:
            if satisfied {
                state = .active
                return (true, [.began])
            }
            if isTriggerKey(addedKeyCode) { deliveredKeyCodes.insert(addedKeyCode) }
            return (false, [])
        case .active:
            if isTriggerKey(addedKeyCode) { return (true, []) }
            if alreadyDown { return (false, []) }
            state = .disarmed
            return (false, [.cancelledByExtraKey])
        case .disarmed:
            return (false, [])
        }
    }

    private func handleRelease(removedKeyCode: UInt16, wasDelivered: Bool) -> (Bool, [TriggerEffect]) {
        switch state {
        case .active:
            guard isTriggerKey(removedKeyCode) else { return (false, []) }
            state = triggerIsFullyReleased ? .armed : .disarmed
            return (!wasDelivered, [.ended])
        case .armed, .disarmed:
            if state == .disarmed && triggerIsFullyReleased {
                state = .armed
            }
            return (false, [])
        }
    }

    private func reconcilePhysicalState() -> [TriggerEffect] {
        guard let probe = keyStateProbe else { return [] }
        var lostKeyCodes: [UInt16] = []
        for keyCode in downKeyCodes {
            if probe(keyCode) {
                probeConfirmedKeyCodes.insert(keyCode)
            } else if probeConfirmedKeyCodes.contains(keyCode) {
                lostKeyCodes.append(keyCode)
            }
        }
        var triggerKeyLost = false
        for keyCode in lostKeyCodes {
            downKeyCodes.remove(keyCode)
            deliveredKeyCodes.remove(keyCode)
            probeConfirmedKeyCodes.remove(keyCode)
            if spec.triggerKeyCodes.contains(keyCode) { triggerKeyLost = true }
        }
        switch state {
        case .active where triggerKeyLost || !satisfied:
            state = triggerIsFullyReleased ? .armed : .disarmed
            return [.ended]
        case .disarmed where triggerIsFullyReleased:
            state = .armed
            return []
        default:
            return []
        }
    }
}
