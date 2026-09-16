import XCTest
@testable import GoatVoiceCore

final class SessionMachineTests: XCTestCase {
    private func t(_ seconds: Double) -> MonotonicTime {
        MonotonicTime(seconds: seconds)
    }

    private func recordingMachine(start: Double = 0) -> (SessionMachine, SessionID) {
        var machine = SessionMachine()
        let id = SessionID()
        let effects = machine.handle(.triggerComplete(id), at: t(start))
        XCTAssertEqual(effects, [.startCapture(id), .blockNetwork])
        return (machine, id)
    }

    private func finishingMachine(start: Double = 0, release: Double = 5) -> (SessionMachine, SessionID) {
        var (machine, id) = recordingMachine(start: start)
        machine.handle(.triggerReleased, at: t(release))
        guard case .finishing = machine.state else {
            XCTFail("expected finishing")
            return (machine, id)
        }
        return (machine, id)
    }

    private func deliveringMachine(transcript: String = "hello") -> (SessionMachine, SessionID) {
        var (machine, id) = finishingMachine()
        machine.handle(.inferenceSucceeded(AttemptToken(sessionID: id), transcript: transcript), at: t(6))
        guard case .delivering = machine.state else {
            XCTFail("expected delivering")
            return (machine, id)
        }
        return (machine, id)
    }

    func testTriggerCompleteStartsRecording() {
        var machine = SessionMachine()
        let id = SessionID()
        let effects = machine.handle(.triggerComplete(id), at: t(10))
        XCTAssertEqual(effects, [.startCapture(id), .blockNetwork])
        guard case .recording(let context) = machine.state else {
            return XCTFail("expected recording")
        }
        XCTAssertEqual(context.sessionID, id)
        XCTAssertEqual(context.startTime, t(10))
        XCTAssertFalse(context.warningIssued)
    }

    func testNormalReleaseFinishesWithFloorDeadline() {
        var (machine, id) = recordingMachine()
        let effects = machine.handle(.triggerReleased, at: t(5))
        XCTAssertEqual(effects, [.stopCapture(id),
                                 .runInference(AttemptToken(sessionID: id)),
                                 .disarmTrigger])
        guard case .finishing(let context) = machine.state else {
            return XCTFail("expected finishing")
        }
        XCTAssertEqual(context.finishReason, .normalRelease)
        XCTAssertEqual(context.attempt, 0)
        XCTAssertEqual(context.deadline, t(35))
        XCTAssertEqual(machine.triggerGate, .disarmed)
    }

    func testPostReleaseDeadlineCeiling() {
        var (machine, id) = recordingMachine()
        machine.handle(.triggerReleased, at: t(400))
        guard case .finishing(let context) = machine.state else {
            return XCTFail("expected finishing")
        }
        XCTAssertEqual(context.audioDuration, 400)
        XCTAssertEqual(context.deadline, t(700))
        _ = id
    }

    func testWarningEmittedOnceAtNineteenMinutes() {
        var (machine, id) = recordingMachine()
        XCTAssertEqual(machine.advance(to: t(1139)), [])
        XCTAssertEqual(machine.advance(to: t(1140)), [.presentNotice(.recordingLimitWarning)])
        XCTAssertEqual(machine.advance(to: t(1150)), [])
        XCTAssertEqual(machine.advance(to: t(1199)), [])
        _ = id
    }

    func testHardCapForcesFinishAndRecovers() {
        var (machine, id) = recordingMachine()
        let effects = machine.advance(to: t(1200))
        XCTAssertEqual(effects, [.stopCapture(id),
                                 .runInference(AttemptToken(sessionID: id)),
                                 .disarmTrigger])
        guard case .finishing(let context) = machine.state else {
            return XCTFail("expected finishing")
        }
        XCTAssertEqual(context.finishReason, .recordingLimit)
        XCTAssertFalse(context.finishReason.permitsAutomaticInsertion)
        let delivery = machine.handle(.inferenceSucceeded(AttemptToken(sessionID: id), transcript: "text"),
                                      at: t(1201))
        XCTAssertEqual(delivery, [.recoverTranscript(AttemptToken(sessionID: id), transcript: "text"),
                                  .discardAudio(id),
                                  .unblockNetwork])
        XCTAssertEqual(machine.state, .idle)
    }

    func testReleaseBeyondCapCountsAsForcedFinish() {
        var (machine, id) = recordingMachine()
        let effects = machine.handle(.triggerReleased, at: t(1300))
        XCTAssertEqual(effects, [.stopCapture(id),
                                 .runInference(AttemptToken(sessionID: id)),
                                 .disarmTrigger])
        guard case .finishing(let context) = machine.state else {
            return XCTFail("expected finishing")
        }
        XCTAssertEqual(context.finishReason, .recordingLimit)
        XCTAssertEqual(context.finishTime, t(1200))
        XCTAssertEqual(context.deadline, t(1500))
        XCTAssertEqual(context.audioDuration, SessionMachine.recordingHardLimit)
    }

    func testTickBeyondAnchoredDeadlineDoesNotStartInference() {
        var (machine, id) = recordingMachine()
        let effects = machine.advance(to: t(1500))
        XCTAssertEqual(effects, [.stopCapture(id),
                                 .disarmTrigger,
                                 .presentNotice(.transcriptionFailed),
                                 .discardAudio(id),
                                 .unblockNetwork])
        XCTAssertEqual(machine.state, .idle)
        XCTAssertEqual(machine.handle(.inferenceSucceeded(AttemptToken(sessionID: id), transcript: "x"),
                                      at: t(1501)), [])
    }

    func testInvalidationPreemptsSimultaneousHardCap() {
        for reason in [InvalidationReason.escape, .lock, .sleep, .quit] {
            var (machine, id) = recordingMachine()
            let effects = machine.handle(.invalidate(reason), at: t(1200))
            XCTAssertEqual(effects, [.stopCapture(id),
                                     .disarmTrigger,
                                     .discardAudio(id),
                                     .unblockNetwork])
            XCTAssertEqual(machine.state, .idle)
        }
    }

    func testMicrophoneDisconnectFinishesWithoutPaste() {
        var (machine, id) = recordingMachine()
        let effects = machine.handle(.microphoneDisconnected, at: t(60))
        XCTAssertEqual(effects, [.stopCapture(id),
                                 .runInference(AttemptToken(sessionID: id)),
                                 .presentNotice(.microphoneDisconnected),
                                 .disarmTrigger])
        guard case .finishing(let context) = machine.state else {
            return XCTFail("expected finishing")
        }
        XCTAssertEqual(context.finishReason, .microphoneDisconnected)
        let delivery = machine.handle(.inferenceSucceeded(AttemptToken(sessionID: id), transcript: "kept"),
                                      at: t(61))
        XCTAssertEqual(delivery, [.recoverTranscript(AttemptToken(sessionID: id), transcript: "kept"),
                                  .discardAudio(id),
                                  .unblockNetwork])
    }

    func testEmptyTranscriptReturnsQuietlyToIdle() {
        var (machine, id) = finishingMachine()
        let effects = machine.handle(.inferenceSucceeded(AttemptToken(sessionID: id), transcript: "  \n"),
                                     at: t(6))
        XCTAssertEqual(effects, [.discardAudio(id), .unblockNetwork])
        XCTAssertEqual(machine.state, .idle)
    }

    func testEligibleTranscriptDeliversOnce() {
        var (machine, id) = finishingMachine()
        let token = AttemptToken(sessionID: id)
        let effects = machine.handle(.inferenceSucceeded(token, transcript: "hello"), at: t(6))
        XCTAssertEqual(effects, [.deliverTranscript(token, transcript: "hello")])
        guard case .delivering(let context) = machine.state else {
            return XCTFail("expected delivering")
        }
        XCTAssertEqual(context.token, token)
        let done = machine.handle(.pastePosted(token), at: t(6.5))
        XCTAssertEqual(done, [.discardAudio(id), .unblockNetwork])
        XCTAssertEqual(machine.state, .idle)
        XCTAssertEqual(machine.handle(.invalidate(.escape), at: t(7)), [])
        XCTAssertEqual(machine.handle(.inferenceSucceeded(token, transcript: "late"), at: t(7)), [])
    }

    func testInvalidateBeforePasteAbortsDelivery() {
        var (machine, id) = deliveringMachine()
        let effects = machine.handle(.invalidate(.escape), at: t(7))
        XCTAssertEqual(effects, [.abortDelivery(id), .discardAudio(id), .unblockNetwork])
        XCTAssertEqual(machine.state, .idle)
    }

    func testDeliveryAbortedFallsBackToRecovery() {
        var (machine, id) = deliveringMachine(transcript: "rescue me")
        let token = AttemptToken(sessionID: id)
        let effects = machine.handle(.deliveryAborted(token), at: t(7))
        XCTAssertEqual(effects, [.recoverTranscript(token, transcript: "rescue me"),
                                 .discardAudio(id),
                                 .unblockNetwork])
        XCTAssertEqual(machine.state, .idle)
    }

    func testTransientFailureRetriesOncePreservingDeadline() {
        var (machine, id) = finishingMachine()
        let first = AttemptToken(sessionID: id, attempt: 0)
        let retryEffects = machine.handle(.inferenceFailed(first, .transient), at: t(10))
        let retry = AttemptToken(sessionID: id, attempt: 1)
        XCTAssertEqual(retryEffects, [.runInference(retry)])
        guard case .finishing(let context) = machine.state else {
            return XCTFail("expected finishing")
        }
        XCTAssertEqual(context.attempt, 1)
        XCTAssertEqual(context.deadline, t(35))
        XCTAssertEqual(machine.handle(.inferenceSucceeded(first, transcript: "stale"), at: t(11)), [])
        let success = machine.handle(.inferenceSucceeded(retry, transcript: "fresh"), at: t(12))
        XCTAssertEqual(success, [.deliverTranscript(retry, transcript: "fresh")])
    }

    func testSecondTransientFailureDoesNotRetry() {
        var (machine, id) = finishingMachine()
        machine.handle(.inferenceFailed(AttemptToken(sessionID: id, attempt: 0), .transient), at: t(10))
        let effects = machine.handle(.inferenceFailed(AttemptToken(sessionID: id, attempt: 1), .transient),
                                     at: t(20))
        XCTAssertEqual(effects, [.presentNotice(.transcriptionFailed),
                                 .discardAudio(id),
                                 .unblockNetwork])
        XCTAssertEqual(machine.state, .idle)
    }

    func testDeterministicFailureNeverRetries() {
        var (machine, id) = finishingMachine()
        let effects = machine.handle(.inferenceFailed(AttemptToken(sessionID: id), .deterministic), at: t(6))
        XCTAssertEqual(effects, [.presentNotice(.transcriptionFailed),
                                 .discardAudio(id),
                                 .unblockNetwork])
        XCTAssertEqual(machine.state, .idle)
    }

    func testTransientFailureAtDeadlineDoesNotRetry() {
        var (machine, id) = finishingMachine()
        let effects = machine.handle(.inferenceFailed(AttemptToken(sessionID: id), .transient), at: t(34.5))
        XCTAssertEqual(effects, [.runInference(AttemptToken(sessionID: id, attempt: 1))])
    }

    func testTransientFailureAfterDeadlineExpiresSession() {
        var (machine, id) = finishingMachine()
        let effects = machine.handle(.inferenceFailed(AttemptToken(sessionID: id), .transient), at: t(35))
        XCTAssertEqual(effects, [.cancelInference(AttemptToken(sessionID: id)),
                                 .presentNotice(.transcriptionFailed),
                                 .discardAudio(id),
                                 .unblockNetwork])
        XCTAssertEqual(machine.state, .idle)
    }

    func testDeadlineExpiryInvalidatesLateResults() {
        var (machine, id) = finishingMachine()
        let expiry = machine.advance(to: t(36))
        XCTAssertEqual(expiry, [.cancelInference(AttemptToken(sessionID: id)),
                                .presentNotice(.transcriptionFailed),
                                .discardAudio(id),
                                .unblockNetwork])
        XCTAssertEqual(machine.state, .idle)
        XCTAssertEqual(machine.handle(.inferenceSucceeded(AttemptToken(sessionID: id), transcript: "late"),
                                      at: t(37)), [])
    }

    func testEventAtDeadlineTriggersExpiryFirst() {
        var (machine, id) = finishingMachine()
        let effects = machine.handle(.inferenceSucceeded(AttemptToken(sessionID: id), transcript: "late"),
                                     at: t(40))
        XCTAssertEqual(effects, [.cancelInference(AttemptToken(sessionID: id)),
                                 .presentNotice(.transcriptionFailed),
                                 .discardAudio(id),
                                 .unblockNetwork])
        XCTAssertEqual(machine.state, .idle)
    }

    func testStaleSessionAndAttemptResultsDropped() {
        var (machine, id) = finishingMachine()
        let other = AttemptToken(sessionID: SessionID(), attempt: 0)
        let future = AttemptToken(sessionID: id, attempt: 1)
        XCTAssertEqual(machine.handle(.inferenceSucceeded(other, transcript: "x"), at: t(6)), [])
        XCTAssertEqual(machine.handle(.inferenceFailed(future, .transient), at: t(6)), [])
        XCTAssertEqual(machine.handle(.pastePosted(other), at: t(6)), [])
        guard case .finishing = machine.state else {
            return XCTFail("expected finishing to survive stale input")
        }
    }

    func testExtraKeyCancelsRecordingAndIgnoresLaterRelease() {
        var (machine, id) = recordingMachine()
        let effects = machine.handle(.extraKeyPressed, at: t(3))
        XCTAssertEqual(effects, [.stopCapture(id),
                                 .disarmTrigger,
                                 .discardAudio(id),
                                 .unblockNetwork])
        XCTAssertEqual(machine.state, .idle)
        XCTAssertEqual(machine.handle(.triggerReleased, at: t(4)), [])
    }

    func testExtraKeyInvalidationReasonMatches() {
        var (machine, id) = recordingMachine()
        let effects = machine.handle(.invalidate(.extraKey), at: t(3))
        XCTAssertEqual(effects, [.stopCapture(id),
                                 .disarmTrigger,
                                 .discardAudio(id),
                                 .unblockNetwork])
        XCTAssertEqual(machine.state, .idle)
    }

    func testExtraKeyIgnoredWhileFinishing() {
        var (machine, _) = finishingMachine()
        XCTAssertEqual(machine.handle(.extraKeyPressed, at: t(6)), [])
        guard case .finishing = machine.state else {
            return XCTFail("expected finishing")
        }
    }

    func testLockDuringFinishingCancelsInferenceAndDropsLateResult() {
        var (machine, id) = finishingMachine()
        let effects = machine.handle(.invalidate(.lock), at: t(8))
        XCTAssertEqual(effects, [.cancelInference(AttemptToken(sessionID: id)),
                                 .discardAudio(id),
                                 .unblockNetwork])
        XCTAssertEqual(machine.state, .idle)
        XCTAssertEqual(machine.handle(.inferenceSucceeded(AttemptToken(sessionID: id), transcript: "x"),
                                      at: t(9)), [])
    }

    func testDeadlineInvalidationShowsFailureNotice() {
        var (machine, id) = finishingMachine()
        let effects = machine.handle(.invalidate(.deadline), at: t(9))
        XCTAssertEqual(effects, [.cancelInference(AttemptToken(sessionID: id)),
                                 .presentNotice(.transcriptionFailed),
                                 .discardAudio(id),
                                 .unblockNetwork])
    }

    func testSleepDuringRecordingDiscardsEverything() {
        var (machine, id) = recordingMachine()
        let effects = machine.handle(.invalidate(.sleep), at: t(30))
        XCTAssertEqual(effects, [.stopCapture(id),
                                 .disarmTrigger,
                                 .discardAudio(id),
                                 .unblockNetwork])
        XCTAssertEqual(machine.state, .idle)
    }

    func testCaptureFailurePresentsUnavailableNotice() {
        var (machine, id) = recordingMachine()
        let effects = machine.handle(.invalidate(.captureFailure), at: t(1))
        XCTAssertEqual(effects, [.stopCapture(id),
                                 .disarmTrigger,
                                 .presentNotice(.microphoneUnavailable),
                                 .discardAudio(id),
                                 .unblockNetwork])
        XCTAssertEqual(machine.state, .idle)
    }

    func testTriggerWhileActiveDisarmsWithoutNewSession() {
        var (machine, _) = recordingMachine()
        XCTAssertEqual(machine.handle(.triggerComplete(SessionID()), at: t(2)), [.disarmTrigger])
        guard case .recording = machine.state else {
            return XCTFail("expected recording")
        }
        var (finishing, _) = finishingMachine()
        XCTAssertEqual(finishing.handle(.triggerComplete(SessionID()), at: t(6)), [])
        guard case .finishing = finishing.state else {
            return XCTFail("expected finishing")
        }
    }

    func testHeldTriggerCannotRestartUntilFullyReleased() {
        var (machine, id) = deliveringMachine()
        machine.handle(.pastePosted(AttemptToken(sessionID: id)), at: t(7))
        XCTAssertEqual(machine.state, .idle)
        XCTAssertEqual(machine.triggerGate, .disarmed)
        XCTAssertEqual(machine.handle(.triggerComplete(SessionID()), at: t(8)), [])
        XCTAssertEqual(machine.state, .idle)
        XCTAssertEqual(machine.handle(.triggerFullyReleased, at: t(9)), [])
        XCTAssertEqual(machine.triggerGate, .armed)
        let next = SessionID()
        let effects = machine.handle(.triggerComplete(next), at: t(10))
        XCTAssertEqual(effects, [.startCapture(next), .blockNetwork])
        guard case .recording(let context) = machine.state else {
            return XCTFail("expected recording")
        }
        XCTAssertEqual(context.sessionID, next)
    }

    func testIdleIgnoresStrayEvents() {
        var machine = SessionMachine()
        let id = SessionID()
        XCTAssertEqual(machine.handle(.triggerReleased, at: t(0)), [])
        XCTAssertEqual(machine.handle(.microphoneDisconnected, at: t(0)), [])
        XCTAssertEqual(machine.handle(.invalidate(.escape), at: t(0)), [])
        XCTAssertEqual(machine.handle(.inferenceSucceeded(AttemptToken(sessionID: id), transcript: "x"),
                                      at: t(0)), [])
        XCTAssertEqual(machine.handle(.pastePosted(AttemptToken(sessionID: id)), at: t(0)), [])
        XCTAssertEqual(machine.handle(.deliveryAborted(AttemptToken(sessionID: id)), at: t(0)), [])
        XCTAssertEqual(machine.advance(to: t(5000)), [])
        XCTAssertEqual(machine.state, .idle)
    }
}
