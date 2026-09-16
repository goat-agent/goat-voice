import Foundation
import GoatVoiceCore
import GoatVoicePlatform

enum SnapshotOutcome: String, Equatable, Sendable {
    case safe
    case oversize
    case promisedContent
    case transientResidue
    case unavailable

    init(_ error: ClipboardError) {
        switch error {
        case .snapshotExceedsLimit: self = .oversize
        case .promisedContentUnavailable: self = .promisedContent
        case .transientResidue: self = .transientResidue
        case .snapshotUnavailable, .writeFailed, .boundaryMismatch,
             .preconditionRejected:
            self = .unavailable
        }
    }
}

enum FallbackReason: String, Equatable, Sendable {
    case emptyTranscript
    case unsafeSnapshot
    case unsafeSnapshotOversize
    case unsafeSnapshotPromised
    case transientResidue
    case finishBlocked
    case targetUncaptured
    case targetMismatch
    case intentMutated
    case intentUntrusted
    case newerClipboard
    case missingDeliveryState
    case writeBoundaryMismatch
    case writeRejected
    case writeFailed
    case gateSessionLost
    case gateAccessibilityLost
    case gateFocusLost
    case gateNotEditable
    case gateFieldChanged
    case gateWindowChanged
    case gateIntentMutated
    case gateIntentUntrusted
    case postFailed
    case postAlreadyAttempted
    case ownershipLost
}

enum FallbackKind: String, Equatable, Sendable {
    case transcriptCopied
    case explicitCopy
}

struct DeliveryDecisionTrace: Equatable, Sendable {
    var finishPermitsInsertion: Bool
    var snapshot: SnapshotOutcome
    var verification: TargetVerification?
    var intent: MutationGuardVerdict
    var clipboardUnchangedSinceBoundary: Bool
    var decision: DeliveryDecision
}

enum DeliveryDiagnostic: Equatable, Sendable {
    case decision(DeliveryDecisionTrace)
    case residueWaitTimedOut
    case posted
    case fellBack(FallbackKind, FallbackReason)
    case invalidated
}

final class GateRejection: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: FallbackReason?

    var reason: FallbackReason? { lock.withLock { stored } }

    func record(_ reason: FallbackReason) {
        lock.withLock { if stored == nil { stored = reason } }
    }
}
