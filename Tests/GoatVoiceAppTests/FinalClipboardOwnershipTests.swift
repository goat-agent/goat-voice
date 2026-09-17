import XCTest
import GoatVoicePlatform
@testable import GoatVoiceApp

@MainActor
final class FinalClipboardOwnershipTests: XCTestCase {
    func testSynchronousRecoveryInvalidationBlocksQueuedWrite() async throws {
        let board = GatedPasteboard()
        let recovery = RecoveryController(
            clipboard: ClipboardCoordinator(backend: board), clock: MonotonicClock())
        let invalidated = expectation(description: "Invalidated inside clipboard read")
        board.onNextChangeCountRead {
            recovery.invalidateSynchronously()
            invalidated.fulfill()
        }
        recovery.present(prepared: nil, transcript: "discard this",
                         release: ReleaseContext(finishReason: .microphoneDisconnected,
                                                 boundaryChangeCount: 1, target: nil),
                         displayID: nil)
        await fulfillment(of: [invalidated], timeout: 2)
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
