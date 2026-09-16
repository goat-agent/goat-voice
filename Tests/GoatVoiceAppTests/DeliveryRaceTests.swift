import CoreGraphics
import Foundation
import GoatVoiceCore
import GoatVoicePlatform
import XCTest
@testable import GoatVoiceApp

final class ActorGate: @unchecked Sendable {
    private let lock = NSLock()
    private var triggerAt: Int?
    private var hits = 0
    private var open = false
    private var enteredValue = false
    var entered: Bool { lock.withLock { enteredValue } }

    func arm(afterCalls n: Int) {
        lock.withLock {
            triggerAt = n
            hits = 0
            open = false
            enteredValue = false
        }
    }

    func track() {
        lock.lock()
        hits += 1
        let blocks = triggerAt == hits && !open
        if blocks { enteredValue = true }
        lock.unlock()
        guard blocks else { return }
        while true {
            lock.lock()
            if open { lock.unlock(); return }
            lock.unlock()
            Thread.sleep(forTimeInterval: 0.005)
        }
    }

    func release() {
        lock.withLock { open = true }
    }
}

final class GatedPasteboard: PasteboardBackend, @unchecked Sendable {
    let gate = ActorGate()
    private let lock = NSLock()
    private var items: [[String: Data]] = [["public.utf8-plain-text": Data("seed".utf8)]]
    private var count = 1
    private var writes: [[[String: Data]]] = []

    var changeCount: Int {
        gate.track()
        return lock.withLock { count }
    }

    var itemCount: Int { lock.withLock { items.count } }

    func typeIdentifiers(ofItemAt index: Int) -> [String] {
        lock.withLock { Array(items[index].keys) }
    }

    func materializeData(itemAt index: Int, typeIdentifier: String) -> Data? {
        lock.withLock { items[index][typeIdentifier] }
    }

    func replaceItems(_ newItems: [[String: Data]]) -> PasteboardWriteResult {
        lock.withLock {
            items = newItems
            count += 1
            writes.append(newItems)
            return .success(changeCount: count)
        }
    }

    var writeCount: Int { lock.withLock { writes.count } }

    func userWrite(_ text: String) {
        _ = replaceItems([["public.utf8-plain-text": Data(text.utf8)]])
    }

    func plainText() -> String? {
        lock.withLock {
            items.first?["public.utf8-plain-text"].flatMap {
                String(data: $0, encoding: .utf8)
            }
        }
    }
}

@MainActor
final class DeliveryRaceTests: XCTestCase {
    @MainActor
    private final class Outcome {
        var posted = false
        var aborted: PreparedRecovery?
    }

    @MainActor
    private final class DeliveryHarness {
        let pasteboard = GatedPasteboard()
        let ax = FakeAccessibility()
        let poster = FakePoster()
        let latch = InterruptibilityLatch()
        let cancelFlag = CancellationFlag()
        let sessionSignal = CancellationFlag()
        let clipboard: ClipboardCoordinator
        let intentGuard: UserIntentGuard
        let resolver: TargetResolver
        let descriptor: TargetDescriptor

        init() {
            clipboard = ClipboardCoordinator(backend: pasteboard)
            resolver = TargetResolver(backend: ax, displayLookup: FakeDisplayLookup())
            intentGuard = UserIntentGuard(backend: ax, secureInputProbe: { false })
            latch.setInterruptible(true)
            descriptor = TargetDescriptor(
                elementToken: ax.token, windowID: 42,
                bundleIdentifier: "com.example.fake", displayID: 3,
                capturedAt: Date())
            intentGuard.begin(target: descriptor)
        }

        func makeTransaction(transcript: String = "hello world",
                             gateAfterDecision: Int? = nil) -> DeliveryTransaction {
            DeliveryTransaction(
                token: AttemptToken(sessionID: SessionID(), attempt: 0),
                transcript: transcript,
                release: ReleaseContext(
                    finishReason: .normalRelease,
                    boundaryChangeCount: 1,
                    target: descriptor),
                deps: DeliveryTransaction.Dependencies(
                    clipboard: clipboard,
                    accessibility: ax,
                    targetResolver: resolver,
                    intentGuard: intentGuard,
                    latch: latch,
                    cancelFlag: cancelFlag,
                    makeInserter: { [poster] in TextInserter(poster: poster) },
                    sessionIsValid: { [sessionSignal] in !sessionSignal.isObserved },
                    onDiagnostic: { [pasteboard] diagnostic in
                        if case .decision = diagnostic, let gateAfterDecision {
                            pasteboard.gate.arm(afterCalls: gateAfterDecision)
                        }
                    }))
        }
    }

    @MainActor
    private final class RecoveryHarness {
        let pasteboard = GatedPasteboard()
        let clockSource = ManualClockSource()
        let recovery: RecoveryController
        private(set) var notices: [Notice] = []

        init() {
            let clipboard = ClipboardCoordinator(backend: pasteboard)
            let clock = MonotonicClock(epoch: clockSource.epoch) { [clockSource] in
                clockSource.instant
            }
            recovery = RecoveryController(clipboard: clipboard, clock: clock)
            recovery.presentNotice = { [weak self] notice, _ in
                self?.notices.append(notice)
            }
        }
    }

    private func settle(timeout: TimeInterval = 4,
                        until predicate: @escaping @MainActor () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return true }
            try? await Task.sleep(for: .milliseconds(15))
        }
        return predicate()
    }

    func testInvalidateInsideTempWriteBlocksMutationAndPaste() async throws {
        let harness = DeliveryHarness()
        let outcome = Outcome()
        let tx = harness.makeTransaction(gateAfterDecision: 2)
        tx.onPosted = { outcome.posted = true }
        tx.onAborted = { outcome.aborted = $0 }
        let run = Task { await tx.run() }

        let gateEntered = await settle { harness.pasteboard.gate.entered }
        XCTAssertTrue(gateEntered)
        tx.abort()
        harness.pasteboard.gate.release()
        await run.value

        XCTAssertEqual(harness.pasteboard.writeCount, 0)
        XCTAssertEqual(harness.pasteboard.plainText(), "seed")
        XCTAssertTrue(harness.poster.postedPIDs.isEmpty)
        XCTAssertFalse(outcome.posted)
    }

    func testInvalidateDuringSnapshotPreventsAnyWrite() async throws {
        let harness = DeliveryHarness()
        let outcome = Outcome()
        let tx = harness.makeTransaction()
        tx.onPosted = { outcome.posted = true }
        tx.onAborted = { outcome.aborted = $0 }
        harness.pasteboard.gate.arm(afterCalls: 1)
        let run = Task { await tx.run() }

        let gateEntered = await settle { harness.pasteboard.gate.entered }
        XCTAssertTrue(gateEntered)
        tx.abort()
        harness.pasteboard.gate.release()
        await run.value

        XCTAssertEqual(harness.pasteboard.writeCount, 0)
        XCTAssertTrue(harness.poster.postedPIDs.isEmpty)
        XCTAssertFalse(outcome.posted)
        XCTAssertNil(outcome.aborted)
    }

    func testUserClipboardMutationInGapPreservesNewerClipboard() async throws {
        let harness = DeliveryHarness()
        let outcome = Outcome()
        let tx = harness.makeTransaction(gateAfterDecision: 1)
        tx.onPosted = { outcome.posted = true }
        tx.onAborted = { outcome.aborted = $0 }
        let run = Task { await tx.run() }

        let gateEntered = await settle { harness.pasteboard.gate.entered }
        XCTAssertTrue(gateEntered)
        harness.pasteboard.userWrite("user data")
        harness.pasteboard.gate.release()
        await run.value

        XCTAssertEqual(harness.pasteboard.plainText(), "user data")
        XCTAssertTrue(harness.poster.postedPIDs.isEmpty)
        XCTAssertEqual(outcome.aborted, .explicitCopy(.newerClipboard))
    }

    func testTargetChangeInsideActorBlocksPost() async throws {
        let harness = DeliveryHarness()
        let outcome = Outcome()
        let tx = harness.makeTransaction(gateAfterDecision: 3)
        tx.onPosted = { outcome.posted = true }
        tx.onAborted = { outcome.aborted = $0 }
        let run = Task { await tx.run() }

        let gateEntered = await settle { harness.pasteboard.gate.entered }
        XCTAssertTrue(gateEntered)
        harness.ax.sameTarget = false
        harness.pasteboard.gate.release()
        await run.value

        XCTAssertTrue(harness.poster.postedPIDs.isEmpty)
        XCTAssertFalse(outcome.posted)
        XCTAssertEqual(outcome.aborted, .copiedToClipboard)
        XCTAssertEqual(harness.pasteboard.plainText(), "hello world")
    }

    func testAbortAtPostGateRestoresTemporaryTranscript() async throws {
        let harness = DeliveryHarness()
        let outcome = Outcome()
        let tx = harness.makeTransaction(gateAfterDecision: 3)
        tx.onPosted = { outcome.posted = true }
        tx.onAborted = { outcome.aborted = $0 }
        let run = Task { await tx.run() }

        let gateEntered = await settle { harness.pasteboard.gate.entered }
        XCTAssertTrue(gateEntered)
        tx.abort()
        harness.pasteboard.gate.release()
        await run.value

        XCTAssertTrue(harness.poster.postedPIDs.isEmpty)
        XCTAssertFalse(outcome.posted)
        let restored = await settle { harness.pasteboard.plainText() == "seed" }
        XCTAssertTrue(restored)
    }

    func testSessionInvalidationInsideActorBlocksWrite() async throws {
        let harness = DeliveryHarness()
        let outcome = Outcome()
        let tx = harness.makeTransaction(gateAfterDecision: 2)
        tx.onPosted = { outcome.posted = true }
        tx.onAborted = { outcome.aborted = $0 }
        let run = Task { await tx.run() }

        let gateEntered = await settle { harness.pasteboard.gate.entered }
        XCTAssertTrue(gateEntered)
        harness.sessionSignal.note()
        harness.pasteboard.gate.release()
        await run.value

        XCTAssertEqual(harness.pasteboard.writeCount, 0)
        XCTAssertEqual(harness.pasteboard.plainText(), "seed")
        XCTAssertTrue(harness.poster.postedPIDs.isEmpty)
    }

    func testEmptyTranscriptPerformsNoWriteOrPaste() async throws {
        let harness = DeliveryHarness()
        let outcome = Outcome()
        let tx = harness.makeTransaction(transcript: "\u{7}\u{1F}\u{8}")
        tx.onPosted = { outcome.posted = true }
        tx.onAborted = { outcome.aborted = $0 }
        await tx.run()

        XCTAssertEqual(harness.pasteboard.writeCount, 0)
        XCTAssertTrue(harness.poster.postedPIDs.isEmpty)
        XCTAssertFalse(outcome.posted)
        XCTAssertNotNil(outcome.aborted)
    }

    func testFailedPostReportsCopiedNotDelivered() async throws {
        let harness = DeliveryHarness()
        harness.poster.succeeds = false
        let outcome = Outcome()
        let tx = harness.makeTransaction()
        tx.onPosted = { outcome.posted = true }
        tx.onAborted = { outcome.aborted = $0 }
        await tx.run()

        XCTAssertEqual(harness.poster.postedPIDs.count, 1)
        XCTAssertFalse(outcome.posted)
        XCTAssertEqual(outcome.aborted, .copiedToClipboard)
        XCTAssertEqual(harness.pasteboard.plainText(), "hello world")
    }

    func testReplacedPendingSurvivesCancelledExpiry() async throws {
        let harness = RecoveryHarness()
        harness.recovery.present(
            prepared: .explicitCopy(.newerClipboard),
            transcript: "alpha", release: nil, displayID: nil)
        harness.recovery.present(
            prepared: .explicitCopy(.newerClipboard),
            transcript: "bravo", release: nil, displayID: nil)
        try? await Task.sleep(for: .milliseconds(150))

        harness.recovery.performRecoveryAction(.copyRecoveryTranscript)
        let copied = await settle { harness.pasteboard.plainText() == "bravo" }
        XCTAssertTrue(copied)
    }

    func testStalePresentTaskCannotWriteAfterDiscard() async throws {
        let harness = RecoveryHarness()
        harness.pasteboard.gate.arm(afterCalls: 1)
        harness.recovery.present(
            prepared: nil, transcript: "stale", release: nil, displayID: nil)

        let gateEntered = await settle { harness.pasteboard.gate.entered }
        XCTAssertTrue(gateEntered)
        harness.recovery.discardPending()
        harness.pasteboard.gate.release()
        try? await Task.sleep(for: .milliseconds(150))

        XCTAssertEqual(harness.pasteboard.writeCount, 0)
        XCTAssertTrue(harness.notices.isEmpty)
    }

    func testRecoveryWriteInsideActorRejectedAfterDiscard() async throws {
        let harness = RecoveryHarness()
        harness.recovery.onDiagnostic = { [pasteboard = harness.pasteboard] diagnostic in
            if case .decision = diagnostic { pasteboard.gate.arm(afterCalls: 2) }
        }
        harness.recovery.present(
            prepared: nil, transcript: "delta",
            release: ReleaseContext(
                finishReason: .microphoneDisconnected,
                boundaryChangeCount: 1, target: nil),
            displayID: nil)

        let gateEntered = await settle { harness.pasteboard.gate.entered }
        XCTAssertTrue(gateEntered)
        harness.recovery.discardPending()
        harness.pasteboard.gate.release()
        try? await Task.sleep(for: .milliseconds(150))

        XCTAssertEqual(harness.pasteboard.writeCount, 0)
        XCTAssertTrue(harness.notices.isEmpty)
    }

    func testExplicitCopyLateCompletionDropsAfterNewerRecovery() async throws {
        let harness = RecoveryHarness()
        harness.recovery.present(
            prepared: .explicitCopy(.newerClipboard),
            transcript: "bravo", release: nil, displayID: nil)
        harness.pasteboard.gate.arm(afterCalls: 1)
        harness.recovery.performRecoveryAction(.copyRecoveryTranscript)

        let gateEntered = await settle { harness.pasteboard.gate.entered }
        XCTAssertTrue(gateEntered)
        harness.recovery.present(
            prepared: .explicitCopy(.newerClipboard),
            transcript: "charlie", release: nil, displayID: nil)
        harness.pasteboard.gate.release()
        try? await Task.sleep(for: .milliseconds(150))

        XCTAssertEqual(harness.pasteboard.writeCount, 0)
        XCTAssertFalse(harness.notices.contains { $0.message == .copiedToClipboard })

        harness.recovery.performRecoveryAction(.copyRecoveryTranscript)
        let copied = await settle { harness.pasteboard.plainText() == "charlie" }
        XCTAssertTrue(copied)
    }

    func testExpiredPendingCopyDoesNotWrite() async throws {
        let harness = RecoveryHarness()
        harness.recovery.present(
            prepared: .explicitCopy(.newerClipboard),
            transcript: "echo", release: nil, displayID: nil)
        harness.clockSource.advance(by: .seconds(31))
        harness.recovery.performRecoveryAction(.copyRecoveryTranscript)
        try? await Task.sleep(for: .milliseconds(150))

        XCTAssertEqual(harness.pasteboard.writeCount, 0)
    }

    func testNormalDeliveryStillPastesAndRestores() async throws {
        let harness = DeliveryHarness()
        let outcome = Outcome()
        let tx = harness.makeTransaction()
        tx.onPosted = { outcome.posted = true }
        tx.onAborted = { outcome.aborted = $0 }
        await tx.run()

        XCTAssertTrue(outcome.posted)
        XCTAssertNil(outcome.aborted)
        XCTAssertEqual(harness.poster.postedPIDs, [4242])
        XCTAssertEqual(harness.pasteboard.plainText(), "hello world")

        let restored = await settle { harness.pasteboard.plainText() == "seed" }
        XCTAssertTrue(restored)
    }
}
