import Foundation

struct Notice: Equatable, Sendable {
    enum Message: Equatable, Sendable {
        case microphoneAccessRequired
        case accessibilityRequired
        case shortcutUnavailable
        case modelNotReady
        case modelDownloading
        case modelFailedToLoad
        case microphoneUnavailable
        case microphoneDisconnected
        case transcriptionFailed
        case copiedToClipboard
        case couldntInsert
        case oneMinuteRemaining
    }

    enum Action: Equatable, Sendable {
        case openSettings
        case copyRecoveryTranscript
    }

    var message: Message
    var action: Action?

    var text: String {
        switch message {
        case .microphoneAccessRequired: return "Microphone access required"
        case .accessibilityRequired: return "Accessibility access required"
        case .shortcutUnavailable: return "Shortcut unavailable"
        case .modelNotReady: return "Model not ready"
        case .modelDownloading: return "Model downloading"
        case .modelFailedToLoad: return "Model failed to load"
        case .microphoneUnavailable: return "Microphone unavailable"
        case .microphoneDisconnected: return "Microphone disconnected"
        case .transcriptionFailed: return "Transcription failed"
        case .copiedToClipboard: return "Copied to clipboard"
        case .couldntInsert: return "Couldn't insert"
        case .oneMinuteRemaining: return "1 minute remaining"
        }
    }

    var actionTitle: String? {
        switch action {
        case .openSettings: return "Open Settings"
        case .copyRecoveryTranscript: return "Copy"
        case nil: return nil
        }
    }

    var dismissalTimeout: TimeInterval {
        action == nil ? 2 : 30
    }
}
