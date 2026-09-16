import XCTest
@testable import GoatVoiceService

private actor PreviewBackend: LocalASRPreviewing {
    private var pending: CheckedContinuation<String, Never>?
    private(set) var previewSamples = 0
    private(set) var finalSamples = 0
    private(set) var finalOverlapped = false

    func load(directory: URL) async throws {}
    func unload() async {}

    func preview(samples: [Float]) async throws -> String {
        previewSamples = samples.count
        return await withCheckedContinuation { pending = $0 }
    }

    func transcribe(samples: [Float]) async throws -> String {
        finalOverlapped = pending != nil
        finalSamples = samples.count
        return "final result"
    }

    func resolve() {
        pending?.resume(returning: "interim result")
        pending = nil
    }

    var isPreviewing: Bool { pending != nil }
}

private struct PreviewProvider: LocalBackendProviding {
    let backend: PreviewBackend
    var supportedModelIDs: [String] { ["preview"] }
    func availability() -> [String: Bool] { ["preview": true] }
    func makeBackend(modelID: String) throws -> any LocalASRBackend { backend }
}

final class PreviewSessionTests: XCTestCase {
    private func audio(seconds: Int) -> Data {
        let values = [Int16](repeating: 2000, count: seconds * 16_000)
        return values.withUnsafeBytes { Data($0) }
    }

    private func ready(_ core: ServiceCore, connection: UUID) async throws {
        try await core.loadModel("preview", directory: URL(fileURLWithPath: "/unused"))
        try await core.beginSession("session", connectionID: connection)
    }

    private func waitForPreview(_ backend: PreviewBackend) async throws {
        for _ in 0..<200 {
            if await backend.isPreviewing { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Preview did not start")
    }

    func testPreviewUsesBoundedTailAndFinalUsesCompleteAudioWithoutOverlap() async throws {
        let backend = PreviewBackend()
        let core = ServiceCore(provider: PreviewProvider(backend: backend))
        let connection = UUID()
        try await ready(core, connection: connection)
        try await core.pushAudio("session", connectionID: connection, chunk: audio(seconds: 6), offset: 0)
        try await core.pushAudio("session", connectionID: connection, chunk: audio(seconds: 6), offset: 192_000)
        let preview = Task { try await core.previewSession("session", connectionID: connection) }
        try await waitForPreview(backend)
        let context = try await core.prepareFinish("session", connectionID: connection,
                                                 canonicalAudio: audio(seconds: 12),
                                                 deadline: Date().addingTimeInterval(5))
        let final = Task { try await core.completeFinish(context) }
        await backend.resolve()
        do {
            _ = try await preview.value
            XCTFail("Post-release preview must be stale")
        } catch {
            XCTAssertEqual(error as? GoatVoiceServiceError, .cancelled)
        }
        let result = try await final.value
        let previewSamples = await backend.previewSamples
        let finalSamples = await backend.finalSamples
        let overlapped = await backend.finalOverlapped
        XCTAssertEqual(result, "final result")
        XCTAssertEqual(previewSamples, 128_000)
        XCTAssertEqual(finalSamples, 192_000)
        XCTAssertFalse(overlapped)
    }

    func testDuplicatePreviewIsRejectedAndCancelledResultCannotEscape() async throws {
        let backend = PreviewBackend()
        let core = ServiceCore(provider: PreviewProvider(backend: backend))
        let connection = UUID()
        try await ready(core, connection: connection)
        try await core.pushAudio("session", connectionID: connection, chunk: audio(seconds: 2), offset: 0)
        let preview = Task { try await core.previewSession("session", connectionID: connection) }
        try await waitForPreview(backend)
        do {
            _ = try await core.previewSession("session", connectionID: connection)
            XCTFail("Only one preview may run")
        } catch {
            XCTAssertEqual(error as? GoatVoiceServiceError, .busyLoading)
        }
        await core.cancelSession("session", connectionID: connection)
        await backend.resolve()
        do {
            _ = try await preview.value
            XCTFail("Cancelled preview must not escape")
        } catch {
            XCTAssertEqual(error as? GoatVoiceServiceError, .cancelled)
        }
    }

    func testSilenceAndInsufficientAudioNeverReachModel() async throws {
        let backend = PreviewBackend()
        let core = ServiceCore(provider: PreviewProvider(backend: backend))
        let connection = UUID()
        try await ready(core, connection: connection)
        try await core.pushAudio("session", connectionID: connection, chunk: audio(seconds: 1), offset: 0)
        let short = try await core.previewSession("session", connectionID: connection)
        XCTAssertEqual(short, "")
        await core.cancelSession("session", connectionID: connection)
        try await core.beginSession("session", connectionID: connection)
        try await core.pushAudio("session", connectionID: connection, chunk: Data(count: 64_000), offset: 0)
        let silent = try await core.previewSession("session", connectionID: connection)
        let sampleCount = await backend.previewSamples
        XCTAssertEqual(silent, "")
        XCTAssertEqual(sampleCount, 0)
    }

    func testSignalGateRejectsNonfiniteAndEmptySamples() {
        XCTAssertFalse(PreviewAudioPolicy.containsSignal([]))
        XCTAssertFalse(PreviewAudioPolicy.containsSignal([.nan]))
        XCTAssertFalse(PreviewAudioPolicy.containsSignal([.infinity]))
        XCTAssertFalse(PreviewAudioPolicy.containsSignal([0, 0, 0]))
        XCTAssertTrue(PreviewAudioPolicy.containsSignal([0.1, -0.1]))
    }
}

final class BackendInferenceOperationTests: XCTestCase {
    func testCancellingWaitDoesNotCancelModelOperation() async throws {
        let backend = PreviewBackend()
        let producer = Task { try await backend.preview(samples: [0.1]) }
        let operation = BackendInferenceOperation(purpose: .preview, task: producer)
        let waiter = Task { try await operation.waitForCompletion() }
        for _ in 0..<200 {
            if await backend.isPreviewing { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        waiter.cancel()
        do {
            try await waiter.value
            XCTFail("Cancelled wait should return immediately")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertFalse(producer.isCancelled)
        await backend.resolve()
        let result = try await producer.value
        XCTAssertEqual(result, "interim result")
    }
}
