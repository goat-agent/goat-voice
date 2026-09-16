import Foundation

public enum SnapshotSafety: Sendable, Equatable {
    case safe
    case unsafe
}

public enum TargetIdentity: Sendable, Equatable {
    case sameEditableField
    case mismatch
    case untrusted
}

public enum IntentVerdict: Sendable, Equatable {
    case unmutated
    case mutated
    case untrusted
}

public enum ExplicitCopyReason: String, Sendable, Equatable {
    case unsafeSnapshot
    case newerClipboard
}

public enum DeliveryDecision: Sendable, Equatable {
    case pasteSequence
    case copyTranscript
    case explicitCopy(ExplicitCopyReason)
}

public struct DeliveryContext: Sendable, Equatable {
    public var finishReason: FinishReason
    public var snapshot: SnapshotSafety
    public var target: TargetIdentity
    public var intent: IntentVerdict
    public var boundaryChangeCount: Int
    public var currentChangeCount: Int

    public init(finishReason: FinishReason,
                snapshot: SnapshotSafety,
                target: TargetIdentity,
                intent: IntentVerdict,
                boundaryChangeCount: Int,
                currentChangeCount: Int) {
        self.finishReason = finishReason
        self.snapshot = snapshot
        self.target = target
        self.intent = intent
        self.boundaryChangeCount = boundaryChangeCount
        self.currentChangeCount = currentChangeCount
    }

    public var clipboardUnchangedSinceBoundary: Bool {
        boundaryChangeCount == currentChangeCount
    }
}

public enum PrePasteDecision: Sendable, Equatable {
    case postPaste
    case keepTranscript
    case preserveNewerClipboard
    case alreadyAttempted
}

public struct PrePasteContext: Sendable, Equatable {
    public var target: TargetIdentity
    public var intent: IntentVerdict
    public var temporaryChangeCount: Int
    public var currentChangeCount: Int
    public var pasteAlreadyAttempted: Bool

    public init(target: TargetIdentity,
                intent: IntentVerdict,
                temporaryChangeCount: Int,
                currentChangeCount: Int,
                pasteAlreadyAttempted: Bool) {
        self.target = target
        self.intent = intent
        self.temporaryChangeCount = temporaryChangeCount
        self.currentChangeCount = currentChangeCount
        self.pasteAlreadyAttempted = pasteAlreadyAttempted
    }

    public var ownsTemporaryClipboard: Bool {
        temporaryChangeCount == currentChangeCount
    }
}

public enum RestoreDecision: Sendable, Equatable {
    case restoreSnapshot
    case keepTranscript
    case preserveNewerClipboard
}

public struct RestoreContext: Sendable, Equatable {
    public var temporaryChangeCount: Int
    public var currentChangeCount: Int
    public var pastePosted: Bool

    public init(temporaryChangeCount: Int,
                currentChangeCount: Int,
                pastePosted: Bool) {
        self.temporaryChangeCount = temporaryChangeCount
        self.currentChangeCount = currentChangeCount
        self.pastePosted = pastePosted
    }

    public var ownsTemporaryClipboard: Bool {
        temporaryChangeCount == currentChangeCount
    }
}

public enum DeliveryPolicy {
    public static func decision(for context: DeliveryContext) -> DeliveryDecision {
        if context.snapshot == .unsafe {
            return .explicitCopy(.unsafeSnapshot)
        }
        guard context.finishReason.permitsAutomaticInsertion,
              context.target == .sameEditableField,
              context.intent == .unmutated else {
            return context.clipboardUnchangedSinceBoundary
                ? .copyTranscript
                : .explicitCopy(.newerClipboard)
        }
        return .pasteSequence
    }

    public static func prePasteDecision(for context: PrePasteContext) -> PrePasteDecision {
        if context.pasteAlreadyAttempted {
            return .alreadyAttempted
        }
        if !context.ownsTemporaryClipboard {
            return .preserveNewerClipboard
        }
        guard context.target == .sameEditableField,
              context.intent == .unmutated else {
            return .keepTranscript
        }
        return .postPaste
    }

    public static func restoreDecision(for context: RestoreContext) -> RestoreDecision {
        if !context.ownsTemporaryClipboard {
            return .preserveNewerClipboard
        }
        return context.pastePosted ? .restoreSnapshot : .keepTranscript
    }
}

public struct PendingRecoveryTranscript: Sendable, Equatable {
    public static let maximumLifetimeSeconds: Double = 30

    public let text: String
    public let storedAtMonotonicSeconds: Double

    public init(text: String, storedAtMonotonicSeconds: Double) {
        self.text = text
        self.storedAtMonotonicSeconds = storedAtMonotonicSeconds
    }

    public func isExpired(atMonotonicSeconds now: Double) -> Bool {
        now - storedAtMonotonicSeconds >= Self.maximumLifetimeSeconds
    }
}
