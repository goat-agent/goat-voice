import Foundation

public enum MicrophoneSelection: Codable, Equatable, Sendable {
    case systemDefault
    case pinned(deviceUID: String, label: String)
}

public struct AudioInputDevice: Equatable, Sendable {
    public var objectID: UInt32
    public var uid: String
    public var name: String

    public init(objectID: UInt32, uid: String, name: String) {
        self.objectID = objectID
        self.uid = uid
        self.name = name
    }
}

public enum AudioDeviceError: Error, Equatable {
    case noInputDevices
    case pinnedDeviceMissing(uid: String)
    case deviceQueryFailed(code: Int32)
}

public protocol AudioDeviceResolving: Sendable {
    func inputDevices() throws -> [AudioInputDevice]
    func resolve(_ selection: MicrophoneSelection) throws -> AudioInputDevice
}

public struct AudioCaptureLimits: Sendable {
    public var maximumCapturedBytes: Int
    public var canonicalSampleRate: Double
    public var canonicalChannels: Int

    public init(maximumCapturedBytes: Int = 41_943_040,
                canonicalSampleRate: Double = 16_000,
                canonicalChannels: Int = 1) {
        self.maximumCapturedBytes = maximumCapturedBytes
        self.canonicalSampleRate = canonicalSampleRate
        self.canonicalChannels = canonicalChannels
    }
}

public struct CapturedAudioChunk: Sendable {
    public var pcm16: Data
    public var frameCount: Int

    public init(pcm16: Data, frameCount: Int) {
        self.pcm16 = pcm16
        self.frameCount = frameCount
    }
}

public struct AudioLevelUpdate: Sendable {
    public var rms: Double
    public var peak: Double

    public init(rms: Double, peak: Double) {
        self.rms = rms
        self.peak = peak
    }
}

public enum AudioCaptureEvent: Sendable {
    case inputDeviceLost
    case captureLimitReached
    case engineInterrupted
}

public enum AudioCaptureError: Error, Equatable {
    case alreadyCapturing
    case engineUnavailable
}

public struct AudioCaptureStartupFailure: Error, Equatable, Sendable {
    public enum Stage: String, Equatable, Sendable {
        case inputDeviceBinding
        case inputFormatQuery
        case inputTapInstall
        case engineStart
    }

    public var stage: Stage
    public var code: Int32

    public init(stage: Stage, code: Int32) {
        self.stage = stage
        self.code = code
    }
}

public protocol AudioCapturing: AnyObject, Sendable {
    var onChunk: (@Sendable (CapturedAudioChunk) -> Void)? { get set }
    var onLevel: (@Sendable (AudioLevelUpdate) -> Void)? { get set }
    var onEvent: (@Sendable (AudioCaptureEvent) -> Void)? { get set }
    func start(device: AudioInputDevice) throws
    func stop()
    func stopAndDrain(until deadline: ContinuousClock.Instant) async -> Bool
    var isCapturing: Bool { get }
}
