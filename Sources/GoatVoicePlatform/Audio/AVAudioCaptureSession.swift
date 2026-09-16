import AVFAudio
import Foundation

public final class AVAudioCaptureSession: AudioCapturing, @unchecked Sendable {
    private struct State {
        var generation: UInt64 = 0
        var capturing = false
        var stopping = false
        var deliveriesClosed = true
        var engineStarted = false
        var device: AudioInputDevice?
        var tapFormat: AVAudioFormat?
        var capturedBytes = 0
        var pendingBytes = 0
        var onChunk: (@Sendable (CapturedAudioChunk) -> Void)?
        var onLevel: (@Sendable (AudioLevelUpdate) -> Void)?
        var onEvent: (@Sendable (AudioCaptureEvent) -> Void)?
    }

    private final class DrainFence: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Bool, Never>?

        init(_ continuation: CheckedContinuation<Bool, Never>) {
            self.continuation = continuation
        }

        func resume(_ drained: Bool) {
            lock.lock()
            let continuation = continuation
            self.continuation = nil
            lock.unlock()
            continuation?.resume(returning: drained)
        }
    }

    private let engine: any AudioEngineBackend
    private let hardware: any AudioHardwareBackend
    private let converter: CanonicalAudioConverter
    private let callbackQueue: DispatchQueue
    private let controlQueue: DispatchQueue
    private let tapBufferSize: AVAudioFrameCount
    private let pendingByteLimit: Int
    private let capturedByteLimit: Int
    private let lock = NSLock()
    private var state = State()
    private var deviceObservation: AudioObservationToken?
    private var engineObservation: AudioObservationToken?

    public init(engine: any AudioEngineBackend = AVAudioEngineBackend(),
                hardware: any AudioHardwareBackend = CoreAudioHardware(),
                limits: AudioCaptureLimits = AudioCaptureLimits(),
                converter: CanonicalAudioConverter? = nil,
                callbackQueue: DispatchQueue = DispatchQueue(label: "goat.voice.audio-callbacks"),
                controlQueue: DispatchQueue = DispatchQueue(label: "goat.voice.audio-control"),
                tapBufferSize: AVAudioFrameCount = 4_800,
                pendingByteLimit: Int = 8_388_608,
                durationLimit: TimeInterval = 1_200) {
        self.engine = engine
        self.hardware = hardware
        self.converter = converter ?? CanonicalAudioConverter(
            sampleRate: limits.canonicalSampleRate,
            channels: limits.canonicalChannels)
        self.callbackQueue = callbackQueue
        self.controlQueue = controlQueue
        self.tapBufferSize = tapBufferSize
        self.pendingByteLimit = pendingByteLimit
        let canonicalCap = Int(
            limits.canonicalSampleRate * Double(limits.canonicalChannels)
                * durationLimit * Double(MemoryLayout<Int16>.size))
        capturedByteLimit = min(limits.maximumCapturedBytes, canonicalCap)
    }

    public var onChunk: (@Sendable (CapturedAudioChunk) -> Void)? {
        get { lock.withLock { state.onChunk } }
        set { lock.withLock { state.onChunk = newValue } }
    }

    public var onLevel: (@Sendable (AudioLevelUpdate) -> Void)? {
        get { lock.withLock { state.onLevel } }
        set { lock.withLock { state.onLevel = newValue } }
    }

    public var onEvent: (@Sendable (AudioCaptureEvent) -> Void)? {
        get { lock.withLock { state.onEvent } }
        set { lock.withLock { state.onEvent = newValue } }
    }

    public var isCapturing: Bool {
        lock.withLock { state.capturing }
    }

    public func start(device: AudioInputDevice) throws {
        try lock.withLock {
            guard !state.capturing else { throw AudioCaptureError.alreadyCapturing }
            state.generation += 1
            state.capturing = true
            state.stopping = false
            state.deliveriesClosed = false
            state.device = device
            state.capturedBytes = 0
            state.pendingBytes = 0
        }
        do {
            try controlQueue.sync {
                teardownEngine()
                let generation = lock.withLock { state.generation }
                try staged(.inputDeviceBinding) { try engine.setInputDevice(device.objectID) }
                let format = try staged(.inputFormatQuery) { () throws -> AVAudioFormat in
                    let format = try engine.inputHardwareFormat()
                    guard format.sampleRate > 0, format.channelCount > 0 else {
                        throw AudioHardwareFailure(code: 0)
                    }
                    return format
                }
                lock.withLock { state.tapFormat = format }
                try staged(.inputTapInstall) {
                    try engine.installInputTap(bufferSize: tapBufferSize, format: format) {
                        [weak self] buffer in
                        self?.processInput(buffer, generation: generation)
                    }
                }
                let engineObservation = engine.observeConfigurationChanges { [weak self] in
                    self?.handleEngineChange(generation: generation)
                }
                let deviceObservation = hardware.observeInputDeviceChanges { [weak self] in
                    self?.handleDeviceListChange(generation: generation)
                }
                lock.withLock {
                    self.engineObservation = engineObservation
                    self.deviceObservation = deviceObservation
                }
                try staged(.engineStart) { try engine.start() }
                lock.withLock { state.engineStarted = true }
            }
        } catch {
            abandonStart()
            throw error
        }
    }

    public func stop() {
        guard let generation = initiateStop() else { return }
        controlQueue.sync {
            teardownEngine(generation: generation)
        }
        callbackQueue.async { [weak self] in
            self?.closeDeliveries(generation: generation)
        }
    }

    public func stopAndDrain(until deadline: ContinuousClock.Instant) async -> Bool {
        guard let generation = initiateStop() else {
            return lock.withLock { state.deliveriesClosed }
        }
        controlQueue.sync {
            teardownEngine(generation: generation)
        }
        return await withCheckedContinuation { continuation in
            let fence = DrainFence(continuation)
            callbackQueue.async { [weak self] in
                self?.closeDeliveries(generation: generation)
                fence.resume(true)
            }
            let remaining = deadline - .now
            let nanoseconds = remaining.components.seconds * 1_000_000_000
                + remaining.components.attoseconds / 1_000_000_000
            DispatchQueue.global().asyncAfter(
                deadline: .now() + .nanoseconds(Int(max(0, nanoseconds)))) {
                fence.resume(false)
            }
        }
    }

    deinit {
        teardownEngine()
    }

    private func initiateStop() -> UInt64? {
        lock.withLock {
            guard state.capturing || state.stopping else { return nil }
            state.capturing = false
            state.stopping = true
            state.device = nil
            return state.generation
        }
    }

    private func abandonStart() {
        teardownEngine()
        lock.withLock {
            state.capturing = false
            state.stopping = false
            state.deliveriesClosed = true
            state.device = nil
            state.capturedBytes = 0
            state.pendingBytes = 0
            state.generation += 1
        }
    }

    private func teardownEngine() {
        engine.removeInputTap()
        engine.stop()
        let tokens = lock.withLock { () -> [AudioObservationToken] in
            var tokens: [AudioObservationToken] = []
            if let engineObservation { tokens.append(engineObservation) }
            if let deviceObservation { tokens.append(deviceObservation) }
            engineObservation = nil
            deviceObservation = nil
            state.engineStarted = false
            state.tapFormat = nil
            return tokens
        }
        for token in tokens { token.cancel() }
    }

    private func teardownEngine(generation: UInt64) {
        let current = lock.withLock { state.generation == generation }
        guard current else { return }
        teardownEngine()
    }

    private func processInput(_ buffer: AVAudioPCMBuffer, generation: UInt64) {
        let acceptsBuffer = lock.withLock {
            state.capturing && !state.stopping && state.generation == generation
        }
        guard acceptsBuffer else { return }
        for chunk in converter.convert(buffer) where chunk.frameCount > 0 {
            emit(chunk, generation: generation)
        }
    }

    private func emit(_ chunk: CapturedAudioChunk, generation: UInt64) {
        var delivery: CapturedAudioChunk?
        var reachedLimit = false
        lock.withLock {
            guard state.capturing, !state.stopping, state.generation == generation else { return }
            let headroom = capturedByteLimit - state.capturedBytes
            let frames = min(chunk.frameCount, headroom / MemoryLayout<Int16>.size)
            guard headroom > 0, frames > 0 else {
                state.stopping = true
                reachedLimit = true
                return
            }
            let byteCount = frames * MemoryLayout<Int16>.size
            guard state.pendingBytes + byteCount <= pendingByteLimit else {
                state.stopping = true
                reachedLimit = true
                return
            }
            var pcm = chunk.pcm16
            if byteCount < pcm.count { pcm = pcm.prefix(byteCount) }
            state.capturedBytes += byteCount
            state.pendingBytes += byteCount
            if state.capturedBytes >= capturedByteLimit {
                state.stopping = true
                reachedLimit = true
            }
            delivery = CapturedAudioChunk(pcm16: pcm, frameCount: frames)
        }
        guard let delivery else {
            if reachedLimit { requestTermination(.captureLimitReached, generation: generation) }
            return
        }
        let level = levelUpdate(for: delivery)
        callbackQueue.async { [weak self] in
            self?.deliver(delivery, level: level, generation: generation)
        }
        if reachedLimit {
            requestTermination(.captureLimitReached, generation: generation)
        }
    }

    private func deliver(_ chunk: CapturedAudioChunk,
                         level: AudioLevelUpdate,
                         generation: UInt64) {
        let callbacks = lock.withLock { () -> (onLevel: (@Sendable (AudioLevelUpdate) -> Void)?,
                                               onChunk: (@Sendable (CapturedAudioChunk) -> Void)?)? in
            state.pendingBytes = max(0, state.pendingBytes - chunk.pcm16.count)
            guard !state.deliveriesClosed, state.generation == generation else { return nil }
            return (state.onLevel, state.onChunk)
        }
        guard let callbacks else { return }
        callbacks.onLevel?(level)
        callbacks.onChunk?(chunk)
    }

    private func requestTermination(_ event: AudioCaptureEvent, generation: UInt64) {
        let shouldTerminate = lock.withLock { () -> Bool in
            guard state.capturing, state.generation == generation else { return false }
            state.capturing = false
            state.stopping = true
            return true
        }
        guard shouldTerminate else { return }
        controlQueue.async { [weak self] in
            guard let self else { return }
            self.teardownEngine(generation: generation)
            self.callbackQueue.async { [weak self] in
                self?.finalizeTermination(event: event, generation: generation)
            }
        }
    }

    private func finalizeTermination(event: AudioCaptureEvent, generation: UInt64) {
        let handler = lock.withLock { () -> (@Sendable (AudioCaptureEvent) -> Void)? in
            guard !state.deliveriesClosed, state.generation == generation else { return nil }
            state.deliveriesClosed = true
            state.device = nil
            return state.onEvent
        }
        handler?(event)
    }

    private func closeDeliveries(generation: UInt64) {
        lock.withLock {
            guard state.generation == generation else { return }
            state.deliveriesClosed = true
            state.pendingBytes = 0
        }
    }

    private func handleDeviceListChange(generation: UInt64) {
        guard let objectID = activeObjectID(generation: generation) else { return }
        if !hardware.isInputDevicePresent(objectID) {
            requestTermination(.inputDeviceLost, generation: generation)
        }
    }

    private func handleEngineChange(generation: UInt64) {
        guard let objectID = activeObjectID(generation: generation) else { return }
        guard hardware.isInputDevicePresent(objectID) else {
            requestTermination(.inputDeviceLost, generation: generation)
            return
        }
        guard lock.withLock({ state.engineStarted }) else { return }
        guard engine.isRunning, inputFormatMatchesTap() else {
            requestTermination(.engineInterrupted, generation: generation)
            return
        }
    }

    private func inputFormatMatchesTap() -> Bool {
        guard let expected = lock.withLock({ state.tapFormat }),
              let current = try? engine.inputHardwareFormat() else { return false }
        return current.sampleRate == expected.sampleRate
            && current.channelCount == expected.channelCount
            && current.commonFormat == expected.commonFormat
            && current.isInterleaved == expected.isInterleaved
    }

    private func activeObjectID(generation: UInt64) -> UInt32? {
        lock.withLock {
            guard state.capturing, !state.stopping,
                  state.generation == generation,
                  let device = state.device else { return nil }
            return device.objectID
        }
    }

    private func staged<T>(_ stage: AudioCaptureStartupFailure.Stage,
                           _ body: () throws -> T) throws -> T {
        do { return try body() }
        catch { throw startupFailure(stage: stage, error: error) }
    }

    private func startupFailure(stage: AudioCaptureStartupFailure.Stage,
                                error: Error) -> AudioCaptureStartupFailure {
        switch error {
        case let failure as AudioCaptureStartupFailure:
            return failure
        case let failure as AudioHardwareFailure:
            return AudioCaptureStartupFailure(stage: stage, code: failure.code)
        case is AudioCaptureError:
            return AudioCaptureStartupFailure(stage: stage, code: 0)
        default:
            return AudioCaptureStartupFailure(
                stage: stage, code: Int32(clamping: (error as NSError).code))
        }
    }

    private func levelUpdate(for chunk: CapturedAudioChunk) -> AudioLevelUpdate {
        var peak: Double = 0
        var sumSquares: Double = 0
        var sampleCount = 0
        chunk.pcm16.withUnsafeBytes { raw in
            let samples = raw.bindMemory(to: Int16.self)
            sampleCount = samples.count
            for sample in samples {
                let magnitude = Double(abs(Int32(sample))) * (1.0 / 32_768)
                peak = max(peak, magnitude)
                sumSquares += magnitude * magnitude
            }
        }
        let rms = sampleCount > 0 ? (sumSquares / Double(sampleCount)).squareRoot() : 0
        return AudioLevelUpdate(rms: rms, peak: peak)
    }
}
