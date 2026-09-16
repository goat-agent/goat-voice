import Dispatch
import XCTest
@testable import GoatVoiceService

final class EngineHostTests: XCTestCase {
    private final class FakeBackend: LocalASRBackend, LocalASRCacheTrimming,
                                   @unchecked Sendable {
        enum LoadBehavior {
            case succeed
            case fail(Error)
            case slowSucceed(TimeInterval)
            case slowFail(TimeInterval, Error)
            case forever
        }

        var loadBehavior: LoadBehavior = .succeed
        var unloadBlocked = false
        var loaded = false
        var unloadCalls = 0
        var loadCalls = 0
        var trimCalls = 0

        init(loadBehavior: LoadBehavior = .succeed) {
            self.loadBehavior = loadBehavior
        }

        func load(directory: URL) async throws {
            loadCalls += 1
            switch loadBehavior {
            case .succeed:
                break
            case .fail(let error):
                throw error
            case .slowSucceed(let delay):
                let end = Date().addingTimeInterval(delay)
                while Date() < end {
                    try? await Task.sleep(nanoseconds: 10_000_000)
                }
            case .slowFail(let delay, let error):
                let end = Date().addingTimeInterval(delay)
                while Date() < end {
                    try? await Task.sleep(nanoseconds: 10_000_000)
                }
                throw error
            case .forever:
                while true {
                    try? await Task.sleep(nanoseconds: 60_000_000_000)
                }
            }
            loaded = true
        }

        func transcribe(samples: [Float]) async throws -> String { "t" }

        func unload() async {
            while unloadBlocked {
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
            unloadCalls += 1
        }

        func trimCache() async { trimCalls += 1 }
    }

    private final class CountingProvider: LocalBackendProviding, @unchecked Sendable {
        var backends: [FakeBackend] = []
        var pendingBehaviors: [FakeBackend.LoadBehavior] = []
        var supportedModelIDs: [String] { ["m1", "m2"] }
        func availability() -> [String: Bool] { ["m1": true, "m2": true] }
        func makeBackend(modelID: String) throws -> any LocalASRBackend {
            guard supportedModelIDs.contains(modelID) else {
                throw GoatVoiceServiceError.invalidArgument
            }
            let behavior = pendingBehaviors.isEmpty
                ? .succeed : pendingBehaviors.removeFirst()
            let backend = FakeBackend(loadBehavior: behavior)
            backends.append(backend)
            return backend
        }
    }

    private func nsCode(_ error: Error) -> Int { error.goatVoiceServiceNSError.code }
    private let dir = URL(fileURLWithPath: "/tmp/model")

    func testSameModelWarmCoalesces() async throws {
        let provider = CountingProvider()
        let host = EngineHost(provider: provider, watchdog: 5)
        try await host.load(modelID: "m1", directory: dir)
        try await host.load(modelID: "m1", directory: dir)
        XCTAssertEqual(provider.backends.count, 1)
        XCTAssertEqual(provider.backends[0].unloadCalls, 0)
        let state = await host.modelStateName
        XCTAssertEqual(state, "loaded")
    }

    func testDifferentModelWhileLoadingIsBusy() async throws {
        let provider = CountingProvider()
        provider.pendingBehaviors = [.slowSucceed(0.5)]
        let host = EngineHost(provider: provider, watchdog: 5)
        let first = Task { try? await host.load(modelID: "m1", directory: dir) }
        try await Task.sleep(nanoseconds: 50_000_000)
        do {
            try await host.load(modelID: "m2", directory: dir)
            XCTFail("expected busyLoading")
        } catch {
            XCTAssertEqual(nsCode(error), GoatVoiceServiceError.busyLoading.rawValue)
        }
        _ = await first.value
        XCTAssertEqual(provider.backends.count, 1)
    }

    func testTimedOutRetriesStaySingleBackend() async throws {
        let provider = CountingProvider()
        provider.pendingBehaviors = [.forever]
        let host = EngineHost(provider: provider, watchdog: 0.1)
        let started = Date()
        do {
            try await host.load(modelID: "m1", directory: dir)
            XCTFail("expected modelLoadTimedOut")
        } catch {
            XCTAssertEqual(nsCode(error),
                           GoatVoiceServiceError.modelLoadTimedOut.rawValue)
            XCTAssertLessThan(Date().timeIntervalSince(started), 1.0)
        }
        for _ in 0..<3 {
            do {
                try await host.load(modelID: "m1", directory: dir)
                XCTFail("expected modelLoadTimedOut")
            } catch {
                XCTAssertEqual(nsCode(error),
                               GoatVoiceServiceError.modelLoadTimedOut.rawValue)
            }
        }
        do {
            _ = try await host.readyBackend()
            XCTFail("expected modelLoadTimedOut")
        } catch {
            XCTAssertEqual(nsCode(error),
                           GoatVoiceServiceError.modelLoadTimedOut.rawValue)
        }
        XCTAssertEqual(provider.backends.count, 1)
        let state = await host.modelStateName
        XCTAssertEqual(state, "loading")
    }

    func testCoalescedWaitKeepsOriginalDeadline() async throws {
        let provider = CountingProvider()
        provider.pendingBehaviors = [.forever]
        let host = EngineHost(provider: provider, watchdog: 0.3)
        let first = Task { try? await host.load(modelID: "m1", directory: dir) }
        try await Task.sleep(nanoseconds: 200_000_000)
        let started = Date()
        do {
            try await host.load(modelID: "m1", directory: dir)
            XCTFail("expected modelLoadTimedOut")
        } catch {
            XCTAssertEqual(nsCode(error),
                           GoatVoiceServiceError.modelLoadTimedOut.rawValue)
            XCTAssertLessThan(Date().timeIntervalSince(started), 0.25)
        }
        _ = await first.value
        XCTAssertEqual(provider.backends.count, 1)
    }

    func testRecoveryAfterLateProducerSuccess() async throws {
        let provider = CountingProvider()
        provider.pendingBehaviors = [.slowSucceed(0.3)]
        let host = EngineHost(provider: provider, watchdog: 0.05)
        do {
            try await host.load(modelID: "m1", directory: dir)
            XCTFail("expected modelLoadTimedOut")
        } catch {
            XCTAssertEqual(nsCode(error),
                           GoatVoiceServiceError.modelLoadTimedOut.rawValue)
        }
        try await Task.sleep(nanoseconds: 400_000_000)
        try await host.load(modelID: "m1", directory: dir)
        XCTAssertEqual(provider.backends.count, 1)
        XCTAssertTrue(provider.backends[0].loaded)
        let state = await host.modelStateName
        XCTAssertEqual(state, "loaded")
        let backend = try await host.readyBackend()
        XCTAssertTrue((backend as? FakeBackend) === provider.backends[0])
    }

    func testRecoveryAfterLateProducerFailure() async throws {
        let provider = CountingProvider()
        provider.pendingBehaviors = [
            .slowFail(0.3, GoatVoiceServiceError.modelCorrupt), .succeed,
        ]
        let host = EngineHost(provider: provider, watchdog: 0.05)
        do {
            try await host.load(modelID: "m1", directory: dir)
            XCTFail("expected modelLoadTimedOut")
        } catch {
            XCTAssertEqual(nsCode(error),
                           GoatVoiceServiceError.modelLoadTimedOut.rawValue)
        }
        try await Task.sleep(nanoseconds: 400_000_000)
        let failed = await host.modelStateName
        XCTAssertEqual(failed, "failed")
        try await host.load(modelID: "m1", directory: dir)
        XCTAssertEqual(provider.backends.count, 2)
        let state = await host.modelStateName
        XCTAssertEqual(state, "loaded")
    }

    func testCallerCancelDoesNotFreeSlot() async throws {
        let provider = CountingProvider()
        provider.pendingBehaviors = [.slowSucceed(0.4)]
        let host = EngineHost(provider: provider, watchdog: 5)
        let loading = Task { try await host.load(modelID: "m1", directory: dir) }
        try await Task.sleep(nanoseconds: 50_000_000)
        loading.cancel()
        do {
            try await loading.value
            XCTFail("expected cancelled")
        } catch {
            XCTAssertEqual(nsCode(error), GoatVoiceServiceError.cancelled.rawValue)
        }
        try await Task.sleep(nanoseconds: 500_000_000)
        try await host.load(modelID: "m1", directory: dir)
        XCTAssertEqual(provider.backends.count, 1)
        XCTAssertTrue(provider.backends[0].loaded)
    }

    func testUnloadBoundedThenRetireSettles() async throws {
        let provider = CountingProvider()
        let host = EngineHost(provider: provider, watchdog: 0.15)
        try await host.load(modelID: "m1", directory: dir)
        provider.backends[0].unloadBlocked = true
        let started = Date()
        await host.unload()
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.0)
        do {
            try await host.load(modelID: "m2", directory: dir)
            XCTFail("expected busyLoading during retire")
        } catch {
            XCTAssertEqual(nsCode(error), GoatVoiceServiceError.busyLoading.rawValue)
        }
        do {
            try await host.ensureSessionStartable()
            XCTFail("expected busyLoading during retire")
        } catch {
            XCTAssertEqual(nsCode(error), GoatVoiceServiceError.busyLoading.rawValue)
        }
        provider.backends[0].unloadBlocked = false
        var loaded = false
        for _ in 0..<40 {
            do {
                try await host.load(modelID: "m2", directory: dir)
                loaded = true
                break
            } catch {
                try await Task.sleep(nanoseconds: 50_000_000)
            }
        }
        XCTAssertTrue(loaded)
        XCTAssertEqual(provider.backends.count, 2)
        XCTAssertEqual(provider.backends[0].unloadCalls, 1)
        XCTAssertEqual(provider.backends[1].unloadCalls, 0)
    }

    func testStaleRetireCannotTouchNewerBackend() async throws {
        let provider = CountingProvider()
        let host = EngineHost(provider: provider, watchdog: 0.5)
        try await host.load(modelID: "m1", directory: dir)
        provider.backends[0].unloadBlocked = true
        let drop = Task { await host.unload() }
        try await Task.sleep(nanoseconds: 50_000_000)
        provider.backends[0].unloadBlocked = false
        _ = await drop.value
        try await host.load(modelID: "m2", directory: dir)
        let selected = await host.selectedModelID
        XCTAssertEqual(selected, "m2")
        let backend = try await host.readyBackend()
        XCTAssertTrue((backend as? FakeBackend) === provider.backends[1])
        XCTAssertEqual(provider.backends[0].unloadCalls, 1)
        XCTAssertEqual(provider.backends[1].unloadCalls, 0)
    }

    func testSessionStartWhileLoadingAndSwitchGuardedBySessions() async throws {
        let provider = CountingProvider()
        provider.pendingBehaviors = [.slowSucceed(0.3)]
        let host = EngineHost(provider: provider, watchdog: 5)
        let loading = Task { try? await host.load(modelID: "m1", directory: dir) }
        try await Task.sleep(nanoseconds: 50_000_000)
        try await host.ensureSessionStartable()
        _ = await loading.value
        await host.sessionOpened()
        do {
            try await host.load(modelID: "m2", directory: dir)
            XCTFail("expected busyLoading with live session")
        } catch {
            XCTAssertEqual(nsCode(error), GoatVoiceServiceError.busyLoading.rawValue)
        }
        await host.sessionClosed()
    }

    func testMemoryPressureTrimAndCriticalRetire() async throws {
        let provider = CountingProvider()
        let host = EngineHost(provider: provider, watchdog: 2)
        try await host.load(modelID: "m1", directory: dir)
        await host.handleMemoryPressure(
            rawValue: DispatchSource.MemoryPressureEvent.warning.rawValue)
        XCTAssertEqual(provider.backends[0].trimCalls, 1)
        await host.handleMemoryPressure(
            rawValue: DispatchSource.MemoryPressureEvent.critical.rawValue)
        XCTAssertEqual(provider.backends[0].unloadCalls, 1)
        let selected = await host.selectedModelID
        XCTAssertEqual(selected, "m1")
        try await host.ensureSessionStartable()
        let loading = await host.modelStateName
        XCTAssertEqual(loading, "loading")
        let backend = try await host.readyBackend()
        XCTAssertTrue((backend as? FakeBackend) === provider.backends[1])
        XCTAssertEqual(provider.backends.count, 2)
    }

    func testLoadFailureRecordsErrorThenExplicitRetry() async throws {
        let provider = CountingProvider()
        provider.pendingBehaviors = [
            .fail(GoatVoiceServiceError.modelCorrupt), .succeed,
        ]
        let host = EngineHost(provider: provider, watchdog: 5)
        do {
            try await host.load(modelID: "m1", directory: dir)
            XCTFail("expected modelCorrupt")
        } catch {
            XCTAssertEqual(nsCode(error), GoatVoiceServiceError.modelCorrupt.rawValue)
        }
        for _ in 0..<40 {
            let state = await host.modelStateName
            if state == "failed" { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let failed = await host.modelStateName
        XCTAssertEqual(failed, "failed")
        do {
            try await host.ensureSessionStartable()
            XCTFail("expected recorded failure")
        } catch {
            XCTAssertEqual(nsCode(error), GoatVoiceServiceError.modelCorrupt.rawValue)
        }
        try await host.load(modelID: "m1", directory: dir)
        XCTAssertEqual(provider.backends.count, 2)
        let state = await host.modelStateName
        XCTAssertEqual(state, "loaded")
    }
}
