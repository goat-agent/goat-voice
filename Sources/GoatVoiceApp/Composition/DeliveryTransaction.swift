import Foundation
import GoatVoiceCore
import GoatVoicePlatform

@MainActor
final class DeliveryTransaction {
    struct Dependencies {
        let clipboard: ClipboardCoordinator
        let accessibility: any AccessibilityBackend
        let targetResolver: TargetResolver
        let intentGuard: UserIntentGuard
        let latch: InterruptibilityLatch
        let cancelFlag: CancellationFlag
        let makeInserter: @Sendable () -> TextInserter
        let sessionIsValid: @Sendable () -> Bool
        let onDiagnostic: @Sendable (DeliveryDiagnostic) -> Void

        init(clipboard: ClipboardCoordinator,
             accessibility: any AccessibilityBackend,
             targetResolver: TargetResolver,
             intentGuard: UserIntentGuard,
             latch: InterruptibilityLatch,
             cancelFlag: CancellationFlag,
             makeInserter: @escaping @Sendable () -> TextInserter,
             sessionIsValid: @escaping @Sendable () -> Bool = { true },
             onDiagnostic: @escaping @Sendable (DeliveryDiagnostic) -> Void = { _ in }) {
            self.clipboard = clipboard
            self.accessibility = accessibility
            self.targetResolver = targetResolver
            self.intentGuard = intentGuard
            self.latch = latch
            self.cancelFlag = cancelFlag
            self.makeInserter = makeInserter
            self.sessionIsValid = sessionIsValid
            self.onDiagnostic = onDiagnostic
        }
    }

    let token: AttemptToken
    let transcript: String
    let release: ReleaseContext?
    private let deps: Dependencies

    var onPosted: (() -> Void)?
    var onAborted: ((PreparedRecovery) -> Void)?

    private let abortSignal = CancellationFlag()
    private var settleStarted = false
    private var resolved = false
    private let pasteCommitSignal = CancellationFlag()
    private var snapshot: PasteboardSnapshot?
    private var fence: ClipboardFence?
    private var restoreTask: Task<Void, Never>?

    init(token: AttemptToken, transcript: String,
         release: ReleaseContext?, deps: Dependencies) {
        self.token = token
        self.transcript = transcript
        self.release = release
        self.deps = deps
    }

    func run() async {
        let normalized = TextNormalization.normalize(transcript)
        guard !normalized.isEmpty else {
            resolve(.explicitCopy(.newerClipboard), kind: .explicitCopy, reason: .emptyTranscript)
            return
        }
        guard live() else { abort(); return }
        let settled = await deps.clipboard.awaitTransientResidueSettled()
        if !settled { emit(.residueWaitTimedOut) }
        guard live() else { abort(); return }
        let (capturedSnapshot, snapshotOutcome) = await captureSnapshot()
        guard live() else { abort(); return }
        self.snapshot = capturedSnapshot
        let currentChangeCount = await deps.clipboard.currentChangeCount()
        guard live() else { abort(); return }
        let verification = targetVerification()
        let intent = deps.intentGuard.verdict()
        let context = DeliveryContext(
            finishReason: release?.finishReason ?? .normalRelease,
            snapshot: capturedSnapshot != nil ? .safe : .unsafe,
            target: targetIdentity(verification),
            intent: intentVerdict(intent),
            boundaryChangeCount: release?.boundaryChangeCount ?? currentChangeCount,
            currentChangeCount: currentChangeCount)
        let decision = DeliveryPolicy.decision(for: context)
        emit(.decision(DeliveryDecisionTrace(
            finishPermitsInsertion: context.finishReason.permitsAutomaticInsertion,
            snapshot: snapshotOutcome,
            verification: verification,
            intent: intent,
            clipboardUnchangedSinceBoundary: context.clipboardUnchangedSinceBoundary,
            decision: decision)))
        switch decision {
        case .explicitCopy(let reason):
            resolve(.explicitCopy(reason), kind: .explicitCopy,
                    reason: decisionReason(context: context,
                                           snapshotOutcome: snapshotOutcome,
                                           verification: verification,
                                           intent: intent))
        case .copyTranscript:
            await recoveryCopy(normalized, boundary: context.boundaryChangeCount,
                               reason: fallbackReason(context: context,
                                                      verification: verification,
                                                      intent: intent))
        case .pasteSequence:
            await pasteSequence(normalized: normalized)
        }
    }

    func abort() {
        abortSignal.note()
        if !resolved {
            resolved = true
            emit(.invalidated)
        }
        if pasteCommitSignal.isObserved {
            scheduleRestore()
        } else {
            Task { await self.settleAbortedClipboard() }
        }
    }

    private func live() -> Bool {
        !abortSignal.isObserved
            && !deps.cancelFlag.isObserved
            && deps.latch.isInterruptible
            && deps.sessionIsValid()
    }

    private func emit(_ diagnostic: DeliveryDiagnostic) {
        deps.onDiagnostic(diagnostic)
    }

    private func resolve(_ prepared: PreparedRecovery,
                         kind: FallbackKind,
                         reason: FallbackReason) {
        resolved = true
        emit(.fellBack(kind, reason))
        onAborted?(prepared)
    }

    private func inhibition() -> @Sendable () -> Bool {
        let abortSignal = self.abortSignal
        let cancelFlag = deps.cancelFlag
        let latch = deps.latch
        let sessionIsValid = deps.sessionIsValid
        return {
            !abortSignal.isObserved
                && !cancelFlag.isObserved
                && latch.isInterruptible
                && sessionIsValid()
        }
    }

    private func postGate(descriptor: TargetDescriptor,
                          recording rejection: GateRejection) -> @Sendable () -> Bool {
        let base = inhibition()
        let resolver = deps.targetResolver
        let intentGuard = deps.intentGuard
        return {
            guard base() else { rejection.record(.gateSessionLost); return false }
            switch resolver.verify(descriptor) {
            case .same: break
            case .accessibilityUnavailable:
                rejection.record(.gateAccessibilityLost); return false
            case .noFocusedElement:
                rejection.record(.gateFocusLost); return false
            case .focusedNotEditable:
                rejection.record(.gateNotEditable); return false
            case .differentField:
                rejection.record(.gateFieldChanged); return false
            case .differentWindow:
                rejection.record(.gateWindowChanged); return false
            }
            switch intentGuard.verdict() {
            case .clean: break
            case .mutated:
                rejection.record(.gateIntentMutated); return false
            case .untrusted:
                rejection.record(.gateIntentUntrusted); return false
            }
            guard base() else { rejection.record(.gateSessionLost); return false }
            return true
        }
    }

    private func captureSnapshot() async -> (PasteboardSnapshot?, SnapshotOutcome) {
        do {
            return (try await deps.clipboard.snapshot(), .safe)
        } catch let error as ClipboardError {
            return (nil, SnapshotOutcome(error))
        } catch {
            return (nil, .unavailable)
        }
    }

    private func recoveryCopy(_ normalized: String, boundary: Int,
                              reason: FallbackReason) async {
        do {
            _ = try await deps.clipboard.writeRecoveryCopy(
                normalized,
                expectedChangeCount: boundary,
                validatedBy: inhibition())
        } catch {
            guard live() else { abort(); return }
            resolve(.explicitCopy(.newerClipboard), kind: .explicitCopy,
                    reason: writeReason(error))
            return
        }
        guard live() else { abort(); return }
        resolve(.copiedToClipboard, kind: .transcriptCopied, reason: reason)
    }

    private func pasteSequence(normalized: String) async {
        guard let snapshot, let descriptor = release?.target else {
            resolve(.explicitCopy(.newerClipboard), kind: .explicitCopy,
                    reason: .missingDeliveryState)
            return
        }
        let payload: String
        if let context = deps.accessibility.adjacentContext(
            of: descriptor.elementToken, radius: 1) {
            payload = TextNormalization.deliverable(
                normalized, before: context.before.last, after: context.after.first)
        } else {
            payload = normalized
        }
        guard !payload.isEmpty else {
            resolve(.explicitCopy(.newerClipboard), kind: .explicitCopy,
                    reason: .emptyTranscript)
            return
        }
        let writtenFence: ClipboardFence
        do {
            writtenFence = try await deps.clipboard.writeTemporaryTranscript(
                payload,
                expectedChangeCount: snapshot.changeCount,
                validatedBy: inhibition())
        } catch {
            guard live() else { abort(); return }
            resolve(.explicitCopy(.newerClipboard), kind: .explicitCopy,
                    reason: writeReason(error))
            return
        }
        fence = writtenFence
        guard live() else { abort(); return }
        let inserter = deps.makeInserter()
        let rejection = GateRejection()
        let outcome = await deps.clipboard.postPasteIfFenced(
            writtenFence,
            to: descriptor.elementToken.pid,
            using: inserter,
            validatedBy: postGate(descriptor: descriptor, recording: rejection),
            onPosted: { [pasteCommitSignal] in pasteCommitSignal.note() })
        guard live() else { abort(); return }
        switch outcome {
        case .posted:
            resolved = true
            deps.intentGuard.end()
            emit(.posted)
            onPosted?()
            scheduleRestore()
        case .postFailed:
            await deps.clipboard.leaveTemporaryAsClipboard(writtenFence)
            resolve(.copiedToClipboard, kind: .transcriptCopied, reason: .postFailed)
        case .alreadyAttempted:
            await deps.clipboard.leaveTemporaryAsClipboard(writtenFence)
            resolve(.copiedToClipboard, kind: .transcriptCopied, reason: .postAlreadyAttempted)
        case .preconditionRejected:
            await deps.clipboard.leaveTemporaryAsClipboard(writtenFence)
            resolve(.copiedToClipboard, kind: .transcriptCopied,
                    reason: rejection.reason ?? .gateSessionLost)
        case .clipboardOwnershipLost:
            resolve(.explicitCopy(.newerClipboard), kind: .explicitCopy,
                    reason: .ownershipLost)
        }
    }

    private func targetVerification() -> TargetVerification? {
        guard let target = release?.target else { return nil }
        return deps.targetResolver.verify(target)
    }

    private func targetIdentity(_ verification: TargetVerification?) -> TargetIdentity {
        guard release?.target != nil else { return .untrusted }
        return verification == .same ? .sameEditableField : .mismatch
    }

    private func intentVerdict(_ verdict: MutationGuardVerdict) -> IntentVerdict {
        switch verdict {
        case .clean: return .unmutated
        case .mutated: return .mutated
        case .untrusted: return .untrusted
        }
    }

    private func decisionReason(context: DeliveryContext,
                                snapshotOutcome: SnapshotOutcome,
                                verification: TargetVerification?,
                                intent: MutationGuardVerdict) -> FallbackReason {
        if context.snapshot == .unsafe {
            switch snapshotOutcome {
            case .oversize: return .unsafeSnapshotOversize
            case .promisedContent: return .unsafeSnapshotPromised
            case .transientResidue: return .transientResidue
            case .safe, .unavailable: return .unsafeSnapshot
            }
        }
        return fallbackReason(context: context, verification: verification, intent: intent)
    }

    private func fallbackReason(context: DeliveryContext,
                                verification: TargetVerification?,
                                intent: MutationGuardVerdict) -> FallbackReason {
        if !context.finishReason.permitsAutomaticInsertion { return .finishBlocked }
        if release?.target == nil { return .targetUncaptured }
        if verification != .same { return .targetMismatch }
        if intent == .mutated { return .intentMutated }
        if intent == .untrusted { return .intentUntrusted }
        return .newerClipboard
    }

    private func writeReason(_ error: Error) -> FallbackReason {
        guard let error = error as? ClipboardError else { return .writeFailed }
        switch error {
        case .boundaryMismatch: return .writeBoundaryMismatch
        case .preconditionRejected: return .writeRejected
        default: return .writeFailed
        }
    }

    private func settleAbortedClipboard() async {
        guard !settleStarted, let fence, let snapshot else { return }
        if pasteCommitSignal.isObserved {
            scheduleRestore()
            return
        }
        settleStarted = true
        _ = await deps.clipboard.restore(
            snapshot, guardedBy: fence,
            validatedBy: { [pasteCommitSignal] in !pasteCommitSignal.isObserved })
        if pasteCommitSignal.isObserved { scheduleRestore() }
    }

    private func scheduleRestore() {
        guard restoreTask == nil else { return }
        restoreTask = Task {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            await self.restoreIfOwned()
        }
    }

    private func restoreIfOwned() async {
        guard let fence, let snapshot else { return }
        let current = await deps.clipboard.currentChangeCount()
        let decision = DeliveryPolicy.restoreDecision(for: RestoreContext(
            temporaryChangeCount: fence.changeCount,
            currentChangeCount: current,
            pastePosted: pasteCommitSignal.isObserved))
        guard decision == .restoreSnapshot else {
            await deps.clipboard.leaveTemporaryAsClipboard(fence)
            return
        }
        _ = await deps.clipboard.restore(snapshot, guardedBy: fence)
    }
}
