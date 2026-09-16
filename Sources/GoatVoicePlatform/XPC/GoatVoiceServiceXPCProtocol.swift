import Foundation

public enum GoatVoiceServiceWire {
    public static let serviceName = "ai.goat.voice.stt"
    public static let errorDomain = "GoatVoice.Service"
    public static let protocolVersion = 2
    public static let maxChunkBytes = 262_144
    public static let maxSessionAudioBytes = 38_400_000
    public static let maxSessions = 1
    public static let modelLoadWatchdog: Duration = .seconds(60)
    public static let previewDeadline: Duration = .seconds(20)
}

@objc(GoatVoiceServiceXPCProtocol)
public protocol GoatVoiceServiceXPCProtocol {
    func handshake(reply: @escaping (NSDictionary) -> Void)

    func loadModel(_ modelID: NSString, modelDirectory: NSURL,
                   reply: @escaping (NSError?) -> Void)
    func unloadModel(reply: @escaping () -> Void)

    func beginSession(_ sessionID: NSString, reply: @escaping (NSError?) -> Void)
    func pushAudio(_ chunk: NSData, sessionID: NSString, offset: UInt64,
                   reply: @escaping (NSError?) -> Void)
    func previewSession(_ sessionID: NSString,
                        reply: @escaping (NSString?, NSError?) -> Void)
    func finishSession(_ sessionID: NSString, canonicalAudio: NSData?,
                       deadline: NSDate,
                       reply: @escaping (NSString?, NSError?) -> Void)
    func cancelSession(_ sessionID: NSString)
}

public enum GoatVoiceServiceXPCInterface {
    public static func make() -> NSXPCInterface {
        let interface = NSXPCInterface(with: GoatVoiceServiceXPCProtocol.self)
        let handshakeReplyClasses = NSSet(
            objects: NSDictionary.self, NSArray.self, NSString.self, NSNumber.self, NSNull.self
        ) as! Set<AnyHashable>
        interface.setClasses(
            handshakeReplyClasses,
            for: #selector(GoatVoiceServiceXPCProtocol.handshake(reply:)),
            argumentIndex: 0,
            ofReply: true
        )
        return interface
    }
}

public enum GoatVoiceServiceErrorKind: Int, Sendable, Equatable, CaseIterable {
    case invalidArgument = 1
    case modelNotSelected = 2
    case modelNotInstalled = 3
    case modelCorrupt = 4
    case backendUnavailable = 5
    case modelLoadFailed = 6
    case modelLoadTimedOut = 7
    case busyLoading = 8
    case inferenceFailed = 9
    case deadlineExceeded = 10
    case cancelled = 11
    case sessionUnknown = 12
    case sessionClosed = 13
    case sessionLimitExceeded = 14
    case audioOffsetMismatch = 15
    case chunkTooLarge = 16
    case sessionAudioLimitExceeded = 17

    public var isRetryable: Bool {
        self == .busyLoading || self == .inferenceFailed
    }
}

public enum ServiceModelState: String, Sendable, Equatable {
    case unloaded
    case loading
    case loaded
    case failed
    case unknown
}

public struct ServiceHandshake: Sendable, Equatable {
    public var protocolVersion: Int
    public var serviceInstanceID: String
    public var modelID: String?
    public var modelState: ServiceModelState
    public var engines: [String: Bool]

    public init(protocolVersion: Int, serviceInstanceID: String, modelID: String?,
                modelState: ServiceModelState, engines: [String: Bool]) {
        self.protocolVersion = protocolVersion
        self.serviceInstanceID = serviceInstanceID
        self.modelID = modelID
        self.modelState = modelState
        self.engines = engines
    }

    public init?(payload: NSDictionary) {
        guard let version = (payload["protocolVersion"] as? NSNumber)?.intValue,
              let instance = payload["serviceInstanceID"] as? String else {
            return nil
        }
        protocolVersion = version
        serviceInstanceID = instance
        modelID = payload["modelID"] as? String
        if let raw = payload["modelState"] as? String,
           let state = ServiceModelState(rawValue: raw) {
            modelState = state
        } else {
            modelState = .unknown
        }
        var parsed: [String: Bool] = [:]
        if let table = payload["engines"] as? NSDictionary {
            for (key, value) in table {
                guard let name = key as? String, let state = value as? String else { continue }
                parsed[name] = state == "available"
            }
        }
        engines = parsed
    }
}
