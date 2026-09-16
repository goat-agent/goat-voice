import XCTest
import GoatVoicePlatform
@testable import GoatVoiceApp

final class RecoveryClipboardContinuityTests: XCTestCase {
    func testOwnRecoveryCopyDoesNotDisableNextDictation() async throws {
        let board = FakePasteboard()
        let clipboard = ClipboardCoordinator(backend: board)
        _ = try await clipboard.writeRecoveryCopy("previous dictation")
        let snapshot = try await clipboard.snapshot()
        XCTAssertEqual(snapshot.changeCount, board.changeCount)
        XCTAssertEqual(board.plainText(), "previous dictation")
    }

    func testRestoringOwnRecoveryCopyPreservesOwnershipForFollowingSession() async throws {
        let board = FakePasteboard()
        let clipboard = ClipboardCoordinator(backend: board)
        _ = try await clipboard.writeRecoveryCopy("previous dictation")
        let snapshot = try await clipboard.snapshot()
        let temporary = try await clipboard.writeTemporaryTranscript("next dictation")
        let restored = await clipboard.restore(snapshot, guardedBy: temporary)
        XCTAssertEqual(restored, .restored)
        _ = try await clipboard.snapshot()
        XCTAssertEqual(board.plainText(), "previous dictation")
    }

    func testForeignConcealedClipboardRemainsProtectedAfterOwnCopy() async throws {
        let board = FakePasteboard()
        let clipboard = ClipboardCoordinator(backend: board)
        _ = try await clipboard.writeRecoveryCopy("previous dictation")
        _ = board.replaceItems([[
            "public.utf8-plain-text": Data("private fixture".utf8),
            "org.nspasteboard.ConcealedType": Data(),
        ]])
        do {
            _ = try await clipboard.snapshot()
            XCTFail("Foreign concealed clipboard must not be considered owned")
        } catch {
            XCTAssertEqual(error as? ClipboardError, .snapshotUnavailable)
        }
        XCTAssertEqual(board.plainText(), "private fixture")
    }
}
