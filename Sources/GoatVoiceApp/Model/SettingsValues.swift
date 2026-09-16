import Foundation

enum PermissionState: Equatable, Sendable {
    case notDetermined
    case allowed
    case denied
}

struct ModelItem: Equatable, Identifiable, Sendable {
    var id: String
    var title: String
    var isRecommended: Bool
    var state: ModelState
}

enum ModelState: Equatable, Sendable {
    case notInstalled
    case downloading(DownloadProgress)
    case verifying
    case loading
    case ready
    case downloadFailed
    case checksumFailed
    case loadFailed

    struct DownloadProgress: Equatable, Sendable {
        var fraction: Double?
        var receivedBytes: Int64?
        var totalBytes: Int64?
    }
}

struct MicrophoneItem: Equatable, Identifiable, Sendable {
    var id: String
    var name: String
}

enum MenuStatus: Equatable, Sendable {
    case setupRequired
    case downloadingModel(fraction: Double?)
    case loadingModel
    case ready
    case modelUnavailable

    var title: String {
        switch self {
        case .setupRequired:
            return "Setup Required"
        case .downloadingModel(let fraction):
            if let fraction {
                return "Downloading Model… \(Int((fraction * 100).rounded()))%"
            }
            return "Downloading Model…"
        case .loadingModel:
            return "Loading Model…"
        case .ready:
            return "Ready"
        case .modelUnavailable:
            return "Model Unavailable"
        }
    }
}
