import Foundation
import GoatVoicePlatform

struct CatalogModel: Equatable, Sendable {
    var manifest: ModelManifest
    var title: String
    var isRecommended: Bool
}

enum ModelDisplayMetadata {
    static func title(for modelID: String) -> String {
        switch modelID {
        case "qwen3-asr-1.7b": return "Qwen3-ASR 1.7B"
        case "whisper-large-v3-turbo": return "Whisper large-v3-turbo"
        default: return modelID
        }
    }
}
