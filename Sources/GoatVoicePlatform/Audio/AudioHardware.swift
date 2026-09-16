import CoreAudio
import Foundation

public struct AudioHardwareFailure: Error, Equatable, Sendable {
    public var code: Int32

    public init(code: Int32) {
        self.code = code
    }
}

public final class AudioObservationToken: Sendable {
    private final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var cancellation: (@Sendable () -> Void)?

        init(_ cancellation: @escaping @Sendable () -> Void) {
            self.cancellation = cancellation
        }

        func cancel() {
            lock.lock()
            let action = cancellation
            cancellation = nil
            lock.unlock()
            action?()
        }
    }

    private let box: Box

    public init(cancel cancellation: @escaping @Sendable () -> Void) {
        box = Box(cancellation)
    }

    public func cancel() {
        box.cancel()
    }

    deinit {
        box.cancel()
    }
}

public protocol AudioHardwareBackend: Sendable {
    func inputDevices() throws -> [AudioInputDevice]
    func defaultInputDevice() throws -> AudioInputDevice?
    func isInputDevicePresent(_ objectID: UInt32) -> Bool
    func observeInputDeviceChanges(_ handler: @escaping @Sendable () -> Void) -> AudioObservationToken
}

public struct CoreAudioHardware: AudioHardwareBackend {
    private static let listenerQueue = DispatchQueue(label: "goat.voice.audio-hardware")

    public init() {}

    public func inputDevices() throws -> [AudioInputDevice] {
        try allDeviceIDs().compactMap { objectID in
            guard let streams = try? inputStreamCount(objectID), streams > 0 else { return nil }
            return try? describe(objectID)
        }
    }

    public func defaultInputDevice() throws -> AudioInputDevice? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var objectID = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &objectID)
        guard status == noErr else { throw AudioHardwareFailure(code: status) }
        guard objectID != AudioObjectID(kAudioObjectUnknown),
              let streams = try? inputStreamCount(objectID), streams > 0,
              let device = try? describe(objectID) else { return nil }
        return device
    }

    public func isInputDevicePresent(_ objectID: UInt32) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsAlive,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var alive: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &alive)
        return status == noErr && alive != 0
    }

    public func observeInputDeviceChanges(
        _ handler: @escaping @Sendable () -> Void) -> AudioObservationToken {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let block: AudioObjectPropertyListenerBlock = { _, _ in handler() }
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, Self.listenerQueue, block)
        guard status == noErr else { return AudioObservationToken(cancel: {}) }
        return AudioObservationToken {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDevices,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &address, Self.listenerQueue, block)
        }
    }

    private func allDeviceIDs() throws -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size)
        guard status == noErr else { throw AudioHardwareFailure(code: status) }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids)
        guard status == noErr else { throw AudioHardwareFailure(code: status) }
        return ids
    }

    private func inputStreamCount(_ objectID: AudioObjectID) throws -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        let status = AudioObjectGetPropertyDataSize(objectID, &address, 0, nil, &size)
        guard status == noErr else { throw AudioHardwareFailure(code: status) }
        return Int(size) / MemoryLayout<AudioStreamID>.size
    }

    private func describe(_ objectID: AudioObjectID) throws -> AudioInputDevice {
        try AudioInputDevice(
            objectID: objectID,
            uid: stringProperty(objectID, selector: kAudioDevicePropertyDeviceUID),
            name: stringProperty(objectID, selector: kAudioDevicePropertyDeviceNameCFString))
    }

    private func stringProperty(_ objectID: AudioObjectID,
                                selector: AudioObjectPropertySelector) throws -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &value)
        guard status == noErr else { throw AudioHardwareFailure(code: status) }
        guard let string = value?.takeRetainedValue() else {
            throw AudioHardwareFailure(code: -1)
        }
        return string as String
    }
}
