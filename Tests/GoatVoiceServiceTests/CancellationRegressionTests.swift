import XCTest
@testable import GoatVoiceService

@MainActor
final class CancellationRegressionTests: XCTestCase {
    private actor ProbeBackend: LocalASRBackend {
        private(set) var started = false
        private(set) var cancelled = false

        func load(directory: URL) async throws {}
        func unload() async {}

        func transcribe(samples: [Float]) async throws -> String {
            started = true
            do {
                try await Task.sleep(for: .seconds(5))
                return "late"
            } catch {
                cancelled = true
                throw error
            }
        }
    }

    private struct Provider: LocalBackendProviding {
        let backend: ProbeBackend
        var supportedModelIDs: [String] { ["probe"] }
        func availability() -> [String: Bool] { ["probe": true] }
        func makeBackend(modelID: String) throws -> any LocalASRBackend { backend }
    }

    func testSessionCancellationReachesProducerPromptly() async throws {
        let backend = ProbeBackend()
        let core = ServiceCore(provider: Provider(backend: backend))
        let connection = UUID()
        try await core.loadModel("probe", directory: URL(fileURLWithPath: "/"))
        try await core.beginSession("session", connectionID: connection)
        let context = try await core.prepareFinish(
            "session", connectionID: connection,
            canonicalAudio: Data(repeating: 0, count: 32),
            deadline: Date().addingTimeInterval(1)
        )
        let operation = Task { try await core.completeFinish(context) }
        for _ in 0..<100 {
            if await backend.started { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        let started = await backend.started
        XCTAssertTrue(started)
        await core.cancelSession("session", connectionID: connection)
        for _ in 0..<100 {
            if await backend.cancelled { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        let cancelled = await backend.cancelled
        XCTAssertTrue(cancelled, "Session cancellation must reach the inference producer")
        operation.cancel()
        _ = try? await operation.value
    }

    func testDeadlineRaceHonorsCallerCancellation() async {
        let clock = ContinuousClock()
        let operation = Task {
            try await Deadline.race(until: Date().addingTimeInterval(1)) {
                try await Task.sleep(for: .seconds(5))
                return 1
            }
        }
        try? await Task.sleep(for: .milliseconds(5))
        let started = clock.now
        operation.cancel()
        _ = try? await operation.value
        XCTAssertLessThan(started.duration(to: clock.now), .milliseconds(200))
    }
}
