import Foundation

enum GoatVoiceServiceError: Int, Error, Sendable {
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

    static let domain = "GoatVoice.Service"

    var isRetryable: Bool {
        self == .busyLoading || self == .inferenceFailed
    }

    func nsError(detail: String? = nil, extraUserInfo: [String: Any] = [:]) -> NSError {
        var userInfo: [String: Any] = [
            NSLocalizedDescriptionKey: detail ?? defaultDescription,
            "retryable": isRetryable,
        ]
        for (key, value) in extraUserInfo {
            userInfo[key] = value
        }
        return NSError(domain: Self.domain, code: rawValue, userInfo: userInfo)
    }

    private var defaultDescription: String {
        switch self {
        case .invalidArgument: return "invalid argument"
        case .modelNotSelected: return "no model selected or loaded"
        case .modelNotInstalled: return "model files not installed"
        case .modelCorrupt: return "model artifact failed verification"
        case .backendUnavailable: return "ASR backend not available in this build"
        case .modelLoadFailed: return "model failed to load"
        case .modelLoadTimedOut: return "model load exceeded watchdog"
        case .busyLoading: return "a different model load is in flight"
        case .inferenceFailed: return "transcription failed"
        case .deadlineExceeded: return "post-release deadline exceeded"
        case .cancelled: return "session cancelled"
        case .sessionUnknown: return "unknown session"
        case .sessionClosed: return "session is closed"
        case .sessionLimitExceeded: return "live session limit exceeded"
        case .audioOffsetMismatch: return "audio chunk offset mismatch"
        case .chunkTooLarge: return "audio chunk exceeds bound"
        case .sessionAudioLimitExceeded: return "session audio exceeds bound"
        }
    }
}

extension Error {
    var goatVoiceServiceNSError: NSError {
        if let error = self as? GoatVoiceServiceError {
            return error.nsError()
        }
        if self is CancellationError {
            return GoatVoiceServiceError.cancelled.nsError()
        }
        let bridged = self as NSError
        if bridged.domain == GoatVoiceServiceError.domain {
            return bridged
        }
        return GoatVoiceServiceError.inferenceFailed.nsError(extraUserInfo: [
            "underlyingDomain": bridged.domain,
            "underlyingCode": bridged.code,
        ])
    }
}
