import XCTest
@testable import GoatVoicePlatform

final class FakePasteboardBackend: PasteboardBackend, @unchecked Sendable {
    private struct State {
        var items: [[String: Data]] = []
        var changeCount = 0
        var materializeCalls = 0
        var onMaterialize: (() -> Void)?
        var failWrites = false
    }

    private var state = State()
    private let lock = NSLock()

    private func withState<T>(_ body: (inout State) throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body(&state)
    }

    var items: [[String: Data]] {
        get { withState { $0.items } }
        set { withState { $0.items = newValue } }
    }

    var itemCount: Int { withState { $0.items.count } }
    var changeCount: Int { withState { $0.changeCount } }
    var materializeCalls: Int { withState { $0.materializeCalls } }

    var onMaterialize: (() -> Void)? {
        get { withState { $0.onMaterialize } }
        set { withState { $0.onMaterialize = newValue } }
    }

    var failWrites: Bool {
        get { withState { $0.failWrites } }
        set { withState { $0.failWrites = newValue } }
    }

    func typeIdentifiers(ofItemAt index: Int) -> [String] {
        withState { state in
            guard state.items.indices.contains(index) else { return [] }
            return state.items[index].keys.sorted()
        }
    }

    func materializeData(itemAt index: Int, typeIdentifier: String) -> Data? {
        let callback = withState { $0.onMaterialize }
        callback?()
        return withState { state in
            state.materializeCalls += 1
            guard state.items.indices.contains(index) else { return nil }
            return state.items[index][typeIdentifier]
        }
    }

    func replaceItems(_ newItems: [[String: Data]]) -> PasteboardWriteResult {
        withState { state in
            state.items = []
            state.changeCount += 1
            guard !state.failWrites else { return .rejected }
            state.items = newItems
            return .success(changeCount: state.changeCount)
        }
    }

    func foreignWrite(_ item: [String: Data]) {
        withState { state in
            state.items = [item]
            state.changeCount += 1
        }
    }
}

final class RecordingPastePoster: PasteEventPosting, @unchecked Sendable {
    private var state = (postCount: 0, result: true)
    private let lock = NSLock()

    var postCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return state.postCount
    }

    var result: Bool {
        get {
            lock.lock()
            defer { lock.unlock() }
            return state.result
        }
        set {
            lock.lock()
            state.result = newValue
            lock.unlock()
        }
    }

    func postPaste(to pid: pid_t) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        state.postCount += 1
        return state.result
    }
}

final class ClipboardCoordinatorTests: XCTestCase {
    private var backend: FakePasteboardBackend!
    private var coordinator: ClipboardCoordinator!
    private let stringType = "public.utf8-plain-text"

    override func setUp() {
        backend = FakePasteboardBackend()
        coordinator = ClipboardCoordinator(backend: backend, snapshotLimit: 1_024)
    }

    private func seed(_ items: [[String: Data]]) {
        backend.items = items
        _ = backend.replaceItems(items)
    }

    func testSnapshotCapturesAllItemsAndTypes() async throws {
        seed([
            [stringType: Data("hello".utf8), "public.png": Data(repeating: 7, count: 40)],
            [stringType: Data("second".utf8)],
        ])
        let snapshot = try await coordinator.snapshot()
        XCTAssertEqual(snapshot.items.count, 2)
        XCTAssertEqual(snapshot.items[0][stringType], Data("hello".utf8))
        XCTAssertEqual(snapshot.items[0]["public.png"]?.count, 40)
        XCTAssertEqual(snapshot.materializedBytes, 5 + 40 + 6)
    }

    func testSnapshotEmptyClipboard() async throws {
        let snapshot = try await coordinator.snapshot()
        XCTAssertEqual(snapshot.items, [])
        XCTAssertEqual(snapshot.materializedBytes, 0)
    }

    func testSnapshotAbortsAtBoundDuringMaterialization() async {
        seed([
            [stringType: Data(repeating: 1, count: 900)],
            [stringType: Data(repeating: 2, count: 900)],
            [stringType: Data(repeating: 3, count: 10)],
        ])
        do {
            _ = try await coordinator.snapshot()
            XCTFail("expected snapshotExceedsLimit")
        } catch ClipboardError.snapshotExceedsLimit(let limit) {
            XCTAssertEqual(limit, 1_024)
            XCTAssertEqual(backend.materializeCalls, 2)
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testPromisedTypeFailsSnapshotBeforeMaterializing() async {
        seed([[stringType: Data("x".utf8), "com.apple.pasteboard.promised-file-url": Data()]])
        do {
            _ = try await coordinator.snapshot()
            XCTFail("expected promisedContentUnavailable")
        } catch ClipboardError.promisedContentUnavailable {
            XCTAssertLessThanOrEqual(backend.materializeCalls, 1)
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testForeignConcealedClipboardIsNotSnapshotted() async {
        seed([[stringType: Data("fixture".utf8), "org.nspasteboard.ConcealedType": Data()]])
        do {
            _ = try await coordinator.snapshot()
            XCTFail("Foreign concealed data must remain protected")
        } catch {
            XCTAssertEqual(error as? ClipboardError, .snapshotUnavailable)
        }
    }

    func testMissingTypeDataFailsSnapshot() async {
        backend.items = [[stringType: Data("a".utf8), "com.fake.vanishing": Data()]]
        backend.onMaterialize = { [weak self] in
            self?.backend.items[0].removeValue(forKey: "com.fake.vanishing")
        }
        await XCTAssertThrowsErrorAsync(try await coordinator.snapshot())
    }

    func testForeignWriteDuringSnapshotIsRejected() async {
        backend.items = [[stringType: Data("a".utf8), "public.png": Data(repeating: 1, count: 4)]]
        backend.onMaterialize = { [weak self] in
            self?.backend.foreignWrite(["public.utf8-plain-text": Data("b".utf8)])
        }
        await XCTAssertThrowsErrorAsync(try await coordinator.snapshot())
    }

    func testTemporaryTranscriptWriteProducesFenceAndMarkers() async throws {
        seed([[stringType: Data("user data".utf8)]])
        let fence = try await coordinator.writeTemporaryTranscript("dictated text")
        let currentCount = await coordinator.currentChangeCount()
        XCTAssertEqual(fence.changeCount, currentCount)
        let board = backend.items
        XCTAssertEqual(board.count, 1)
        XCTAssertEqual(board[0][stringType], Data("dictated text".utf8))
        for marker in ClipboardDefaults.transientMarkers {
            XCTAssertNotNil(board[0][marker])
        }
        let intact = await coordinator.fenceIntact(fence)
        XCTAssertTrue(intact)
    }

    func testFailedWriteThrows() async {
        backend.failWrites = true
        do {
            _ = try await coordinator.writeTemporaryTranscript("t")
            XCTFail("expected writeFailed")
        } catch ClipboardError.writeFailed {
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testRejectedRestoreIsReported() async throws {
        seed([[stringType: Data("original".utf8)]])
        let snapshot = try await coordinator.snapshot()
        let fence = try await coordinator.writeTemporaryTranscript("t")
        backend.failWrites = true
        let outcome = await coordinator.restore(snapshot, guardedBy: fence)
        XCTAssertEqual(outcome, .restoreFailed)
    }

    func testWriteVerifyCatchesForeignInterleave() async {
        backend.onMaterialize = { [weak self] in
            self?.backend.items = [["public.utf8-plain-text": Data("foreign".utf8)]]
        }
        await XCTAssertThrowsErrorAsync(try await coordinator.writeTemporaryTranscript("dictated"))
    }

    func testFenceBreaksOnForeignWrite() async throws {
        let fence = try await coordinator.writeTemporaryTranscript("t")
        backend.foreignWrite([stringType: Data("newer".utf8)])
        let intact = await coordinator.fenceIntact(fence)
        XCTAssertFalse(intact)
    }

    func testRestoreOnlyWhenFenceIntact() async throws {
        seed([[stringType: Data("original".utf8), "public.png": Data(repeating: 9, count: 8)]])
        let snapshot = try await coordinator.snapshot()
        let fence = try await coordinator.writeTemporaryTranscript("transcript")

        let outcome = await coordinator.restore(snapshot, guardedBy: fence)
        XCTAssertEqual(outcome, .restored)
        XCTAssertEqual(backend.items.count, 1)
        XCTAssertEqual(backend.items[0][stringType], Data("original".utf8))
        XCTAssertEqual(backend.items[0]["public.png"]?.count, 8)
    }

    func testRestoreNeverOverwritesNewerClipboard() async throws {
        seed([[stringType: Data("original".utf8)]])
        let snapshot = try await coordinator.snapshot()
        let fence = try await coordinator.writeTemporaryTranscript("transcript")
        backend.foreignWrite([stringType: Data("user copied".utf8)])

        let outcome = await coordinator.restore(snapshot, guardedBy: fence)
        XCTAssertEqual(outcome, .ownershipPreserved)
        XCTAssertEqual(backend.items[0][stringType], Data("user copied".utf8))
    }

    func testRecoveryCopyWrites() async throws {
        let fence = try await coordinator.writeRecoveryCopy("recovered text")
        let intact = await coordinator.fenceIntact(fence)
        XCTAssertTrue(intact)
        XCTAssertEqual(backend.items[0][stringType], Data("recovered text".utf8))
    }

    func testTemporaryWriteLeavesTransientResidue() async throws {
        seed([[stringType: Data("user data".utf8)]])
        _ = try await coordinator.writeTemporaryTranscript("temp")
        let hasResidue = await coordinator.hasTransientResidue()
        XCTAssertTrue(hasResidue)
        do {
            _ = try await coordinator.snapshot()
            XCTFail("expected transientResidue")
        } catch ClipboardError.transientResidue {
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testForeignWriteClearsResidue() async throws {
        seed([[stringType: Data("user data".utf8)]])
        _ = try await coordinator.writeTemporaryTranscript("temp")
        backend.foreignWrite([stringType: Data("foreign".utf8)])
        let hasResidue = await coordinator.hasTransientResidue()
        XCTAssertFalse(hasResidue)
        let snapshot = try await coordinator.snapshot()
        XCTAssertEqual(snapshot.items[0][stringType], Data("foreign".utf8))
    }

    func testRestoreClearsResidue() async throws {
        seed([[stringType: Data("original".utf8)]])
        let snapshot = try await coordinator.snapshot()
        let fence = try await coordinator.writeTemporaryTranscript("temp")
        let outcome = await coordinator.restore(snapshot, guardedBy: fence)
        XCTAssertEqual(outcome, .restored)
        let hasResidue = await coordinator.hasTransientResidue()
        XCTAssertFalse(hasResidue)
    }

    func testLeaveTemporaryAsClipboardClearsResidue() async throws {
        _ = try await coordinator.writeTemporaryTranscript("kept")
        await coordinator.leaveTemporaryAsClipboard(
            ClipboardFence(changeCount: backend.changeCount))
        let hasResidue = await coordinator.hasTransientResidue()
        XCTAssertFalse(hasResidue)
        let snapshot = try await coordinator.snapshot()
        XCTAssertEqual(snapshot.items[0][stringType], Data("kept".utf8))
    }

    func testRecoveryCopyDoesNotCreateResidue() async throws {
        _ = try await coordinator.writeRecoveryCopy("kept copy")
        let hasResidue = await coordinator.hasTransientResidue()
        XCTAssertFalse(hasResidue)
        let snapshot = try await coordinator.snapshot()
        XCTAssertEqual(snapshot.items[0][stringType], Data("kept copy".utf8))
    }

    func testAwaitSettleResolvesWhenResidueClears() async throws {
        seed([[stringType: Data("original".utf8)]])
        let snapshot = try await coordinator.snapshot()
        let fence = try await coordinator.writeTemporaryTranscript("temp")
        let waiter = Task { await coordinator.awaitTransientResidueSettled() }
        try? await Task.sleep(for: .milliseconds(40))
        _ = await coordinator.restore(snapshot, guardedBy: fence)
        let settled = await waiter.value
        XCTAssertTrue(settled)
    }

    func testAwaitSettleTimesOutWhileResiduePending() async throws {
        _ = try await coordinator.writeTemporaryTranscript("temp")
        let settled = await coordinator.awaitTransientResidueSettled(
            timeout: .milliseconds(60))
        XCTAssertFalse(settled)
    }
}

final class TextInserterTests: XCTestCase {
    func testExactlyOnePastePost() {
        let poster = RecordingPastePoster()
        let inserter = TextInserter(poster: poster)
        XCTAssertEqual(inserter.pasteOnce(to: 1), .posted)
        XCTAssertEqual(inserter.pasteOnce(to: 1), .alreadyAttempted)
        XCTAssertEqual(poster.postCount, 1)
        XCTAssertTrue(inserter.hasPostedPaste)
    }

    func testFailedPostConsumesAttempt() {
        let poster = RecordingPastePoster()
        poster.result = false
        let inserter = TextInserter(poster: poster)
        XCTAssertEqual(inserter.pasteOnce(to: 1), .postFailed)
        XCTAssertEqual(inserter.pasteOnce(to: 1), .alreadyAttempted)
        XCTAssertEqual(poster.postCount, 1)
    }

    func testConcurrentPasteAttemptsPostOnce() {
        let poster = RecordingPastePoster()
        let inserter = TextInserter(poster: poster)
        var outcomes: [PasteOutcome] = []
        let outcomesLock = NSLock()
        DispatchQueue.concurrentPerform(iterations: 50) { _ in
            let outcome = inserter.pasteOnce(to: 7)
            outcomesLock.lock()
            outcomes.append(outcome)
            outcomesLock.unlock()
        }
        XCTAssertEqual(poster.postCount, 1)
        XCTAssertEqual(outcomes.filter { $0 == .posted }.count, 1)
        XCTAssertEqual(outcomes.filter { $0 == .alreadyAttempted }.count, 49)
    }
}

final class PasteGateTests: XCTestCase {
    private var backend: FakePasteboardBackend!
    private var coordinator: ClipboardCoordinator!
    private var poster: RecordingPastePoster!
    private var inserter: TextInserter!
    private let stringType = "public.utf8-plain-text"

    override func setUp() {
        backend = FakePasteboardBackend()
        coordinator = ClipboardCoordinator(backend: backend)
        poster = RecordingPastePoster()
        inserter = TextInserter(poster: poster)
    }

    func testGatePostsWhenFenced() async throws {
        let fence = try await coordinator.writeTemporaryTranscript("t")
        let outcome = await coordinator.postPasteIfFenced(fence, to: 5, using: inserter)
        XCTAssertEqual(outcome, .posted)
        XCTAssertEqual(poster.postCount, 1)
    }

    func testGateRefusesWhenOwnershipLost() async throws {
        let fence = try await coordinator.writeTemporaryTranscript("t")
        backend.foreignWrite([stringType: Data("newer".utf8)])
        let outcome = await coordinator.postPasteIfFenced(fence, to: 5, using: inserter)
        XCTAssertEqual(outcome, .clipboardOwnershipLost)
        XCTAssertEqual(poster.postCount, 0)
        XCTAssertFalse(inserter.hasPostedPaste)
    }
}

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    file: StaticString = #filePath, line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("expected throw", file: file, line: line)
    } catch {
    }
}
