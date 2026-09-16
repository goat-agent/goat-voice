import AudioToolbox
import AVFAudio
import CoreAudio
import Foundation

public protocol AudioEngineBackend: AnyObject, Sendable {
    var isRunning: Bool { get }
    func setInputDevice(_ objectID: UInt32) throws
    func inputHardwareFormat() throws -> AVAudioFormat
    func installInputTap(bufferSize: AVAudioFrameCount,
                         format: AVAudioFormat,
                         handler: @escaping @Sendable (AVAudioPCMBuffer) -> Void) throws
    func removeInputTap()
    func start() throws
    func stop()
    func observeConfigurationChanges(
        _ handler: @escaping @Sendable () -> Void) -> AudioObservationToken
}

public final class AVAudioEngineBackend: AudioEngineBackend, @unchecked Sendable {
    private let engine: AVAudioEngine
    private let lock = NSLock()
    private var tapInstalled = false

    public init(engine: AVAudioEngine = AVAudioEngine()) {
        self.engine = engine
    }

    public var isRunning: Bool {
        engine.isRunning
    }

    public func setInputDevice(_ objectID: UInt32) throws {
        guard let audioUnit = engine.inputNode.audioUnit else {
            throw AudioCaptureError.engineUnavailable
        }
        var deviceID = AudioDeviceID(objectID)
        let status = AudioUnitSetProperty(
            audioUnit,
            AudioUnitPropertyID(kAudioOutputUnitProperty_CurrentDevice),
            AudioUnitScope(kAudioUnitScope_Global),
            0,
            &deviceID,
            UInt32(MemoryLayout<AudioDeviceID>.size))
        guard status == noErr else { throw AudioHardwareFailure(code: status) }
    }

    public func inputHardwareFormat() throws -> AVAudioFormat {
        engine.inputNode.inputFormat(forBus: 0)
    }

    public func installInputTap(bufferSize: AVAudioFrameCount,
                                format: AVAudioFormat,
                                handler: @escaping @Sendable (AVAudioPCMBuffer) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard !tapInstalled else { return }
        engine.inputNode.installTap(onBus: 0, bufferSize: bufferSize, format: format) { buffer, _ in
            handler(buffer)
        }
        tapInstalled = true
    }

    public func removeInputTap() {
        lock.lock()
        defer { lock.unlock() }
        guard tapInstalled else { return }
        engine.inputNode.removeTap(onBus: 0)
        tapInstalled = false
    }

    public func start() throws {
        try engine.start()
    }

    public func stop() {
        engine.stop()
    }

    public func observeConfigurationChanges(
        _ handler: @escaping @Sendable () -> Void) -> AudioObservationToken {
        let observer = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil) { _ in handler() }
        return AudioObservationToken {
            NotificationCenter.default.removeObserver(observer)
        }
    }
}
