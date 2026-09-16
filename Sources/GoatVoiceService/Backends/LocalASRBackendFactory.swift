import Foundation

enum BackendModelID {
    static let whisperLargeV3Turbo = "whisper-large-v3-turbo"
    static let qwen3ASR17B = "qwen3-asr-1.7b"
}

public struct LocalBackendProvider: LocalBackendProviding {
    public init() {}

    public var supportedModelIDs: [String] {
        [BackendModelID.whisperLargeV3Turbo, BackendModelID.qwen3ASR17B]
    }

    public func makeBackend(modelID: String) throws -> any LocalASRBackend {
        switch modelID {
        case BackendModelID.whisperLargeV3Turbo:
            return WhisperKitBackend()
        case BackendModelID.qwen3ASR17B:
            return Qwen3ASRBackend()
        default:
            throw GoatVoiceServiceError.invalidArgument
        }
    }

    public func availability() -> [String: Bool] {
        [
            BackendModelID.whisperLargeV3Turbo: WhisperKitBackend.isAvailable,
            BackendModelID.qwen3ASR17B: Qwen3ASRBackend.isAvailable,
        ]
    }
}
