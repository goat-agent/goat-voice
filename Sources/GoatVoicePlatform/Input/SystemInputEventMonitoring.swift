import ApplicationServices
import CoreGraphics
import Foundation

public enum EventTapError: Error {
    case creationFailed
    case accessibilityMissing
    case startTimedOut
}

public protocol SystemInputEventMonitoring: AnyObject {
    var handler: (@Sendable (InputEvent) -> Bool)? { get set }
    func start() throws
    func stop()
}

public final class InterruptibilityLatch: @unchecked Sendable {
    private let lock = NSLock()
    private var interruptible: Bool

    public init(initiallyInterruptible: Bool = false) {
        interruptible = initiallyInterruptible
    }

    public var isInterruptible: Bool {
        lock.lock()
        defer { lock.unlock() }
        return interruptible
    }

    public func setInterruptible(_ value: Bool) {
        lock.lock()
        interruptible = value
        lock.unlock()
    }
}

public final class InputTriggerMonitor: @unchecked Sendable {
    public typealias SyncObservation = (event: InputEvent, consumed: Bool, effects: [TriggerEffect])

    private let monitor: SystemInputEventMonitoring
    private let engine: TriggerEngine
    private let engineLock = NSLock()
    private let stateLock = NSLock()
    private let callbackQueue: DispatchQueue
    private let maxPendingObservations = 64

    private var generation: UInt64 = 0
    private var pendingObservations = 0
    private var droppedCount = 0
    private var syncObservers: [UUID: @Sendable (SyncObservation) -> Void] = [:]
    private var customEscapeClosure = false
    private var interruptibilityLatch: InterruptibilityLatch?

    public var onEffect: (@Sendable (TriggerEffect) -> Void)?
    public var onEvent: (@Sendable (InputEvent) -> Void)?

    public convenience init(monitor: SystemInputEventMonitoring, engine: TriggerEngine,
                            interruptibilityLatch: InterruptibilityLatch? = nil) {
        self.init(
            monitor: monitor,
            engine: engine,
            interruptibilityLatch: interruptibilityLatch,
            callbackQueue: DispatchQueue(label: "goat.voice.platform.input.callback")
        )
    }

    init(monitor: SystemInputEventMonitoring, engine: TriggerEngine,
         interruptibilityLatch: InterruptibilityLatch?, callbackQueue: DispatchQueue) {
        self.monitor = monitor
        self.engine = engine
        self.interruptibilityLatch = interruptibilityLatch
        self.callbackQueue = callbackQueue
    }

    public var droppedObservationCount: Int {
        stateLock.lock()
        defer { stateLock.unlock() }
        return droppedCount
    }

    public func start() throws {
        bumpGeneration()
        stateLock.lock()
        let hasCustomEscape = customEscapeClosure
        let latch = interruptibilityLatch
        stateLock.unlock()
        engineLock.lock()
        if engine.keyStateProbe == nil {
            engine.keyStateProbe = { HardwareKeyState.isDown($0) }
        }
        if !hasCustomEscape, let latch {
            engine.escapeInterruptsSession = { latch.isInterruptible }
        }
        engineLock.unlock()
        monitor.handler = { [weak self] event in
            guard let self else { return false }
            return self.routeThroughEngine(event)
        }
        try monitor.start()
    }

    public func stop() {
        monitor.stop()
        monitor.handler = nil
        bumpGeneration()
    }

    public func disarmUntilTriggerFullyReleased() {
        engineLock.lock()
        engine.disarmUntilTriggerFullyReleased()
        engineLock.unlock()
    }

    public func setSpec(_ spec: TriggerSpec) {
        engineLock.lock()
        engine.spec = spec
        engine.disarmUntilTriggerFullyReleased()
        engineLock.unlock()
    }

    public func setEscapeInterruption(_ closure: @escaping @Sendable () -> Bool) {
        engineLock.lock()
        engine.escapeInterruptsSession = closure
        engineLock.unlock()
        stateLock.lock()
        customEscapeClosure = true
        stateLock.unlock()
    }

    public func setInterruptibilityLatch(_ latch: InterruptibilityLatch?) {
        stateLock.lock()
        interruptibilityLatch = latch
        let hasCustomEscape = customEscapeClosure
        stateLock.unlock()
        guard !hasCustomEscape else { return }
        engineLock.lock()
        if let latch {
            engine.escapeInterruptsSession = { latch.isInterruptible }
        } else {
            engine.escapeInterruptsSession = { false }
        }
        engineLock.unlock()
    }

    public func setKeyStateProbe(_ probe: (@Sendable (UInt16) -> Bool)?) {
        engineLock.lock()
        engine.keyStateProbe = probe
        engineLock.unlock()
    }

    public func isSessionActive() -> Bool {
        engineLock.lock()
        defer { engineLock.unlock() }
        return engine.isActive
    }

    public func isArmed() -> Bool {
        engineLock.lock()
        defer { engineLock.unlock() }
        return engine.isArmed
    }

    public func triggerIsFullyReleased() -> Bool {
        engineLock.lock()
        defer { engineLock.unlock() }
        return engine.triggerIsFullyReleased
    }

    @discardableResult
    public func addSynchronousObserver(
        _ observer: @escaping @Sendable (SyncObservation) -> Void
    ) -> UUID {
        let id = UUID()
        stateLock.lock()
        syncObservers[id] = observer
        stateLock.unlock()
        return id
    }

    public func removeSynchronousObserver(_ id: UUID) {
        stateLock.lock()
        syncObservers.removeValue(forKey: id)
        stateLock.unlock()
    }

    private func routeThroughEngine(_ event: InputEvent) -> Bool {
        engineLock.lock()
        let decision = engine.handle(event)
        engineLock.unlock()
        let observation = SyncObservation(event, decision.consume, decision.effects)
        stateLock.lock()
        let observers = Array(syncObservers.values)
        let generationAtEvent = generation
        stateLock.unlock()
        for observer in observers { observer(observation) }
        dispatchAsync(generation: generationAtEvent, observation: observation)
        return decision.consume
    }

    private func dispatchAsync(generation generationAtEvent: UInt64, observation: SyncObservation) {
        if !observation.effects.isEmpty {
            let effects = observation.effects
            callbackQueue.async { [weak self] in
                guard let self, self.currentGeneration() == generationAtEvent else { return }
                for effect in effects { self.onEffect?(effect) }
            }
        }
        guard !observation.consumed else { return }
        stateLock.lock()
        if pendingObservations >= maxPendingObservations {
            droppedCount += 1
            stateLock.unlock()
            return
        }
        pendingObservations += 1
        stateLock.unlock()
        callbackQueue.async { [weak self] in
            guard let self else { return }
            defer {
                self.stateLock.lock()
                self.pendingObservations -= 1
                self.stateLock.unlock()
            }
            guard self.currentGeneration() == generationAtEvent else { return }
            self.onEvent?(observation.event)
        }
    }

    private func bumpGeneration() {
        stateLock.lock()
        generation &+= 1
        stateLock.unlock()
    }

    private func currentGeneration() -> UInt64 {
        stateLock.lock()
        defer { stateLock.unlock() }
        return generation
    }
}

public final class CGEventTapMonitor: SystemInputEventMonitoring {
    public var handler: (@Sendable (InputEvent) -> Bool)?

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var tapRunLoop: CFRunLoop?
    private var thread: Thread?
    private let startSemaphore = DispatchSemaphore(value: 0)
    private var startError: Error?

    public init() {}

    public func start() throws {
        guard AXIsProcessTrusted() else { throw EventTapError.accessibilityMissing }
        guard thread == nil else { return }
        startError = nil
        let tapThread = Thread { [weak self] in self?.runTapLoop() }
        thread = tapThread
        tapThread.start()
        if startSemaphore.wait(timeout: .now() + 5) == .timedOut {
            throw EventTapError.startTimedOut
        }
        if let startError { throw startError }
    }

    public func stop() {
        guard thread != nil, let tapRunLoop else { return }
        self.thread = nil
        CFRunLoopPerformBlock(tapRunLoop, CFRunLoopMode.commonModes.rawValue) { [weak self] in
            self?.teardownTap()
            CFRunLoopStop(tapRunLoop)
        }
        CFRunLoopWakeUp(tapRunLoop)
    }

    private func runTapLoop() {
        tapRunLoop = CFRunLoopGetCurrent()
        let mask = CGEventTapMonitor.interestedEventMask
        let userInfo = Unmanaged.passUnretained(self).toOpaque()
        guard let created = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: CGEventTapMonitor.tapCallback,
            userInfo: userInfo
        ) else {
            startError = EventTapError.creationFailed
            startSemaphore.signal()
            return
        }
        tap = created
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, created, 0)
        runLoopSource = source
        CFRunLoopAddSource(tapRunLoop, source, .commonModes)
        CGEvent.tapEnable(tap: created, enable: true)
        startSemaphore.signal()
        CFRunLoopRun()
    }

    private func teardownTap() {
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
            runLoopSource = nil
        }
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
            self.tap = nil
        }
    }

    private static let tapCallback: CGEventTapCallBack = { _, type, event, userInfo in
        guard let userInfo else { return Unmanaged.passUnretained(event) }
        let monitor = Unmanaged<CGEventTapMonitor>.fromOpaque(userInfo).takeUnretainedValue()
        return monitor.process(type: type, event: event)
    }

    private func process(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            _ = handler?(.tapDisabledByTimeout)
            return Unmanaged.passUnretained(event)
        }
        guard let inputEvent = Self.translate(type: type, event: event) else {
            return Unmanaged.passUnretained(event)
        }
        let consume = handler?(inputEvent) ?? false
        return consume ? nil : Unmanaged.passUnretained(event)
    }

    static func translate(type: CGEventType, event: CGEvent) -> InputEvent? {
        let keyCode = UInt16(clamping: event.getIntegerValueField(.keyboardEventKeycode))
        let modifiers = genericModifiers(from: event.flags)
        switch type {
        case .keyDown:
            let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
            return .keyDown(keyCode: keyCode, modifiers: modifiers, isRepeat: isRepeat)
        case .keyUp:
            return .keyUp(keyCode: keyCode, modifiers: modifiers)
        case .flagsChanged:
            guard let transition = ModifierTransition(keyCode: keyCode, rawFlags: event.flags.rawValue) else {
                return nil
            }
            return transition.isDown
                ? .modifierDown(transition.modifier, keyCode: keyCode)
                : .modifierUp(transition.modifier, keyCode: keyCode)
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            return .pointerDown
        case .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            return .pointerDrag
        case .scrollWheel:
            return .scrollWheel
        default:
            return nil
        }
    }

    static func genericModifiers(from flags: CGEventFlags) -> Set<KeyboardModifier> {
        var result = Set<KeyboardModifier>()
        if flags.contains(.maskControl) { result.insert(.control) }
        if flags.contains(.maskAlternate) { result.insert(.option) }
        if flags.contains(.maskShift) { result.insert(.shift) }
        if flags.contains(.maskCommand) { result.insert(.command) }
        if flags.contains(.maskSecondaryFn) { result.insert(.function) }
        return result
    }

    private static let interestedEventMask: CGEventMask = {
        let types: [CGEventType] = [
            .keyDown, .keyUp, .flagsChanged,
            .leftMouseDown, .leftMouseUp, .leftMouseDragged,
            .rightMouseDown, .rightMouseUp, .rightMouseDragged,
            .otherMouseDown, .otherMouseUp, .otherMouseDragged,
            .scrollWheel,
        ]
        return types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
    }()
}

public enum HardwareKeyState {
    public static func isDown(_ keyCode: UInt16) -> Bool {
        CGEventSource.keyState(.hidSystemState, key: CGKeyCode(keyCode))
    }
}
