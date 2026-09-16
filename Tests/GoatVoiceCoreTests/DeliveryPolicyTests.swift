import Foundation
import XCTest
@testable import GoatVoiceCore

final class DeliveryPolicyTests: XCTestCase {
    private func context(
        finishReason: FinishReason = .normalRelease,
        snapshot: SnapshotSafety = .safe,
        target: TargetIdentity = .sameEditableField,
        intent: IntentVerdict = .unmutated,
        boundaryChangeCount: Int = 10,
        currentChangeCount: Int = 10
    ) -> DeliveryContext {
        DeliveryContext(
            finishReason: finishReason,
            snapshot: snapshot,
            target: target,
            intent: intent,
            boundaryChangeCount: boundaryChangeCount,
            currentChangeCount: currentChangeCount
        )
    }

    private func prePaste(
        target: TargetIdentity = .sameEditableField,
        intent: IntentVerdict = .unmutated,
        temporaryChangeCount: Int = 20,
        currentChangeCount: Int = 20,
        pasteAlreadyAttempted: Bool = false
    ) -> PrePasteContext {
        PrePasteContext(
            target: target,
            intent: intent,
            temporaryChangeCount: temporaryChangeCount,
            currentChangeCount: currentChangeCount,
            pasteAlreadyAttempted: pasteAlreadyAttempted
        )
    }

    func testCleanNormalReleaseAllowsPasteSequence() {
        XCTAssertEqual(DeliveryPolicy.decision(for: context()), .pasteSequence)
    }

    func testClipboardChangeBeforeTemporaryWriteStillPastes() {
        XCTAssertEqual(
            DeliveryPolicy.decision(
                for: context(boundaryChangeCount: 10, currentChangeCount: 12)
            ),
            .pasteSequence
        )
    }

    func testUnsafeSnapshotForcesExplicitCopy() {
        XCTAssertEqual(
            DeliveryPolicy.decision(for: context(snapshot: .unsafe)),
            .explicitCopy(.unsafeSnapshot)
        )
    }

    func testUnsafeSnapshotOverridesEveryOtherPath() {
        XCTAssertEqual(
            DeliveryPolicy.decision(
                for: context(
                    finishReason: .microphoneDisconnected,
                    snapshot: .unsafe,
                    target: .untrusted,
                    intent: .untrusted,
                    currentChangeCount: 99
                )
            ),
            .explicitCopy(.unsafeSnapshot)
        )
    }

    func testForcedFinishNeverPastes() {
        XCTAssertEqual(
            DeliveryPolicy.decision(
                for: context(finishReason: .microphoneDisconnected)
            ),
            .copyTranscript
        )
        XCTAssertEqual(
            DeliveryPolicy.decision(for: context(finishReason: .recordingLimit)),
            .copyTranscript
        )
    }

    func testTargetMismatchRecoversByCopy() {
        XCTAssertEqual(
            DeliveryPolicy.decision(for: context(target: .mismatch)),
            .copyTranscript
        )
    }

    func testUntrustedTargetRecoversByCopy() {
        XCTAssertEqual(
            DeliveryPolicy.decision(for: context(target: .untrusted)),
            .copyTranscript
        )
    }

    func testMutatedIntentRecoversByCopy() {
        XCTAssertEqual(
            DeliveryPolicy.decision(for: context(intent: .mutated)),
            .copyTranscript
        )
    }

    func testUntrustedIntentRecoversByCopy() {
        XCTAssertEqual(
            DeliveryPolicy.decision(for: context(intent: .untrusted)),
            .copyTranscript
        )
    }

    func testNewerClipboardRequiresExplicitCopy() {
        XCTAssertEqual(
            DeliveryPolicy.decision(
                for: context(target: .mismatch, currentChangeCount: 11)
            ),
            .explicitCopy(.newerClipboard)
        )
        XCTAssertEqual(
            DeliveryPolicy.decision(
                for: context(
                    finishReason: .recordingLimit,
                    currentChangeCount: 42
                )
            ),
            .explicitCopy(.newerClipboard)
        )
    }

    func testPrePasteAllClearPostsPaste() {
        XCTAssertEqual(
            DeliveryPolicy.prePasteDecision(for: prePaste()),
            .postPaste
        )
    }

    func testPrePasteOwnershipRacePreservesNewer() {
        XCTAssertEqual(
            DeliveryPolicy.prePasteDecision(
                for: prePaste(temporaryChangeCount: 20, currentChangeCount: 21)
            ),
            .preserveNewerClipboard
        )
    }

    func testPrePasteOwnershipLossDominatesTargetFailure() {
        XCTAssertEqual(
            DeliveryPolicy.prePasteDecision(
                for: prePaste(
                    target: .mismatch,
                    intent: .mutated,
                    currentChangeCount: 21
                )
            ),
            .preserveNewerClipboard
        )
    }

    func testPrePasteTargetFailureKeepsTranscript() {
        XCTAssertEqual(
            DeliveryPolicy.prePasteDecision(for: prePaste(target: .mismatch)),
            .keepTranscript
        )
        XCTAssertEqual(
            DeliveryPolicy.prePasteDecision(for: prePaste(target: .untrusted)),
            .keepTranscript
        )
    }

    func testPrePasteMutationKeepsTranscript() {
        XCTAssertEqual(
            DeliveryPolicy.prePasteDecision(for: prePaste(intent: .mutated)),
            .keepTranscript
        )
        XCTAssertEqual(
            DeliveryPolicy.prePasteDecision(for: prePaste(intent: .untrusted)),
            .keepTranscript
        )
    }

    func testPrePasteNeverPostsTwice() {
        XCTAssertEqual(
            DeliveryPolicy.prePasteDecision(
                for: prePaste(pasteAlreadyAttempted: true)
            ),
            .alreadyAttempted
        )
        XCTAssertEqual(
            DeliveryPolicy.prePasteDecision(
                for: prePaste(
                    currentChangeCount: 21,
                    pasteAlreadyAttempted: true
                )
            ),
            .alreadyAttempted
        )
    }

    func testRestoreWhenOwnedAndPastePosted() {
        let context = RestoreContext(
            temporaryChangeCount: 20,
            currentChangeCount: 20,
            pastePosted: true
        )
        XCTAssertEqual(
            DeliveryPolicy.restoreDecision(for: context),
            .restoreSnapshot
        )
    }

    func testRestoreNeverOverwritesNewerClipboard() {
        let context = RestoreContext(
            temporaryChangeCount: 20,
            currentChangeCount: 25,
            pastePosted: true
        )
        XCTAssertEqual(
            DeliveryPolicy.restoreDecision(for: context),
            .preserveNewerClipboard
        )
    }

    func testRestoreKeepsTranscriptWhenPasteNotPosted() {
        let context = RestoreContext(
            temporaryChangeCount: 20,
            currentChangeCount: 20,
            pastePosted: false
        )
        XCTAssertEqual(
            DeliveryPolicy.restoreDecision(for: context),
            .keepTranscript
        )
    }

    func testRestorePreservesNewerEvenWithoutPaste() {
        let context = RestoreContext(
            temporaryChangeCount: 20,
            currentChangeCount: 21,
            pastePosted: false
        )
        XCTAssertEqual(
            DeliveryPolicy.restoreDecision(for: context),
            .preserveNewerClipboard
        )
    }

    func testPasteSequenceFlowEndToEnd() {
        XCTAssertEqual(
            DeliveryPolicy.decision(for: context()),
            .pasteSequence
        )
        XCTAssertEqual(
            DeliveryPolicy.prePasteDecision(
                for: prePaste(temporaryChangeCount: 21, currentChangeCount: 21)
            ),
            .postPaste
        )
        let restore = RestoreContext(
            temporaryChangeCount: 21,
            currentChangeCount: 21,
            pastePosted: true
        )
        XCTAssertEqual(
            DeliveryPolicy.restoreDecision(for: restore),
            .restoreSnapshot
        )
    }

    func testRecoveryTranscriptExpiresAtThirtySeconds() {
        let pending = PendingRecoveryTranscript(
            text: "x",
            storedAtMonotonicSeconds: 100
        )
        XCTAssertFalse(pending.isExpired(atMonotonicSeconds: 99))
        XCTAssertFalse(pending.isExpired(atMonotonicSeconds: 129.999))
        XCTAssertTrue(pending.isExpired(atMonotonicSeconds: 130))
        XCTAssertTrue(pending.isExpired(atMonotonicSeconds: 500))
        XCTAssertEqual(PendingRecoveryTranscript.maximumLifetimeSeconds, 30)
    }
}
