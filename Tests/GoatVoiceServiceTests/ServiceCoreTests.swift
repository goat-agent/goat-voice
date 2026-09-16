import XCTest
@testable import GoatVoiceService

final class ServiceCoreTests: XCTestCase {
    private final class StubBackend: LocalASRBackend, @unchecked Sendable {
        var loadDelay: TimeInterval = 0
        var loadError: Error?
        var transcribeDelay: TimeInterval = 0
        var transcribeResult: Result<String, Error> = .success("transcript")
        var loaded = false
        var unloaded = false
        var lastSampleCount = 0

        func load(directory: URL) async throws {
            if let loadError { throw loadError }
            if loadDelay > 0 {
                try await Task.sleep(nanoseconds: UInt64(loadDelay * 1_000_000_000))
            }
            loaded = true
        }

        func transcribe(samples: [Float]) async throws -> String {
            if transcribeDelay > 0 {
                try await Task.sleep(nanoseconds: UInt64(transcribeDelay * 1_000_000_000))
            }
            lastSampleCount = samples.count
            return try transcribeResult.get()
        }

        func unload() async { unloaded = true }
    }

    private struct StubProvider: LocalBackendProviding {
        let backend: StubBackend
        var supportedModelIDs: [String] { ["stub-model"] }
        func availability() -> [String: Bool] { ["stub-model": true] }
        func makeBackend(modelID: String) throws -> any LocalASRBackend {
            guard modelID == "stub-model" else { throw GoatVoiceServiceError.invalidArgument }
            return backend
        }
    }

    private func pcm(seconds: Double) -> Data {
        Data(count: Int(16_000 * seconds) * 2)
    }

    private func finish(_ core: ServiceCore, _ id: String, conn: UUID,
                        canonical: Data? = nil,
                        deadline: Date = Date().addingTimeInterval(120)) async throws -> String {
        let context = try await core.prepareFinish(id, connectionID: conn,
                                                   canonicalAudio: canonical,
                                                   deadline: deadline)
        return try await core.completeFinish(context)
    }

    private func nsCode(_ error: Error) -> Int { error.goatVoiceServiceNSError.code }

    func testBeginRequiresModelSelection() async {
        let core = ServiceCore(provider: StubProvider(backend: StubBackend()))
        do {
            try await core.beginSession("s", connectionID: UUID())
            XCTFail("expected modelNotSelected")
        } catch {
            XCTAssertEqual(nsCode(error), GoatVoiceServiceError.modelNotSelected.rawValue)
        }
    }

    func testStreamedFinishConvertsSamples() async throws {
        let backend = StubBackend()
        let core = ServiceCore(provider: StubProvider(backend: backend))
        let conn = UUID()
        try await core.loadModel("stub-model", directory: URL(fileURLWithPath: "/tmp/m"))
        try await core.beginSession("s", connectionID: conn)
        let first = pcm(seconds: 2)
        try await core.pushAudio("s", connectionID: conn, chunk: first, offset: 0)
        try await core.pushAudio("s", connectionID: conn, chunk: pcm(seconds: 1),
                                 offset: UInt64(first.count))
        let text = try await finish(core, "s", conn: conn)
        XCTAssertEqual(text, "transcript")
        XCTAssertEqual(backend.lastSampleCount, 48_000)
    }

    func testPushValidatesChunkBoundAndOffset() async throws {
        let backend = StubBackend()
        let core = ServiceCore(provider: StubProvider(backend: backend))
        let conn = UUID()
        try await core.loadModel("stub-model", directory: URL(fileURLWithPath: "/tmp/m"))
        try await core.beginSession("s", connectionID: conn)
        do {
            try await core.pushAudio("s", connectionID: conn,
                                   chunk: Data(count: ServiceBounds.maxChunkBytes + 1),
                                   offset: 0)
            XCTFail("expected chunkTooLarge")
        } catch {
            XCTAssertEqual(nsCode(error), GoatVoiceServiceError.chunkTooLarge.rawValue)
        }
        do {
            try await core.pushAudio("s", connectionID: conn, chunk: pcm(seconds: 1), offset: 7)
            XCTFail("expected audioOffsetMismatch")
        } catch {
            XCTAssertEqual(nsCode(error), GoatVoiceServiceError.audioOffsetMismatch.rawValue)
        }
    }

    func testFinishAfterDroppedPushRequiresCanonical() async throws {
        let backend = StubBackend()
        let core = ServiceCore(provider: StubProvider(backend: backend))
        let conn = UUID()
        try await core.loadModel("stub-model", directory: URL(fileURLWithPath: "/tmp/m"))
        try await core.beginSession("s", connectionID: conn)
        try await core.pushAudio("s", connectionID: conn, chunk: pcm(seconds: 1), offset: 0)
        do {
            try await core.pushAudio("s", connectionID: conn, chunk: pcm(seconds: 1), offset: 0)
            XCTFail("expected audioOffsetMismatch")
        } catch {
            XCTAssertEqual(nsCode(error), GoatVoiceServiceError.audioOffsetMismatch.rawValue)
        }
        do {
            _ = try await finish(core, "s", conn: conn)
            XCTFail("expected invalidArgument")
        } catch {
            XCTAssertEqual(nsCode(error), GoatVoiceServiceError.invalidArgument.rawValue)
        }
    }

    func testCanonicalReplayRecoversDroppedStream() async throws {
        let backend = StubBackend()
        let core = ServiceCore(provider: StubProvider(backend: backend))
        let conn = UUID()
        try await core.loadModel("stub-model", directory: URL(fileURLWithPath: "/tmp/m"))
        try await core.beginSession("s", connectionID: conn)
        try await core.pushAudio("s", connectionID: conn, chunk: pcm(seconds: 1), offset: 0)
        do {
            try await core.pushAudio("s", connectionID: conn, chunk: pcm(seconds: 1), offset: 0)
            XCTFail("expected audioOffsetMismatch")
        } catch {
            XCTAssertEqual(nsCode(error), GoatVoiceServiceError.audioOffsetMismatch.rawValue)
        }
        let canonical = pcm(seconds: 3)
        let text = try await finish(core, "s", conn: conn, canonical: canonical)
        XCTAssertEqual(text, "transcript")
        XCTAssertEqual(backend.lastSampleCount, 48_000)
    }

    func testOverBoundCanonicalRejected() async throws {
        let backend = StubBackend()
        let core = ServiceCore(provider: StubProvider(backend: backend))
        let conn = UUID()
        try await core.loadModel("stub-model", directory: URL(fileURLWithPath: "/tmp/m"))
        try await core.beginSession("s", connectionID: conn)
        do {
            _ = try await finish(core, "s", conn: conn,
                                 canonical: Data(count: ServiceBounds.maxSessionAudioBytes + 1))
            XCTFail("expected sessionAudioLimitExceeded")
        } catch {
            XCTAssertEqual(nsCode(error), GoatVoiceServiceError.sessionAudioLimitExceeded.rawValue)
        }
    }

    func testOneLiveSessionMaximum() async throws {
        let backend = StubBackend()
        let core = ServiceCore(provider: StubProvider(backend: backend))
        let conn = UUID()
        try await core.loadModel("stub-model", directory: URL(fileURLWithPath: "/tmp/m"))
        try await core.beginSession("first", connectionID: conn)
        do {
            try await core.beginSession("second", connectionID: conn)
            XCTFail("expected sessionLimitExceeded")
        } catch {
            XCTAssertEqual(nsCode(error), GoatVoiceServiceError.sessionLimitExceeded.rawValue)
        }
        await core.cancelSession("first", connectionID: conn)
        try await core.beginSession("second", connectionID: conn)
        _ = try await finish(core, "second", conn: conn)
    }

    func testReplacementFencesStaleGeneration() async throws {
        let backend = StubBackend()
        backend.transcribeDelay = 0.15
        let core = ServiceCore(provider: StubProvider(backend: backend))
        let conn = UUID()
        try await core.loadModel("stub-model", directory: URL(fileURLWithPath: "/tmp/m"))
        try await core.beginSession("s", connectionID: conn)
        try await core.pushAudio("s", connectionID: conn, chunk: pcm(seconds: 1), offset: 0)
        let stale = Task {
            let ctx = try await core.prepareFinish("s", connectionID: conn,
                                                   canonicalAudio: nil,
                                                   deadline: Date().addingTimeInterval(120))
            return try await core.completeFinish(ctx)
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        try await core.beginSession("s", connectionID: conn)
        try await core.pushAudio("s", connectionID: conn, chunk: pcm(seconds: 1), offset: 0)
        let text = try await finish(core, "s", conn: conn)
        XCTAssertEqual(text, "transcript")
        do {
            _ = try await stale.value
            XCTFail("expected cancelled")
        } catch {
            XCTAssertEqual(nsCode(error), GoatVoiceServiceError.cancelled.rawValue)
        }
    }

    func testDuplicateFinishRejectedWhileInFlight() async throws {
        let backend = StubBackend()
        backend.transcribeDelay = 0.15
        let core = ServiceCore(provider: StubProvider(backend: backend))
        let conn = UUID()
        try await core.loadModel("stub-model", directory: URL(fileURLWithPath: "/tmp/m"))
        try await core.beginSession("s", connectionID: conn)
        try await core.pushAudio("s", connectionID: conn, chunk: pcm(seconds: 1), offset: 0)
        let first = Task {
            let ctx = try await core.prepareFinish("s", connectionID: conn,
                                                   canonicalAudio: nil,
                                                   deadline: Date().addingTimeInterval(120))
            return try await core.completeFinish(ctx)
        }
        try await Task.sleep(nanoseconds: 30_000_000)
        do {
            _ = try await core.prepareFinish("s", connectionID: conn,
                                             canonicalAudio: nil,
                                             deadline: Date().addingTimeInterval(120))
            XCTFail("expected sessionClosed")
        } catch {
            XCTAssertEqual(nsCode(error), GoatVoiceServiceError.sessionClosed.rawValue)
        }
        let firstResult = try await first.value
        XCTAssertEqual(firstResult, "transcript")
    }

    func testCancelDuringInferenceResolvesCancelled() async throws {
        let backend = StubBackend()
        backend.transcribeDelay = 5
        let core = ServiceCore(provider: StubProvider(backend: backend))
        let conn = UUID()
        try await core.loadModel("stub-model", directory: URL(fileURLWithPath: "/tmp/m"))
        try await core.beginSession("s", connectionID: conn)
        let context = try await core.prepareFinish("s", connectionID: conn,
                                                   canonicalAudio: pcm(seconds: 1),
                                                   deadline: Date().addingTimeInterval(120))
        let operation = Task { try await core.completeFinish(context) }
        try await Task.sleep(nanoseconds: 100_000_000)
        await core.cancelSession("s", connectionID: conn)
        do {
            _ = try await operation.value
            XCTFail("expected cancelled")
        } catch {
            XCTAssertEqual(nsCode(error), GoatVoiceServiceError.cancelled.rawValue)
        }
    }

    func testUncooperativeBackendHonorsDeadline() async throws {
        final class HangingBackend: LocalASRBackend, @unchecked Sendable {
            var loaded = false
            func load(directory: URL) async throws { loaded = true }
            func transcribe(samples: [Float]) async throws -> String {
                while true {
                    try? await Task.sleep(nanoseconds: 60_000_000_000)
                }
            }
            func unload() async {}
        }
        let hanging = HangingBackend()
        struct Provider: LocalBackendProviding {
            let backend: HangingBackend
            var supportedModelIDs: [String] { ["stub-model"] }
            func availability() -> [String: Bool] { ["stub-model": true] }
            func makeBackend(modelID: String) throws -> any LocalASRBackend { backend }
        }
        let core = ServiceCore(provider: Provider(backend: hanging))
        let conn = UUID()
        try await core.loadModel("stub-model", directory: URL(fileURLWithPath: "/tmp/m"))
        try await core.beginSession("s", connectionID: conn)
        let started = Date()
        do {
            _ = try await finish(core, "s", conn: conn,
                                 deadline: Date().addingTimeInterval(0.15))
            XCTFail("expected deadlineExceeded")
        } catch {
            XCTAssertEqual(nsCode(error), GoatVoiceServiceError.deadlineExceeded.rawValue)
            XCTAssertLessThan(Date().timeIntervalSince(started), 1.0)
        }
    }

    func testFinishAfterCancelAndAfterUnload() async throws {
        let backend = StubBackend()
        let core = ServiceCore(provider: StubProvider(backend: backend))
        let conn = UUID()
        try await core.loadModel("stub-model", directory: URL(fileURLWithPath: "/tmp/m"))
        try await core.beginSession("s", connectionID: conn)
        await core.cancelSession("s", connectionID: conn)
        do {
            _ = try await finish(core, "s", conn: conn)
            XCTFail("expected sessionUnknown")
        } catch {
            XCTAssertEqual(nsCode(error), GoatVoiceServiceError.sessionUnknown.rawValue)
        }
        try await core.beginSession("s2", connectionID: conn)
        await core.unloadModel()
        XCTAssertTrue(backend.unloaded)
        do {
            try await core.beginSession("s3", connectionID: conn)
            XCTFail("expected modelNotSelected")
        } catch {
            XCTAssertEqual(nsCode(error), GoatVoiceServiceError.modelNotSelected.rawValue)
        }
    }

    func testCrossConnectionIsolation() async throws {
        let backend = StubBackend()
        let core = ServiceCore(provider: StubProvider(backend: backend))
        let connA = UUID()
        let connB = UUID()
        try await core.loadModel("stub-model", directory: URL(fileURLWithPath: "/tmp/m"))
        try await core.beginSession("s", connectionID: connA)
        do {
            try await core.pushAudio("s", connectionID: connB, chunk: pcm(seconds: 1), offset: 0)
            XCTFail("expected sessionUnknown")
        } catch {
            XCTAssertEqual(nsCode(error), GoatVoiceServiceError.sessionUnknown.rawValue)
        }
        do {
            _ = try await finish(core, "s", conn: connB)
            XCTFail("expected sessionUnknown")
        } catch {
            XCTAssertEqual(nsCode(error), GoatVoiceServiceError.sessionUnknown.rawValue)
        }
        await core.retireForeignSessions(keeping: connB)
        do {
            _ = try await finish(core, "s", conn: connA)
            XCTFail("expected sessionUnknown after retire")
        } catch {
            XCTAssertEqual(nsCode(error), GoatVoiceServiceError.sessionUnknown.rawValue)
        }
    }

    func testCancelConnectionDropsSessions() async throws {
        let backend = StubBackend()
        let core = ServiceCore(provider: StubProvider(backend: backend))
        let conn = UUID()
        try await core.loadModel("stub-model", directory: URL(fileURLWithPath: "/tmp/m"))
        try await core.beginSession("s", connectionID: conn)
        try await core.pushAudio("s", connectionID: conn, chunk: pcm(seconds: 1), offset: 0)
        await core.cancelConnection(conn)
        do {
            _ = try await finish(core, "s", conn: conn)
            XCTFail("expected sessionUnknown")
        } catch {
            XCTAssertEqual(nsCode(error), GoatVoiceServiceError.sessionUnknown.rawValue)
        }
    }

    func testHandshakeContents() async throws {
        let backend = StubBackend()
        let core = ServiceCore(provider: StubProvider(backend: backend))
        let payload = await core.handshakePayload()
        XCTAssertNotNil(payload["serviceInstanceID"] as? String)
        XCTAssertEqual((payload["protocolVersion"] as? Int), 2)
    }

    func testTransientFailureRetryableThenSucceeds() async throws {
        let backend = StubBackend()
        backend.transcribeResult = .failure(GoatVoiceServiceError.inferenceFailed)
        let core = ServiceCore(provider: StubProvider(backend: backend))
        let conn = UUID()
        try await core.loadModel("stub-model", directory: URL(fileURLWithPath: "/tmp/m"))
        try await core.beginSession("s", connectionID: conn)
        try await core.pushAudio("s", connectionID: conn, chunk: pcm(seconds: 1), offset: 0)
        do {
            _ = try await finish(core, "s", conn: conn)
            XCTFail("expected inferenceFailed")
        } catch {
            let ns = error.goatVoiceServiceNSError
            XCTAssertEqual(ns.code, GoatVoiceServiceError.inferenceFailed.rawValue)
            XCTAssertEqual((ns.userInfo["retryable"] as? Bool), true)
        }
        try await core.beginSession("s2", connectionID: conn)
        try await core.pushAudio("s2", connectionID: conn, chunk: pcm(seconds: 1), offset: 0)
        backend.transcribeResult = .success("retry transcript")
        let retried = try await finish(core, "s2", conn: conn)
        XCTAssertEqual(retried, "retry transcript")
    }
}
