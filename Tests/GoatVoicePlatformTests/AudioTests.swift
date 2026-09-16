import AVFAudio
import Foundation
import os
import XCTest
@testable import GoatVoicePlatform

final class AudioTests: XCTestCase {
    private final class FakeHardware: AudioHardwareBackend, @unchecked Sendable {
        private let lock = NSLock()
        private var devices: [AudioInputDevice]
        private var defaultDevice: AudioInputDevice??
        private var presentIDs: Set<UInt32>
        private var listHandler: (@Sendable () -> Void)?
        var listError: Error?
        var defaultError: Error?

        init(devices: [AudioInputDevice], defaultDevice: AudioInputDevice?) {
            self.devices = devices
            self.defaultDevice = defaultDevice
            presentIDs = Set(devices.map(\.objectID))
        }

        func inputDevices() throws -> [AudioInputDevice] {
            if let error = listError { throw error }
            return lock.withLock { devices }
        }

        func defaultInputDevice() throws -> AudioInputDevice? {
            if let error = defaultError { throw error }
            return lock.withLock { defaultDevice ?? nil }
        }

        func isInputDevicePresent(_ objectID: UInt32) -> Bool {
            lock.withLock { presentIDs.contains(objectID) }
        }

        func observeInputDeviceChanges(
            _ handler: @escaping @Sendable () -> Void) -> AudioObservationToken {
            lock.withLock { listHandler = handler }
            return AudioObservationToken(cancel: {})
        }

        func removeDevice(_ objectID: UInt32) {
            lock.withLock {
                devices.removeAll { $0.objectID == objectID }
                presentIDs.remove(objectID)
            }
        }

        func simulateDeviceListChange() {
            let handler = lock.withLock { listHandler }
            handler?()
        }
    }

    private final class FakeEngine: AudioEngineBackend, @unchecked Sendable {
        private let lock = NSLock()
        private var tapHandler: (@Sendable (AVAudioPCMBuffer) -> Void)?
        private var configHandler: (@Sendable () -> Void)?
        private(set) var running = false
        private(set) var pinnedDeviceID: UInt32?
        private(set) var pinCalls = 0
        private(set) var tapFormat: AVAudioFormat?
        var inputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false)!
        var startError: Error?

        var isRunning: Bool { lock.withLock { running } }

        func setInputDevice(_ objectID: UInt32) throws {
            lock.withLock {
                pinnedDeviceID = objectID
                pinCalls += 1
            }
        }

        func inputHardwareFormat() throws -> AVAudioFormat {
            lock.withLock { inputFormat }
        }

        func installInputTap(bufferSize: AVAudioFrameCount,
                             format: AVAudioFormat,
                             handler: @escaping @Sendable (AVAudioPCMBuffer) -> Void) throws {
            lock.withLock {
                tapFormat = format
                tapHandler = handler
            }
        }

        func removeInputTap() {
            lock.withLock { tapHandler = nil }
        }

        func start() throws {
            if let startError { throw startError }
            lock.withLock { running = true }
        }

        func stop() {
            lock.withLock { running = false }
        }

        func observeConfigurationChanges(
            _ handler: @escaping @Sendable () -> Void) -> AudioObservationToken {
            lock.withLock { configHandler = handler }
            return AudioObservationToken(cancel: {})
        }

        func feed(_ buffer: AVAudioPCMBuffer) {
            let handler = lock.withLock { tapHandler }
            handler?(buffer)
        }

        func simulateConfigurationChange() {
            let handler = lock.withLock { configHandler }
            handler?()
        }
    }

    private static let builtIn = AudioInputDevice(objectID: 11, uid: "builtin-mic", name: "MacBook Mic")
    private static let usb = AudioInputDevice(objectID: 22, uid: "usb-mic", name: "USB Mic")

    private func makeFloatBuffer(sampleRate: Double,
                                 channels: Int,
                                 frames: Int,
                                 fill: (Int, Int) -> Float) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                   sampleRate: sampleRate,
                                   channels: AVAudioChannelCount(channels),
                                   interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
        buffer.frameLength = AVAudioFrameCount(frames)
        for channel in 0 ..< channels {
            let data = buffer.floatChannelData![channel]
            for frame in 0 ..< frames {
                data[frame] = fill(channel, frame)
            }
        }
        return buffer
    }

    private func samples16(_ data: Data) -> [Int16] {
        data.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
    }

    private func makeSession(engine: FakeEngine,
                             hardware: FakeHardware,
                             limits: AudioCaptureLimits = AudioCaptureLimits(),
                             pendingByteLimit: Int = 8_388_608,
                             durationLimit: TimeInterval = 1_200,
                             controlQueue: DispatchQueue = DispatchQueue(label: "test.audio-control"))
        -> AVAudioCaptureSession {
        AVAudioCaptureSession(
            engine: engine,
            hardware: hardware,
            limits: limits,
            callbackQueue: DispatchQueue(label: "test.audio-callbacks"),
            controlQueue: controlQueue,
            tapBufferSize: 4_800,
            pendingByteLimit: pendingByteLimit,
            durationLimit: durationLimit)
    }

    func testConverterResamplesToCanonicalRate() {
        let converter = CanonicalAudioConverter()
        let buffer = makeFloatBuffer(sampleRate: 48_000, channels: 1, frames: 4_800) { _, _ in 0.5 }
        let chunks = converter.convert(buffer)
        let frames = chunks.reduce(0) { $0 + $1.frameCount }
        XCTAssertEqual(frames, 1_600, accuracy: 8)
        for chunk in chunks {
            XCTAssertEqual(chunk.pcm16.count, chunk.frameCount * 2)
            XCTAssertLessThanOrEqual(chunk.frameCount, CanonicalAudioConverter.maximumFramesPerChunk)
            XCTAssertGreaterThan(chunk.frameCount, 0)
        }
    }

    func testConverterDownmixesToMono() {
        let converter = CanonicalAudioConverter()
        let buffer = makeFloatBuffer(sampleRate: 16_000, channels: 2, frames: 1_600) { channel, _ in
            channel == 0 ? 0.25 : 0.75
        }
        let chunks = converter.convert(buffer)
        let frames = chunks.reduce(0) { $0 + $1.frameCount }
        XCTAssertEqual(frames, 1_600, accuracy: 4)
        let samples = samples16(chunks[0].pcm16)
        XCTAssertFalse(samples.isEmpty)
        for sample in samples.prefix(64) {
            XCTAssertEqual(Double(sample), 16_384, accuracy: 800)
        }
    }

    func testConverterSplitsLargeBuffersIntoBoundedChunks() {
        let converter = CanonicalAudioConverter()
        let buffer = makeFloatBuffer(sampleRate: 16_000, channels: 1,
                                     frames: CanonicalAudioConverter.maximumFramesPerChunk * 2 + 500) { _, _ in 0.1 }
        let chunks = converter.convert(buffer)
        XCTAssertEqual(chunks.count, 3)
        XCTAssertEqual(chunks[0].frameCount, CanonicalAudioConverter.maximumFramesPerChunk)
        XCTAssertEqual(chunks[1].frameCount, CanonicalAudioConverter.maximumFramesPerChunk)
        XCTAssertEqual(chunks[2].frameCount, 500)
    }

    func testResolverReturnsSystemDefault() throws {
        let hardware = FakeHardware(devices: [Self.builtIn, Self.usb], defaultDevice: Self.usb)
        let resolver = CoreAudioDeviceResolver(hardware: hardware)
        XCTAssertEqual(try resolver.resolve(.systemDefault), Self.usb)
        XCTAssertEqual(try resolver.inputDevices().count, 2)
    }

    func testResolverMatchesPinnedDeviceUID() throws {
        let hardware = FakeHardware(devices: [Self.builtIn, Self.usb], defaultDevice: Self.builtIn)
        let resolver = CoreAudioDeviceResolver(hardware: hardware)
        let resolved = try resolver.resolve(.pinned(deviceUID: "usb-mic", label: "USB Mic"))
        XCTAssertEqual(resolved, Self.usb)
    }

    func testResolverFailsWhenPinnedDeviceMissing() {
        let hardware = FakeHardware(devices: [Self.builtIn], defaultDevice: Self.builtIn)
        let resolver = CoreAudioDeviceResolver(hardware: hardware)
        XCTAssertThrowsError(try resolver.resolve(.pinned(deviceUID: "gone", label: "Gone"))) { error in
            XCTAssertEqual(error as? AudioDeviceError, .pinnedDeviceMissing(uid: "gone"))
        }
    }

    func testResolverFailsWhenNoDefaultDevice() {
        let hardware = FakeHardware(devices: [], defaultDevice: nil)
        let resolver = CoreAudioDeviceResolver(hardware: hardware)
        XCTAssertThrowsError(try resolver.resolve(.systemDefault)) { error in
            XCTAssertEqual(error as? AudioDeviceError, .noInputDevices)
        }
    }

    func testResolverMapsHardwareFailureToDeviceQueryFailed() {
        let hardware = FakeHardware(devices: [], defaultDevice: nil)
        hardware.listError = AudioHardwareFailure(code: 50_304)
        let resolver = CoreAudioDeviceResolver(hardware: hardware)
        XCTAssertThrowsError(try resolver.inputDevices()) { error in
            XCTAssertEqual(error as? AudioDeviceError, .deviceQueryFailed(code: 50_304))
        }
    }

    func testSessionPinsResolvedDeviceAndDeliversCanonicalChunks() throws {
        let hardware = FakeHardware(devices: [Self.builtIn, Self.usb], defaultDevice: Self.builtIn)
        let engine = FakeEngine()
        let session = makeSession(engine: engine, hardware: hardware)
        let chunkExpectation = expectation(description: "chunk")
        let levelExpectation = expectation(description: "level")
        let received = OSAllocatedUnfairLock(initialState: [CapturedAudioChunk]())
        let leveled = OSAllocatedUnfairLock(initialState: false)
        session.onLevel = { update in
            XCTAssertGreaterThan(update.peak, 0)
            XCTAssertLessThanOrEqual(update.peak, 1)
            let firstLevel = leveled.withLock { value in
                guard !value else { return false }
                value = true
                return true
            }
            if firstLevel { levelExpectation.fulfill() }
        }
        session.onChunk = { chunk in
            received.withLock { $0.append(chunk) }
            chunkExpectation.fulfill()
        }
        try session.start(device: Self.usb)
        XCTAssertTrue(session.isCapturing)
        XCTAssertEqual(engine.pinnedDeviceID, Self.usb.objectID)
        XCTAssertEqual(engine.pinCalls, 1)
        engine.feed(makeFloatBuffer(sampleRate: 48_000, channels: 2, frames: 4_800) { _, _ in 0.4 })
        wait(for: [chunkExpectation, levelExpectation], timeout: 5)
        session.stop()
        XCTAssertFalse(session.isCapturing)
        XCTAssertFalse(engine.isRunning)
        let chunks = received.withLock { $0 }
        let frames = chunks.reduce(0) { $0 + $1.frameCount }
        XCTAssertEqual(frames, 1_600, accuracy: 8)
        for chunk in chunks {
            XCTAssertEqual(chunk.pcm16.count, chunk.frameCount * 2)
        }
    }

    func testSessionDrainsQueuedChunksThenClosesDeliveries() throws {
        let hardware = FakeHardware(devices: [Self.builtIn], defaultDevice: Self.builtIn)
        let engine = FakeEngine()
        let session = makeSession(engine: engine, hardware: hardware)
        let firstChunk = expectation(description: "first chunk")
        let stall = DispatchSemaphore(value: 0)
        let delivered = OSAllocatedUnfairLock(initialState: 0)
        let released = OSAllocatedUnfairLock(initialState: false)
        session.onChunk = { _ in
            if delivered.withLock({ $0 += 1; return $0 }) == 1 { firstChunk.fulfill() }
            if !released.withLock({ $0 }) { stall.wait() }
        }
        try session.start(device: Self.builtIn)
        engine.feed(makeFloatBuffer(sampleRate: 16_000, channels: 1, frames: 1_600) { _, _ in 0.3 })
        wait(for: [firstChunk], timeout: 5)
        engine.feed(makeFloatBuffer(sampleRate: 16_000, channels: 1, frames: 1_600) { _, _ in 0.3 })
        engine.feed(makeFloatBuffer(sampleRate: 16_000, channels: 1, frames: 1_600) { _, _ in 0.3 })
        session.stop()
        engine.feed(makeFloatBuffer(sampleRate: 16_000, channels: 1, frames: 1_600) { _, _ in 0.3 })
        released.withLock { $0 = true }
        stall.signal()
        let drained = expectation(description: "drained")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { drained.fulfill() }
        wait(for: [drained], timeout: 5)
        XCTAssertEqual(delivered.withLock { $0 }, 3)
    }

    func testSessionEmitsCaptureLimitAtExactByteCap() throws {
        let hardware = FakeHardware(devices: [Self.builtIn], defaultDevice: Self.builtIn)
        let engine = FakeEngine()
        let durationLimit: TimeInterval = 0.5
        let expectedBytes = Int(16_000 * durationLimit) * 2
        let session = makeSession(
            engine: engine,
            hardware: hardware,
            durationLimit: durationLimit)
        let limitHit = expectation(description: "limit")
        let totalBytes = OSAllocatedUnfairLock(initialState: 0)
        session.onChunk = { chunk in totalBytes.withLock { $0 += chunk.pcm16.count } }
        session.onEvent = { event in
            if case .captureLimitReached = event { limitHit.fulfill() }
        }
        try session.start(device: Self.builtIn)
        for _ in 0 ..< 4 {
            engine.feed(makeFloatBuffer(sampleRate: 16_000, channels: 1, frames: 4_096) { _, _ in 0.2 })
        }
        wait(for: [limitHit], timeout: 5)
        let settled = expectation(description: "settled")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { settled.fulfill() }
        wait(for: [settled], timeout: 5)
        XCTAssertEqual(totalBytes.withLock { $0 }, expectedBytes)
        XCTAssertFalse(session.isCapturing)
    }

    func testSessionEmitsInputDeviceLostOnDisconnect() throws {
        let hardware = FakeHardware(devices: [Self.builtIn, Self.usb], defaultDevice: Self.usb)
        let engine = FakeEngine()
        let session = makeSession(engine: engine, hardware: hardware)
        let lost = expectation(description: "lost")
        session.onEvent = { event in
            if case .inputDeviceLost = event { lost.fulfill() }
        }
        try session.start(device: Self.usb)
        hardware.removeDevice(Self.usb.objectID)
        hardware.simulateDeviceListChange()
        wait(for: [lost], timeout: 5)
        XCTAssertFalse(session.isCapturing)
        XCTAssertFalse(engine.isRunning)
    }

    func testSessionEmitsEngineInterruptedWhenDeviceSurvives() throws {
        let hardware = FakeHardware(devices: [Self.builtIn], defaultDevice: Self.builtIn)
        let engine = FakeEngine()
        let session = makeSession(engine: engine, hardware: hardware)
        let interrupted = expectation(description: "interrupted")
        session.onEvent = { event in
            if case .engineInterrupted = event { interrupted.fulfill() }
        }
        try session.start(device: Self.builtIn)
        engine.stop()
        engine.simulateConfigurationChange()
        wait(for: [interrupted], timeout: 5)
        XCTAssertFalse(session.isCapturing)
    }

    func testSessionEmitsInputDeviceLostWhenEngineChangeHidesDeadDevice() throws {
        let hardware = FakeHardware(devices: [Self.builtIn], defaultDevice: Self.builtIn)
        let engine = FakeEngine()
        let session = makeSession(engine: engine, hardware: hardware)
        let lost = expectation(description: "lost")
        session.onEvent = { event in
            if case .inputDeviceLost = event { lost.fulfill() }
        }
        try session.start(device: Self.builtIn)
        hardware.removeDevice(Self.builtIn.objectID)
        engine.simulateConfigurationChange()
        wait(for: [lost], timeout: 5)
    }

    func testSessionDoesNotReResolveDeviceMidSession() throws {
        let hardware = FakeHardware(devices: [Self.builtIn, Self.usb], defaultDevice: Self.builtIn)
        let engine = FakeEngine()
        let session = makeSession(engine: engine, hardware: hardware)
        try session.start(device: Self.builtIn)
        hardware.removeDevice(Self.usb.objectID)
        hardware.simulateDeviceListChange()
        engine.feed(makeFloatBuffer(sampleRate: 16_000, channels: 1, frames: 160) { _, _ in 0.1 })
        XCTAssertTrue(session.isCapturing)
        XCTAssertEqual(engine.pinnedDeviceID, Self.builtIn.objectID)
        XCTAssertEqual(engine.pinCalls, 1)
        session.stop()
    }

    func testSessionRejectsSecondStartWhileCapturing() throws {
        let hardware = FakeHardware(devices: [Self.builtIn], defaultDevice: Self.builtIn)
        let engine = FakeEngine()
        let session = makeSession(engine: engine, hardware: hardware)
        try session.start(device: Self.builtIn)
        XCTAssertThrowsError(try session.start(device: Self.builtIn)) { error in
            XCTAssertEqual(error as? AudioCaptureError, .alreadyCapturing)
        }
        session.stop()
    }

    func testSessionStopsWhenDeliveryQueueSaturates() throws {
        let hardware = FakeHardware(devices: [Self.builtIn], defaultDevice: Self.builtIn)
        let engine = FakeEngine()
        let session = makeSession(engine: engine, hardware: hardware, pendingByteLimit: 20_000)
        let blocked = DispatchSemaphore(value: 0)
        let firstDelivered = expectation(description: "first")
        let released = OSAllocatedUnfairLock(initialState: false)
        let delivered = OSAllocatedUnfairLock(initialState: 0)
        session.onChunk = { _ in
            if delivered.withLock({ $0 += 1; return $0 }) == 1 { firstDelivered.fulfill() }
            if !released.withLock({ $0 }) { blocked.wait() }
        }
        let limitHit = expectation(description: "limit")
        session.onEvent = { event in
            if case .captureLimitReached = event { limitHit.fulfill() }
        }
        try session.start(device: Self.builtIn)
        for _ in 0 ..< 5 {
            engine.feed(makeFloatBuffer(sampleRate: 16_000, channels: 1, frames: 4_096) { _, _ in 0.2 })
        }
        wait(for: [firstDelivered], timeout: 5)
        released.withLock { $0 = true }
        blocked.signal()
        wait(for: [limitHit], timeout: 5)
        XCTAssertFalse(session.isCapturing)
    }

    func testSessionStartFailureLeavesStoppedSession() {
        let hardware = FakeHardware(devices: [Self.builtIn], defaultDevice: Self.builtIn)
        let engine = FakeEngine()
        engine.startError = AudioHardwareFailure(code: -1)
        let session = makeSession(engine: engine, hardware: hardware)
        XCTAssertThrowsError(try session.start(device: Self.builtIn)) { error in
            XCTAssertEqual(error as? AudioCaptureStartupFailure,
                           AudioCaptureStartupFailure(stage: .engineStart, code: -1))
        }
        XCTAssertFalse(session.isCapturing)
        XCTAssertFalse(engine.isRunning)
    }

    func testStopAndDrainWaitsForQueuedChunks() async throws {
        let hardware = FakeHardware(devices: [Self.builtIn], defaultDevice: Self.builtIn)
        let engine = FakeEngine()
        let session = makeSession(engine: engine, hardware: hardware)
        let firstChunk = expectation(description: "first")
        let stall = DispatchSemaphore(value: 0)
        let delivered = OSAllocatedUnfairLock(initialState: 0)
        let released = OSAllocatedUnfairLock(initialState: false)
        session.onChunk = { _ in
            if delivered.withLock({ $0 += 1; return $0 }) == 1 { firstChunk.fulfill() }
            if !released.withLock({ $0 }) { stall.wait() }
        }
        try session.start(device: Self.builtIn)
        engine.feed(makeFloatBuffer(sampleRate: 16_000, channels: 1, frames: 1_600) { _, _ in 0.3 })
        await fulfillment(of: [firstChunk], timeout: 5)
        engine.feed(makeFloatBuffer(sampleRate: 16_000, channels: 1, frames: 1_600) { _, _ in 0.3 })
        engine.feed(makeFloatBuffer(sampleRate: 16_000, channels: 1, frames: 1_600) { _, _ in 0.3 })
        let drainTask = Task {
            await session.stopAndDrain(until: .now + .seconds(5))
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) {
            released.withLock { $0 = true }
            stall.signal()
        }
        let drained = await drainTask.value
        XCTAssertTrue(drained)
        XCTAssertEqual(delivered.withLock { $0 }, 3)
        XCTAssertFalse(session.isCapturing)
        XCTAssertFalse(engine.isRunning)
    }

    func testStopAndDrainBoundsWaitOnDeadline() async throws {
        let hardware = FakeHardware(devices: [Self.builtIn], defaultDevice: Self.builtIn)
        let engine = FakeEngine()
        let session = makeSession(engine: engine, hardware: hardware)
        let firstChunk = expectation(description: "first")
        let stall = DispatchSemaphore(value: 0)
        let released = OSAllocatedUnfairLock(initialState: false)
        session.onChunk = { _ in
            firstChunk.fulfill()
            if !released.withLock({ $0 }) { stall.wait() }
        }
        try session.start(device: Self.builtIn)
        engine.feed(makeFloatBuffer(sampleRate: 16_000, channels: 1, frames: 1_600) { _, _ in 0.3 })
        await fulfillment(of: [firstChunk], timeout: 5)
        engine.feed(makeFloatBuffer(sampleRate: 16_000, channels: 1, frames: 1_600) { _, _ in 0.3 })
        let drained = await session.stopAndDrain(until: .now + .milliseconds(200))
        XCTAssertFalse(drained)
        XCTAssertFalse(engine.isRunning)
        released.withLock { $0 = true }
        stall.signal()
    }

    func testRapidStopStartKeepsNewSessionAlive() async throws {
        let hardware = FakeHardware(devices: [Self.builtIn, Self.usb], defaultDevice: Self.builtIn)
        let engine = FakeEngine()
        let session = makeSession(engine: engine, hardware: hardware)
        try session.start(device: Self.builtIn)
        engine.feed(makeFloatBuffer(sampleRate: 16_000, channels: 1, frames: 1_600) { _, _ in 0.3 })
        session.stop()
        try session.start(device: Self.usb)
        XCTAssertTrue(session.isCapturing)
        let chunk = expectation(description: "new chunk")
        session.onChunk = { _ in chunk.fulfill() }
        engine.feed(makeFloatBuffer(sampleRate: 16_000, channels: 1, frames: 1_600) { _, _ in 0.3 })
        await fulfillment(of: [chunk], timeout: 5)
        XCTAssertTrue(engine.isRunning)
        XCTAssertEqual(engine.pinnedDeviceID, Self.usb.objectID)
        XCTAssertEqual(engine.pinCalls, 2)
        session.stop()
    }

    func testStaleTeardownCannotKillNewSession() async throws {
        let controlQueue = DispatchQueue(label: "test.gated-control")
        let hardware = FakeHardware(devices: [Self.builtIn, Self.usb], defaultDevice: Self.usb)
        let engine = FakeEngine()
        let session = makeSession(engine: engine, hardware: hardware, controlQueue: controlQueue)
        try session.start(device: Self.usb)
        let blocker = DispatchSemaphore(value: 0)
        controlQueue.async { blocker.wait() }
        hardware.removeDevice(Self.usb.objectID)
        hardware.simulateDeviceListChange()
        let restart = expectation(description: "restart")
        DispatchQueue.global().async {
            try? session.start(device: Self.builtIn)
            restart.fulfill()
        }
        try await Task.sleep(for: .milliseconds(50))
        blocker.signal()
        await fulfillment(of: [restart], timeout: 5)
        XCTAssertTrue(session.isCapturing)
        let chunk = expectation(description: "new chunk")
        session.onChunk = { _ in chunk.fulfill() }
        engine.feed(makeFloatBuffer(sampleRate: 16_000, channels: 1, frames: 1_600) { _, _ in 0.4 })
        await fulfillment(of: [chunk], timeout: 5)
        XCTAssertTrue(engine.isRunning)
        session.stop()
    }

    func testOldGenerationCloseCannotSilenceNewSession() async throws {
        let callbackQueue = DispatchQueue(label: "test.gated-callbacks")
        let hardware = FakeHardware(devices: [Self.builtIn], defaultDevice: Self.builtIn)
        let engine = FakeEngine()
        let session = AVAudioCaptureSession(
            engine: engine,
            hardware: hardware,
            callbackQueue: callbackQueue,
            controlQueue: DispatchQueue(label: "test.gated-control2"))
        let gate = DispatchSemaphore(value: 0)
        callbackQueue.async { gate.wait() }
        try session.start(device: Self.builtIn)
        engine.feed(makeFloatBuffer(sampleRate: 16_000, channels: 1, frames: 1_600) { _, _ in 0.2 })
        session.stop()
        try session.start(device: Self.usb)
        gate.signal()
        let chunk = expectation(description: "new session chunk")
        session.onChunk = { _ in chunk.fulfill() }
        engine.feed(makeFloatBuffer(sampleRate: 16_000, channels: 1, frames: 1_600) { _, _ in 0.4 })
        await fulfillment(of: [chunk], timeout: 5)
        XCTAssertTrue(session.isCapturing)
        session.stop()
    }
}
