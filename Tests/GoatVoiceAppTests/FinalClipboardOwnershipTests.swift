import XCTest
import GoatVoicePlatform
@testable import GoatVoiceApp

@MainActor
final class FinalClipboardOwnershipTests: XCTestCase {
    func testSynchronousRecoveryInvalidationBlocksQueuedWrite() async throws {
        let board = GatedPasteboard()
        let recovery = RecoveryController(
            clipboard: ClipboardCoordinator(backend: board), clock: MonotonicClock())
        board.gate.arm(afterCalls: 1)
        recovery.present(prepared: nil, transcript: "discard this",
                         release: ReleaseContext(finishReason: .microphoneDisconnected,
                                                 boundaryChangeCount: 1, target: nil),
                         displayID: nil)
        for _ in 0..<100 {
            if board.gate.entered { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(board.gate.entered)
        recovery.invalidateSynchronously()
        board.gate.release()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(board.writeCount, 0)
        XCTAssertEqual(board.plainText(), "seed")
        recovery.shutdown()
    }

    func testUserCopyDuringTargetValidationPreventsPaste() async throws {
        let board = GatedPasteboard()
        let clipboard = ClipboardCoordinator(backend: board)
        let fence = try await clipboard.writeTemporaryTranscript("dictation")
        let poster = FakePoster()
        let outcome = await clipboard.postPasteIfFenced(
            fence, to: 42, using: TextInserter(poster: poster),
            validatedBy: {
                board.userWrite("new user clipboard")
                return true
            })
        XCTAssertEqual(outcome, .clipboardOwnershipLost)
        XCTAssertTrue(poster.postedPIDs.isEmpty)
        XCTAssertEqual(board.plainText(), "new user clipboard")
    }
}
