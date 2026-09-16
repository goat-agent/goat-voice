import CoreGraphics
import Foundation
import GoatVoiceCore
import GoatVoicePlatform

enum RecoveryCopyOutcome: String, Equatable, Sendable {
    case copied
    case writeFailed
    case expired
}

enum RecoveryDiagnostic: Equatable, Sendable {
    case decision(snapshot: SnapshotOutcome, decision: DeliveryDecision)
    case presented(Notice.Message)
    case copyFinished(RecoveryCopyOutcome)
    case staleResultDropped
}

@MainActor
final class RecoveryController: RecoveryActionHandling {
    var onOpenSettings: (() -> Void)?
    var presentNotice: ((Notice, CGDirectDisplayID?) -> Void)?
    var noticeResolved: ((Notice) -> Void)?
    var onDiagnostic: (@Sendable (RecoveryDiagnostic) -> Void)?

    private nonisolated let invalidationSignal = RecoveryInvalidationSignal()
    private let clipboard: ClipboardCoordinator
    private let clock: MonotonicClock
    private var pending: PendingRecoveryTranscript?
    private var expiryTask: Task<Void, Never>?
    private var inFlight: Task<Void, Never>?
    private var epoch: UInt64 = 0
    private var epochFlag: CancellationFlag?

    init(clipboard: ClipboardCoordinator, clock: MonotonicClock) {
        self.clipboard = clipboard
        self.clock = clock
    }

    func present(prepared: PreparedRecovery?, transcript: String,
                 release: ReleaseContext?, displayID: CGDirectDisplayID?) {
        discardPending()
        let normalized = TextNormalization.normalize(transcript)
        guard !normalized.isEmpty else { return }
        let generation = epoch
        let flag = CancellationFlag()
        epochFlag = flag
        invalidationSignal.install(flag)
        if let prepared {
            apply(prepared, text: normalized, displayID: displayID)
            return
        }
        inFlight = Task { [weak self] in
            guard let self else { return }
            _ = await self.clipboard.awaitTransientResidueSettled()
            guard self.alive(generation, flag) else { return }
            let snapshotOutcome = await self.captureSnapshotOutcome()
            guard self.alive(generation, flag) else { return }
            let current = await self.clipboard.currentChangeCount()
            guard self.alive(generation, flag) else { return }
            let context = DeliveryContext(
                finishReason: release?.finishReason ?? .microphoneDisconnected,
                snapshot: snapshotOutcome == .safe ? .safe : .unsafe,
                target: .untrusted,
                intent: .unmutated,
                boundaryChangeCount: release?.boundaryChangeCount ?? current,
                currentChangeCount: current)
            let decision = DeliveryPolicy.decision(for: context)
            self.onDiagnostic?(.decision(snapshot: snapshotOutcome, decision: decision))
            switch decision {
            case .copyTranscript:
                do {
                    _ = try await self.clipboard.writeRecoveryCopy(
                        normalized,
                        expectedChangeCount: context.boundaryChangeCount,
                        validatedBy: { !flag.isObserved })
                    guard self.alive(generation, flag) else { return }
                    self.onDiagnostic?(.copyFinished(.copied))
                    self.showNotice(.copiedToClipboard, action: nil,
                                    displayID: displayID)
                } catch {
                    guard self.alive(generation, flag) else { return }
                    self.onDiagnostic?(.copyFinished(.writeFailed))
                    self.storePending(normalized)
                    self.showNotice(.couldntInsert,
                                    action: .copyRecoveryTranscript,
                                    displayID: displayID)
                }
            case .explicitCopy, .pasteSequence:
                self.storePending(normalized)
                self.showNotice(.couldntInsert,
                                action: .copyRecoveryTranscript,
                                displayID: displayID)
            }
        }
    }

    func performRecoveryAction(_ action: Notice.Action) {
        switch action {
        case .openSettings:
            onOpenSettings?()
        case .copyRecoveryTranscript:
            guard let pending,
                  !pending.isExpired(atMonotonicSeconds: clock.now().seconds),
                  let flag = epochFlag else { return }
            let text = pending.text
            let generation = epoch
            let clock = self.clock
            let expiry = pending.storedAtMonotonicSeconds
                + PendingRecoveryTranscript.maximumLifetimeSeconds
            inFlight = Task { [weak self] in
                guard let self else { return }
                do {
                    _ = try await self.clipboard.writeRecoveryCopy(
                        text,
                        validatedBy: {
                            !flag.isObserved && clock.now().seconds < expiry
                        })
                    guard self.alive(generation, flag) else {
                        self.onDiagnostic?(.staleResultDropped)
                        return
                    }
                    self.discardPending()
                    self.onDiagnostic?(.copyFinished(.copied))
                    self.showNotice(.copiedToClipboard, action: nil,
                                    displayID: nil)
                } catch {
                    guard self.alive(generation, flag) else {
                        self.onDiagnostic?(.staleResultDropped)
                        return
                    }
                    if self.pending?.isExpired(
                        atMonotonicSeconds: self.clock.now().seconds) == true {
                        self.discardPending()
                        self.onDiagnostic?(.copyFinished(.expired))
                        return
                    }
                    self.onDiagnostic?(.copyFinished(.writeFailed))
                    self.showNotice(.couldntInsert,
                                    action: .copyRecoveryTranscript,
                                    displayID: nil)
                }
            }
        }
    }

    func noticeDidExpire(_ notice: Notice) {
        if notice.action == .copyRecoveryTranscript {
            discardPending()
        }
        noticeResolved?(notice)
    }

    nonisolated func invalidateSynchronously() {
        invalidationSignal.cancel()
    }

    func discardPending() {
        invalidationSignal.cancel()
        pending = nil
        expiryTask?.cancel()
        expiryTask = nil
        epochFlag?.note()
        epochFlag = nil
        inFlight?.cancel()
        inFlight = nil
        epoch &+= 1
    }

    func shutdown() {
        discardPending()
    }

    private func alive(_ generation: UInt64, _ flag: CancellationFlag) -> Bool {
        epoch == generation && !flag.isObserved
    }

    private func captureSnapshotOutcome() async -> SnapshotOutcome {
        do {
            _ = try await clipboard.snapshot()
            return .safe
        } catch let error as ClipboardError {
            return SnapshotOutcome(error)
        } catch {
            return .unavailable
        }
    }

    private func apply(_ prepared: PreparedRecovery, text: String,
                       displayID: CGDirectDisplayID?) {
        switch prepared {
        case .copiedToClipboard:
            showNotice(.copiedToClipboard, action: nil, displayID: displayID)
        case .explicitCopy:
            storePending(text)
            showNotice(.couldntInsert, action: .copyRecoveryTranscript,
                       displayID: displayID)
        }
    }

    private func storePending(_ text: String) {
        let stored = PendingRecoveryTranscript(
            text: text, storedAtMonotonicSeconds: clock.now().seconds)
        pending = stored
        expiryTask?.cancel()
        expiryTask = Task { [weak self] in
            try? await Task.sleep(
                for: .seconds(PendingRecoveryTranscript.maximumLifetimeSeconds))
            guard let self, !Task.isCancelled else { return }
            guard self.pending == stored else { return }
            self.discardPending()
        }
    }

    private func showNotice(_ message: Notice.Message, action: Notice.Action?,
                            displayID: CGDirectDisplayID?) {
        onDiagnostic?(.presented(message))
        show(.init(message: message, action: action), displayID: displayID)
    }

    private func show(_ notice: Notice, displayID: CGDirectDisplayID?) {
        presentNotice?(notice, displayID)
    }
}

private final class RecoveryInvalidationSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var current: CancellationFlag?

    func install(_ flag: CancellationFlag) {
        lock.withLock {
            current?.note()
            current = flag
        }
    }

    func cancel() {
        lock.withLock { current?.note() }
    }
}
