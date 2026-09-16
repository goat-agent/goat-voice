import CoreGraphics
import Foundation

enum IndicatorContent: Equatable, Sendable {
    case hidden
    case strip(StripPhase)
    case notice(Notice)
    case exiting(ExitKind)
}

enum StripPhase: Equatable, Sendable {
    case listening
    case processing
}

enum ExitKind: Equatable, Sendable {
    case delivered
    case cancelled
}

struct SessionPresentation: Equatable, Sendable {
    var content: IndicatorContent
    var displayID: CGDirectDisplayID?

    static let idle = SessionPresentation(content: .hidden, displayID: nil)
}

extension IndicatorContent {
    var isSessionActive: Bool {
        switch self {
        case .strip, .exiting:
            return true
        case .hidden, .notice:
            return false
        }
    }
}
