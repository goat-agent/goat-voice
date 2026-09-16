import Foundation

public struct SessionID: Hashable, Codable, Sendable {
    public let rawValue: UUID

    public init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

public struct AttemptToken: Hashable, Codable, Sendable {
    public let sessionID: SessionID
    public let attempt: Int

    public init(sessionID: SessionID, attempt: Int = 0) {
        self.sessionID = sessionID
        self.attempt = attempt
    }
}

public enum FinishReason: String, Codable, Sendable {
    case normalRelease
    case microphoneDisconnected
    case recordingLimit

    public var permitsAutomaticInsertion: Bool {
        self == .normalRelease
    }
}

public enum InvalidationReason: String, Codable, Sendable {
    case escape
    case extraKey
    case lock
    case sleep
    case quit
    case deadline
    case captureFailure
}
