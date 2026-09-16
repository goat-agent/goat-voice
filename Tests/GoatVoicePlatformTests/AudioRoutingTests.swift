import AVFAudio
import Foundation
import os
import XCTest
@testable import GoatVoicePlatform

final class AudioRoutingTests: XCTestCase {
    private final class FakeHardware: AudioHardwareBackend, @unchecked Sendable {
        private let lock = NSLock()
        private var devices: [AudioInputDevice]
        private var presentIDs: Set<UInt32>
        private var listHandlers: [@Sendable () -> Void] = []
        var defaultDevice: AudioInputDevice?

        init(devices: [AudioInputDevice], defaultDevice: AudioInputDevice?) {
            self.devices = devices
            self.defaultDevice = defaultDevice
            presentIDs = Set(devices.map(\.objectID))
        }

        func inputDevices() throws -> [AudioInputDevice] {
            lock.withLock { devices }
        }

        func defaultInputDevice() throws -> AudioInputDevice? {
            lock.withLock { defaultDevice }
        }

        func isInputDevicePresent(_ objectID: UInt32) -> Bool {
            lock.withLock { presentIDs.contains(objectID) }
        }

        func observeInputDeviceChanges(
            _ handler: @escaping @Sendable () -> Void) -> AudioObservationToken {
            lock.withLock { listHandlers.append(handler) }
            return AudioObservationToken(cancel: {})
        }

        func removeDevice(_ objectID: UInt32) {
            lock.withLock {
                devices.removeAll { $0.objectID == objectID }
                presentIDs.remove(objectID)
            }
        }

        func simulateDeviceListChange() {
            lock.withLock { listHandlers.last }?()
        }

        func simulateStaleDeviceListChange() {
            lock.withLock { listHandlers.first }?()
        }
    }

    private final class FakeEngine: AudioEngineBackend, @unchecked Sendable {
        private let lock = NSLock()
        private var tapHandler: (@Sendable (AVAudioPCMBuffer) -> Void)?
        private var firstTapHandler: (@Sendable (AVAudioPCMBuffer) -> Void)?
        private var configHandlers: [@Sendable () -> Void] = []
        private var running = false
        private(set) var pinnedDeviceID: UInt32?
        private(set) var pinCalls = 0
        private(set) var tapFormat: AVAudioFormat?
        var inputFormat: AVAudioFormat
        var formatError: Error?
        var bindError: Error?
        var installError: Error?
        var startError: Error?
        var onStart: (@Sendable () -> Void)?

        init(inputFormat: AVAudioFormat) {
            self.inputFormat = inputFormat
        }

        var isRunning: Bool { lock.withLock { running } }

        func setInputDevice(_ objectID: UInt32) throws {
            try lock.withLock {
                if let bindError { throw bindError }
                pinnedDeviceID = objectID
                pinCalls += 1
            }
        }

        func inputHardwareFormat() throws -> AVAudioFormat {
            try lock.withLock {
                if let formatError { throw formatError }
                return inputFormat
            }
        }

        func installInputTap(bufferSize: AVAudioFrameCount,
                             format: AVAudioFormat,
                             handler: @escaping @Sendable (AVAudioPCMBuffer) -> Void) throws {
            try lock.withLock {
                if let installError { throw installError }
                tapFormat = format
                tapHandler = handler
                if firstTapHandler == nil { firstTapHandler = handler }
            }
        }

        func removeInputTap() {
            lock.withLock { tapHandler = nil }
        }

        func start() throws {
            if let startError { throw startError }
            onStart?()
            lock.withLock { running = true }
        }

        func stop() {
            lock.withLock { running = false }
        }

        func observeConfigurationChanges(
            _ handler: @escaping @Sendable () -> Void) -> AudioObservationToken {
            lock.withLock { configHandlers.append(handler) }
            return AudioObservationToken(cancel: {})
        }

        func feed(_ buffer: AVAudioPCMBuffer) {
            lock.withLock { tapHandler }?(buffer)
        }

        func feedPreviousSession(_ buffer: AVAudioPCMBuffer) {
            lock.withLock { firstTapHandler }?(buffer)
        }

        func simulateConfigurationChange() {
            lock.withLock { configHandlers.last }?()
        }

        func simulateStaleConfigurationChange() {
            lock.withLock { configHandlers.first }?()
        }
    }

    private static let airpods = AudioInputDevice(objectID: 91, uid: "airpods-uid", name: "AirPods Pro")
    private static let builtIn = AudioInputDevice(objectID: 11, uid: "builtin-mic", name: "MacBook Mic")
    private static let airpodsInputFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 24_000, channels: 1, interleaved: false)!
    private static let engineOutputFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: false)!
    private static let handsfreeInputFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!

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

    private func makeSession(engine: FakeEngine,
                             hardware: FakeHardware,
                             controlQueue: DispatchQueue = DispatchQueue(label: "test.routing-control"))
        -> AVAudioCaptureSession {
        AVAudioCaptureSession(
            engine: engine,
            hardware: hardware,
            callbackQueue: DispatchQueue(label: "test.routing-callbacks"),
            controlQueue: controlQueue,
            tapBufferSize: 4_800)
    }

    func testPreviousSessionAudioCannotEnterRestartedCapture() async throws {
        let hardware = FakeHardware(devices: [Self.airpods], defaultDevice: Self.airpods)
        let engine = FakeEngine(inputFormat: Self.airpodsInputFormat)
        let session = makeSession(engine: engine, hardware: hardware)
        let frames = OSAllocatedUnfairLock(initialState: 0)
        session.onChunk = { chunk in frames.withLock { $0 += chunk.frameCount } }
        try session.start(device: Self.airpods)
        let drained = await session.stopAndDrain(until: .now + .seconds(1))
        XCTAssertTrue(drained)
        try session.start(device: Self.airpods)
        let buffer = makeFloatBuffer(sampleRate: 24_000, channels: 1, frames: 2_400) { _, _ in 0.2 }
        engine.feedPreviousSession(buffer)
        engine.feed(buffer)
        let finalDrain = await session.stopAndDrain(until: .now + .seconds(1))
        XCTAssertTrue(finalDrain)
        XCTAssertEqual(frames.withLock { $0 }, 1_600)
    }

    func testTapBindsToHardwareInputFormatNotEngineOutputFormat() throws {
        let hardware = FakeHardware(devices: [Self.airpods], defaultDevice: Self.airpods)
        let engine = FakeEngine(inputFormat: Self.airpodsInputFormat)
        let session = makeSession(engine: engine, hardware: hardware)
        let chunk = expectation(description: "canonical chunk")
        let frames = OSAllocatedUnfairLock(initialState: 0)
        session.onChunk = { delivered in
            frames.withLock { $0 += delivered.frameCount }
            chunk.fulfill()
        }
        try session.start(device: Self.airpods)
        XCTAssertEqual(engine.tapFormat?.sampleRate, 24_000)
        XCTAssertEqual(engine.tapFormat?.channelCount, 1)
        XCTAssertEqual(engine.tapFormat, Self.airpodsInputFormat)
        XCTAssertNotEqual(engine.tapFormat, Self.engineOutputFormat)
        engine.feed(makeFloatBuffer(sampleRate: 24_000, channels: 1, frames: 4_800) { _, _ in 0.4 })
        wait(for: [chunk], timeout: 5)
        XCTAssertEqual(frames.withLock { $0 }, 3_200, accuracy: 8)
        session.stop()
    }

    func testStartReportsEngineStartStageAndStatus() {
        let hardware = FakeHardware(devices: [Self.airpods], defaultDevice: Self.airpods)
        let engine = FakeEngine(inputFormat: Self.airpodsInputFormat)
        engine.startError = AudioHardwareFailure(code: -10_868)
        let session = makeSession(engine: engine, hardware: hardware)
        XCTAssertThrowsError(try session.start(device: Self.airpods)) { error in
            XCTAssertEqual(error as? AudioCaptureStartupFailure,
                           AudioCaptureStartupFailure(stage: .engineStart, code: -10_868))
        }
        XCTAssertFalse(session.isCapturing)
        XCTAssertFalse(engine.isRunning)
        XCTAssertEqual(engine.pinCalls, 1)
    }

    func testStartReportsDeviceBindingStage() {
        let hardware = FakeHardware(devices: [Self.airpods], defaultDevice: Self.airpods)
        let engine = FakeEngine(inputFormat: Self.airpodsInputFormat)
        engine.bindError = AudioHardwareFailure(code: -10_851)
        let session = makeSession(engine: engine, hardware: hardware)
        XCTAssertThrowsError(try session.start(device: Self.airpods)) { error in
            XCTAssertEqual(error as? AudioCaptureStartupFailure,
                           AudioCaptureStartupFailure(stage: .inputDeviceBinding, code: -10_851))
        }
        XCTAssertFalse(session.isCapturing)
    }

    func testStartReportsInputFormatQueryStageOnQueryFailure() {
        let hardware = FakeHardware(devices: [Self.airpods], defaultDevice: Self.airpods)
        let engine = FakeEngine(inputFormat: Self.airpodsInputFormat)
        engine.formatError = AudioHardwareFailure(code: 50_304)
        let session = makeSession(engine: engine, hardware: hardware)
        XCTAssertThrowsError(try session.start(device: Self.airpods)) { error in
            XCTAssertEqual(error as? AudioCaptureStartupFailure,
                           AudioCaptureStartupFailure(stage: .inputFormatQuery, code: 50_304))
        }
        XCTAssertFalse(session.isCapturing)
    }

    func testStartReportsInputFormatQueryStageOnDegenerateFormat() {
        let hardware = FakeHardware(devices: [Self.airpods], defaultDevice: Self.airpods)
        let engine = FakeEngine(inputFormat: AVAudioFormat())
        let session = makeSession(engine: engine, hardware: hardware)
        XCTAssertThrowsError(try session.start(device: Self.airpods)) { error in
            guard let failure = error as? AudioCaptureStartupFailure else {
                return XCTFail("expected AudioCaptureStartupFailure, got \(error)")
            }
            XCTAssertEqual(failure.stage, .inputFormatQuery)
        }
        XCTAssertFalse(session.isCapturing)
    }

    func testStartReportsTapInstallStage() {
        let hardware = FakeHardware(devices: [Self.airpods], defaultDevice: Self.airpods)
        let engine = FakeEngine(inputFormat: Self.airpodsInputFormat)
        engine.installError = AudioHardwareFailure(code: -10_868)
        let session = makeSession(engine: engine, hardware: hardware)
        XCTAssertThrowsError(try session.start(device: Self.airpods)) { error in
            XCTAssertEqual(error as? AudioCaptureStartupFailure,
                           AudioCaptureStartupFailure(stage: .inputTapInstall, code: -10_868))
        }
        XCTAssertFalse(session.isCapturing)
    }

    func testStartupConfigurationChangeWithLiveDeviceKeepsSession() throws {
        let hardware = FakeHardware(devices: [Self.airpods], defaultDevice: Self.airpods)
        let engine = FakeEngine(inputFormat: Self.airpodsInputFormat)
        engine.onStart = { engine.simulateConfigurationChange() }
        let session = makeSession(engine: engine, hardware: hardware)
        let unexpected = expectation(description: "no event")
        unexpected.isInverted = true
        session.onEvent = { _ in unexpected.fulfill() }
        try session.start(device: Self.airpods)
        wait(for: [unexpected], timeout: 0.5)
        XCTAssertTrue(session.isCapturing)
        XCTAssertTrue(engine.isRunning)
        let chunk = expectation(description: "chunk")
        session.onChunk = { _ in chunk.fulfill() }
        engine.feed(makeFloatBuffer(sampleRate: 24_000, channels: 1, frames: 2_400) { _, _ in 0.3 })
        wait(for: [chunk], timeout: 5)
        session.stop()
    }

    func testConfigurationChangeWithRunningEngineAndStableFormatKeepsCapturing() throws {
        let hardware = FakeHardware(devices: [Self.airpods], defaultDevice: Self.airpods)
        let engine = FakeEngine(inputFormat: Self.airpodsInputFormat)
        let session = makeSession(engine: engine, hardware: hardware)
        let unexpected = expectation(description: "no event")
        unexpected.isInverted = true
        session.onEvent = { _ in unexpected.fulfill() }
        try session.start(device: Self.airpods)
        engine.simulateConfigurationChange()
        wait(for: [unexpected], timeout: 0.5)
        XCTAssertTrue(session.isCapturing)
        let chunk = expectation(description: "chunk")
        session.onChunk = { _ in chunk.fulfill() }
        engine.feed(makeFloatBuffer(sampleRate: 24_000, channels: 1, frames: 2_400) { _, _ in 0.3 })
        wait(for: [chunk], timeout: 5)
        session.stop()
    }

    func testConfigurationChangeWithHaltedEngineEmitsInterrupted() throws {
        let hardware = FakeHardware(devices: [Self.airpods], defaultDevice: Self.airpods)
        let engine = FakeEngine(inputFormat: Self.airpodsInputFormat)
        let session = makeSession(engine: engine, hardware: hardware)
        let interrupted = expectation(description: "interrupted")
        session.onEvent = { event in
            if case .engineInterrupted = event { interrupted.fulfill() }
        }
        try session.start(device: Self.airpods)
        engine.stop()
        engine.simulateConfigurationChange()
        wait(for: [interrupted], timeout: 5)
        XCTAssertFalse(session.isCapturing)
    }

    func testConfigurationChangeWithInputFormatDriftEmitsInterrupted() throws {
        let hardware = FakeHardware(devices: [Self.airpods], defaultDevice: Self.airpods)
        let engine = FakeEngine(inputFormat: Self.airpodsInputFormat)
        let session = makeSession(engine: engine, hardware: hardware)
        let interrupted = expectation(description: "interrupted")
        session.onEvent = { event in
            if case .engineInterrupted = event { interrupted.fulfill() }
        }
        try session.start(device: Self.airpods)
        engine.inputFormat = Self.handsfreeInputFormat
        engine.simulateConfigurationChange()
        wait(for: [interrupted], timeout: 5)
        XCTAssertFalse(session.isCapturing)
    }

    func testActualDisconnectEmitsInputDeviceLostAndPreservesPartialSpeech() throws {
        let hardware = FakeHardware(devices: [Self.airpods, Self.builtIn], defaultDevice: Self.airpods)
        let engine = FakeEngine(inputFormat: Self.airpodsInputFormat)
        let session = makeSession(engine: engine, hardware: hardware)
        let delivered = expectation(description: "delivered")
        let lost = expectation(description: "lost")
        let received = OSAllocatedUnfairLock(initialState: 0)
        let sawChunkBeforeEvent = OSAllocatedUnfairLock(initialState: false)
        session.onChunk = { chunk in
            received.withLock { $0 += chunk.frameCount }
            delivered.fulfill()
        }
        session.onEvent = { event in
            if case .inputDeviceLost = event {
                sawChunkBeforeEvent.withLock { $0 = received.withLock { $0 } > 0 }
                lost.fulfill()
            }
        }
        try session.start(device: Self.airpods)
        engine.feed(makeFloatBuffer(sampleRate: 24_000, channels: 1, frames: 2_400) { _, _ in 0.3 })
        wait(for: [delivered], timeout: 5)
        hardware.removeDevice(Self.airpods.objectID)
        engine.simulateConfigurationChange()
        wait(for: [lost], timeout: 5)
        XCTAssertTrue(sawChunkBeforeEvent.withLock { $0 })
        XCTAssertFalse(session.isCapturing)
        XCTAssertFalse(engine.isRunning)
    }

    func testStaleConfigurationNotificationCannotKillNewSession() throws {
        let hardware = FakeHardware(devices: [Self.airpods, Self.builtIn], defaultDevice: Self.airpods)
        let engine = FakeEngine(inputFormat: Self.airpodsInputFormat)
        let session = makeSession(engine: engine, hardware: hardware)
        try session.start(device: Self.builtIn)
        session.stop()
        try session.start(device: Self.airpods)
        hardware.removeDevice(Self.airpods.objectID)
        engine.simulateStaleConfigurationChange()
        XCTAssertTrue(session.isCapturing)
        let lost = expectation(description: "lost")
        session.onEvent = { event in
            if case .inputDeviceLost = event { lost.fulfill() }
        }
        engine.simulateConfigurationChange()
        wait(for: [lost], timeout: 5)
        XCTAssertFalse(session.isCapturing)
    }

    func testStaleDeviceListNotificationCannotKillNewSession() throws {
        let hardware = FakeHardware(devices: [Self.airpods, Self.builtIn], defaultDevice: Self.airpods)
        let engine = FakeEngine(inputFormat: Self.airpodsInputFormat)
        let session = makeSession(engine: engine, hardware: hardware)
        try session.start(device: Self.builtIn)
        session.stop()
        try session.start(device: Self.airpods)
        hardware.removeDevice(Self.airpods.objectID)
        hardware.simulateStaleDeviceListChange()
        XCTAssertTrue(session.isCapturing)
        let lost = expectation(description: "lost")
        session.onEvent = { event in
            if case .inputDeviceLost = event { lost.fulfill() }
        }
        hardware.simulateDeviceListChange()
        wait(for: [lost], timeout: 5)
        XCTAssertFalse(session.isCapturing)
    }

    func testPinnedDeviceKeepsCapturingWhenDefaultChangesMidSession() throws {
        let hardware = FakeHardware(devices: [Self.airpods, Self.builtIn], defaultDevice: Self.builtIn)
        let engine = FakeEngine(inputFormat: Self.airpodsInputFormat)
        let session = makeSession(engine: engine, hardware: hardware)
        let unexpected = expectation(description: "no event")
        unexpected.isInverted = true
        session.onEvent = { _ in unexpected.fulfill() }
        try session.start(device: Self.builtIn)
        hardware.defaultDevice = Self.airpods
        hardware.simulateDeviceListChange()
        engine.simulateConfigurationChange()
        wait(for: [unexpected], timeout: 0.5)
        XCTAssertTrue(session.isCapturing)
        XCTAssertEqual(engine.pinnedDeviceID, Self.builtIn.objectID)
        XCTAssertEqual(engine.pinCalls, 1)
        let chunk = expectation(description: "chunk")
        session.onChunk = { _ in chunk.fulfill() }
        engine.feed(makeFloatBuffer(sampleRate: 24_000, channels: 1, frames: 2_400) { _, _ in 0.3 })
        wait(for: [chunk], timeout: 5)
        session.stop()
    }
}
