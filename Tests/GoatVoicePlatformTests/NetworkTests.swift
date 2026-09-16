import Foundation
import XCTest
@testable import GoatVoicePlatform

final class NetworkTests: XCTestCase {
    private static let url = URL(string: "https://stub.invalid/model.bin")!

    private final class Locked<Value>: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Value

        init(_ value: Value) { self.value = value }

        func withLock<Returned>(_ body: (inout Value) -> Returned) -> Returned {
            lock.withLock { body(&value) }
        }

        func get() -> Value { lock.withLock { value } }
    }

    private final class StubURLProtocol: URLProtocol, @unchecked Sendable {
        struct Script: Sendable {
            var body: Data
            var chunkSize = 1024
            var chunkDelay: TimeInterval = 0
            var stallAfterBytes: Int?
            var honorRange = true
        }

        private static let stateLock = NSLock()
        private static var script: (@Sendable (URLRequest) -> Script)?
        private static var receivedRequests: [URLRequest] = []

        static func install(_ handler: @escaping @Sendable (URLRequest) -> Script) {
            stateLock.withLock {
                script = handler
                receivedRequests = []
            }
        }

        static var requestCount: Int {
            stateLock.withLock { receivedRequests.count }
        }

        private static func parseRangeStart(_ header: String) -> Int? {
            guard header.hasPrefix("bytes="), let dash = header.firstIndex(of: "-") else { return nil }
            return Int(header[header.index(header.startIndex, offsetBy: 6)..<dash])
        }

        private let instanceLock = NSLock()
        private var stopped = false

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            let resolved = Self.stateLock.withLock { () -> Script? in
                Self.receivedRequests.append(request)
                return Self.script?(request)
            }
            guard let resolved else { return }
            DispatchQueue.global().async { self.deliver(resolved) }
        }

        override func stopLoading() {
            instanceLock.withLock { stopped = true }
        }

        private func isStopped() -> Bool {
            instanceLock.withLock { stopped }
        }

        private func deliver(_ script: Script) {
            var body = script.body
            var status = 200
            if script.honorRange, let range = request.value(forHTTPHeaderField: "Range"),
               let offset = Self.parseRangeStart(range) {
                body = body.subdata(in: min(offset, body.count)..<body.count)
                status = 206
            }
            let headers = [
                "Content-Length": String(body.count),
                "Accept-Ranges": "bytes",
                "ETag": "\"stub\""
            ]
            guard let response = HTTPURLResponse(url: request.url!, statusCode: status,
                                                 httpVersion: nil, headerFields: headers) else { return }
            guard !isStopped() else { return }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            let limit = min(script.stallAfterBytes ?? body.count, body.count)
            var sent = 0
            while sent < limit {
                if isStopped() { return }
                let next = min(script.chunkSize, limit - sent)
                client?.urlProtocol(self, didLoad: body.subdata(in: sent..<(sent + next)))
                sent += next
                if script.chunkDelay > 0 { Thread.sleep(forTimeInterval: script.chunkDelay) }
            }
            guard !isStopped(), sent == body.count else { return }
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    private final class FakePausable: NetworkPausable, @unchecked Sendable {
        private let lock = NSLock()
        private var tail: Task<Void, Never>?
        private var recorded: [String] = []
        var pauseDelay: TimeInterval = 0

        var pauseCount: Int { lock.withLock { recorded.filter { $0 == "pause" }.count } }
        var resumeCount: Int { lock.withLock { recorded.filter { $0 == "resume" }.count } }
        var events: [String] { lock.withLock { recorded } }

        func pauseNetworkActivity() async {
            await enqueue {
                let delay = self.lock.withLock { self.pauseDelay }
                if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
                self.lock.withLock { self.recorded.append("pause") }
            }
        }

        func resumeNetworkActivity() async {
            await enqueue {
                self.lock.withLock { self.recorded.append("resume") }
            }
        }

        private func enqueue(_ work: @escaping @Sendable () async -> Void) async {
            let next = lock.withLock { () -> Task<Void, Never> in
                let previous = tail
                let task = Task {
                    await previous?.value
                    await work()
                }
                tail = task
                return task
            }
            await next.value
        }
    }

    private var tempDirectory: URL!

    override func setUp() {
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("network-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDirectory)
        StubURLProtocol.install { _ in .init(body: Data()) }
    }

    private func makeTransport(gate: NetworkSessionGate = NetworkSessionGate(),
                               stallLimit: Duration = .seconds(30)) -> URLSessionDownloadTransport {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSessionDownloadTransport(gate: gate, configuration: configuration,
                                           requestTimeout: 30, stallLimit: stallLimit)
    }

    private func destination(_ name: String = "artifact.bin") -> URL {
        tempDirectory.appendingPathComponent(name)
    }

    private func eventually(_ timeout: TimeInterval = 3,
                            _ condition: @escaping () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return condition()
    }

    private func expectEventually(_ timeout: TimeInterval = 3,
                                  _ condition: @escaping () -> Bool,
                                  file: StaticString = #filePath, line: UInt = #line) async {
        let met = await eventually(timeout, condition)
        XCTAssertTrue(met, "condition not met within \(timeout)s", file: file, line: line)
    }

    private func result(of task: Task<Void, Error>) async -> (any Error)? {
        do {
            try await task.value
            return nil
        } catch {
            return error
        }
    }

    private func requireError(_ error: (any Error)?,
                              _ check: (NetworkTransportError) -> Bool,
                              _ expectation: String,
                              file: StaticString = #filePath, line: UInt = #line) {
        guard let transportError = error as? NetworkTransportError, check(transportError) else {
            XCTFail("expected \(expectation), got \(String(describing: error))", file: file, line: line)
            return
        }
    }

    func testGateBlocksStartsSynchronously() {
        let coordinator = NetworkActivityCoordinator()
        XCTAssertTrue(coordinator.allowsNewNetworkWork)
        coordinator.beginDictationSession()
        XCTAssertFalse(coordinator.allowsNewNetworkWork)
        coordinator.endDictationSession()
        XCTAssertTrue(coordinator.allowsNewNetworkWork)
    }

    func testPerformStartRunsBodyOnlyWhenAllowed() {
        let coordinator = NetworkActivityCoordinator()
        var ran = false
        XCTAssertTrue(coordinator.sessionGate.performStart { ran = true })
        XCTAssertTrue(ran)
        coordinator.beginDictationSession()
        ran = false
        XCTAssertFalse(coordinator.sessionGate.performStart { ran = true })
        XCTAssertFalse(ran)
        coordinator.endDictationSession()
        XCTAssertTrue(coordinator.sessionGate.performStart { ran = true })
    }

    func testBeginPausesRegisteredClientsOnce() async {
        let coordinator = NetworkActivityCoordinator()
        let client = FakePausable()
        coordinator.register(client)
        coordinator.register(client)
        coordinator.beginDictationSession()
        await expectEventually { client.pauseCount == 1 }
        coordinator.endDictationSession()
        await expectEventually { client.resumeCount == 1 }
        XCTAssertEqual(client.events, ["pause", "resume"])
    }

    func testReentrantBeginEndAreIdempotent() async {
        let coordinator = NetworkActivityCoordinator()
        let client = FakePausable()
        coordinator.register(client)
        coordinator.beginDictationSession()
        coordinator.beginDictationSession()
        coordinator.endDictationSession()
        coordinator.endDictationSession()
        await expectEventually { client.events == ["pause", "resume"] }
        XCTAssertTrue(coordinator.allowsNewNetworkWork)
    }

    func testClientRegisteredDuringSessionIsNotPausedOrResumed() async {
        let coordinator = NetworkActivityCoordinator()
        let early = FakePausable()
        let late = FakePausable()
        coordinator.register(early)
        coordinator.beginDictationSession()
        coordinator.register(late)
        coordinator.endDictationSession()
        await expectEventually { early.events == ["pause", "resume"] }
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(late.events, [])
    }

    func testRapidSessionsPreservePauseResumeOrder() async {
        let coordinator = NetworkActivityCoordinator()
        let client = FakePausable()
        coordinator.register(client)
        for _ in 0..<50 {
            coordinator.beginDictationSession()
            coordinator.endDictationSession()
        }
        await expectEventually { client.events.count == 100 }
        XCTAssertEqual(client.events, (0..<50).flatMap { _ in ["pause", "resume"] })
    }

    func testLatePauseAcknowledgementStillReceivesResume() async {
        let coordinator = NetworkActivityCoordinator()
        let client = FakePausable()
        client.pauseDelay = 0.3
        coordinator.register(client)
        coordinator.beginDictationSession()
        coordinator.endDictationSession()
        await expectEventually { client.events == ["pause", "resume"] }
    }

    func testUnregisteredClientGetsNoResume() async {
        let coordinator = NetworkActivityCoordinator()
        let client = FakePausable()
        coordinator.register(client)
        coordinator.beginDictationSession()
        await expectEventually { client.pauseCount == 1 }
        coordinator.unregister(client)
        coordinator.endDictationSession()
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(client.events, ["pause"])
    }

    func testDownloadDeliversFileAndByteProgress() async throws {
        let payload = Data((0..<8_192).map { UInt8($0 % 251) })
        StubURLProtocol.install { _ in .init(body: payload, chunkSize: 512, chunkDelay: 0.0005) }
        let transport = makeTransport()
        let target = destination()
        let reported = Locked<[Int64]>([])
        try await transport.download(Self.url, to: target) { completed in
            reported.withLock { $0.append(completed) }
        }
        XCTAssertEqual(try Data(contentsOf: target), payload)
        XCTAssertEqual(reported.get().last, Int64(payload.count))
        XCTAssertEqual(reported.get(), reported.get().sorted())
        transport.invalidate()
    }

    func testDownloadBlockedBySessionNeverReachesNetwork() async {
        StubURLProtocol.install { _ in .init(body: Data(repeating: 1, count: 64)) }
        let coordinator = NetworkActivityCoordinator()
        let transport = makeTransport(gate: coordinator.sessionGate)
        coordinator.beginDictationSession()
        let error = await result(of: Task {
            try await transport.download(Self.url, to: destination()) { _ in }
        })
        requireError(error, { if case .blockedByActiveSession = $0 { return true }; return false },
                     "blockedByActiveSession")
        XCTAssertEqual(StubURLProtocol.requestCount, 0)
        coordinator.endDictationSession()
        transport.invalidate()
    }

    func testResumeBlockedBySessionNeverCreatesTask() async {
        StubURLProtocol.install { _ in .init(body: Data(repeating: 1, count: 64)) }
        let coordinator = NetworkActivityCoordinator()
        let transport = makeTransport(gate: coordinator.sessionGate)
        coordinator.beginDictationSession()
        let error = await result(of: Task {
            try await transport.resume(with: Data([0x1, 0x2]), to: destination()) { _ in }
        })
        requireError(error, { if case .blockedByActiveSession = $0 { return true }; return false },
                     "blockedByActiveSession")
        XCTAssertEqual(StubURLProtocol.requestCount, 0)
        coordinator.endDictationSession()
        transport.invalidate()
    }

    func testStartCannotRaceSessionBegin() async {
        for iteration in 0..<80 {
            StubURLProtocol.install { _ in .init(body: Data(repeating: 7, count: 32)) }
            let coordinator = NetworkActivityCoordinator()
            let transport = makeTransport(gate: coordinator.sessionGate)
            let dest = destination("race-\(iteration).bin")
            if iteration.isMultiple(of: 2) {
                let download = Task {
                    try await transport.download(Self.url, to: dest) { _ in }
                }
                coordinator.beginDictationSession()
                let error = await result(of: download)
                if let error {
                    requireError(error, { if case .blockedByActiveSession = $0 { return true }
                                          return false }, "blockedByActiveSession")
                }
                XCTAssertEqual(StubURLProtocol.requestCount == 0, error != nil)
            } else {
                coordinator.beginDictationSession()
                let error = await result(of: Task {
                    try await transport.download(Self.url, to: dest) { _ in }
                })
                requireError(error, { if case .blockedByActiveSession = $0 { return true }
                                      return false }, "blockedByActiveSession")
                XCTAssertEqual(StubURLProtocol.requestCount, 0)
            }
            coordinator.endDictationSession()
            transport.invalidate()
        }
    }

    func testSecondDownloadRejectedWhileActive() async {
        let payload = Data(repeating: 3, count: 400_000)
        StubURLProtocol.install { _ in .init(body: payload, chunkSize: 512, chunkDelay: 0.005) }
        let transport = makeTransport()
        let first = Task { try await transport.download(Self.url, to: destination("a.bin")) { _ in } }
        await expectEventually { StubURLProtocol.requestCount == 1 }
        let error = await result(of: Task {
            try await transport.download(Self.url, to: destination("b.bin")) { _ in }
        })
        requireError(error, { if case .alreadyActive = $0 { return true }; return false },
                     "alreadyActive")
        transport.cancel()
        let firstError = await result(of: first)
        requireError(firstError, { if case .cancelled = $0 { return true }; return false },
                     "cancelled")
        transport.invalidate()
    }

    func testCancelTerminatesDownloadAndAllowsRestart() async throws {
        let payload = Data(repeating: 5, count: 400_000)
        StubURLProtocol.install { _ in .init(body: payload, chunkSize: 512, chunkDelay: 0.005) }
        let transport = makeTransport()
        let first = Task { try await transport.download(Self.url, to: destination("a.bin")) { _ in } }
        await expectEventually { StubURLProtocol.requestCount == 1 }
        transport.cancel()
        let firstError = await result(of: first)
        requireError(firstError, { if case .cancelled = $0 { return true }; return false },
                     "cancelled")

        let small = Data(repeating: 9, count: 1_024)
        StubURLProtocol.install { _ in .init(body: small, chunkSize: 256) }
        try await transport.download(Self.url, to: destination("b.bin")) { _ in }
        XCTAssertEqual(try Data(contentsOf: destination("b.bin")), small)
        transport.invalidate()
    }

    func testSwiftTaskCancellationTerminatesDownload() async {
        let payload = Data(repeating: 5, count: 400_000)
        StubURLProtocol.install { _ in .init(body: payload, chunkSize: 512, chunkDelay: 0.005) }
        let transport = makeTransport()
        let task = Task { try await transport.download(Self.url, to: destination()) { _ in } }
        await expectEventually { StubURLProtocol.requestCount == 1 }
        task.cancel()
        let error = await result(of: task)
        requireError(error, { if case .cancelled = $0 { return true }; return false },
                     "cancelled")
        transport.invalidate()
    }

    func testStallWatchdogThrowsStalled() async {
        let payload = Data(repeating: 4, count: 200_000)
        StubURLProtocol.install { _ in
            .init(body: payload, chunkSize: 256, chunkDelay: 0.001, stallAfterBytes: 1_024)
        }
        let transport = makeTransport(stallLimit: .milliseconds(400))
        let error = await result(of: Task {
            try await transport.download(Self.url, to: destination()) { _ in }
        })
        requireError(error, { if case .stalled = $0 { return true }; return false }, "stalled")
        XCTAssertEqual(StubURLProtocol.requestCount, 1)
        transport.invalidate()
    }

    func testPauseCancelsInFlightDownload() async throws {
        let payload = Data((0..<60_000).map { UInt8($0 % 251) })
        StubURLProtocol.install { _ in .init(body: payload, chunkSize: 2_048, chunkDelay: 0.01) }
        let transport = makeTransport()
        let progressed = Locked(false)
        let download = Task {
            try await transport.download(Self.url, to: destination("paused.bin")) { _ in
                progressed.withLock { $0 = true }
            }
        }
        await expectEventually { progressed.get() }
        let producedResumeData = await transport.pause()
        let resumeData = try XCTUnwrap(producedResumeData)
        let error = await result(of: download)
        requireError(error, { if case .cancelled = $0 { return true }; return false }, "cancelled")
        try await transport.resume(with: resumeData, to: destination("resumed.bin")) { _ in }
        XCTAssertEqual(try Data(contentsOf: destination("resumed.bin")), payload)
        transport.invalidate()
    }

    private final class PauseAdapter: NetworkPausable, @unchecked Sendable {
        let transport: URLSessionDownloadTransport
        let destination: URL
        let resumed = Locked(false)
        let resumeData = Locked<Data?>(nil)
        let resumeError = Locked<(any Error)?>(nil)
        private let tail = Locked<Task<Void, Never>?>(nil)

        init(transport: URLSessionDownloadTransport, destination: URL) {
            self.transport = transport
            self.destination = destination
        }

        func pauseNetworkActivity() async {
            await enqueue {
                let data = await self.transport.pause()
                self.resumeData.withLock { $0 = data }
            }
        }

        func resumeNetworkActivity() async {
            await enqueue {
                guard let data = self.resumeData.get() else { return }
                do {
                    try await self.transport.resume(with: data, to: self.destination) { _ in }
                } catch {
                    self.resumeError.withLock { $0 = error }
                }
                self.resumed.withLock { $0 = true }
            }
        }

        private func enqueue(_ work: @escaping @Sendable () async -> Void) async {
            let next = tail.withLock { current -> Task<Void, Never> in
                let previous = current
                let task = Task {
                    await previous?.value
                    await work()
                }
                current = task
                return task
            }
            await next.value
        }
    }

    func testSessionPausesAndResumesInFlightDownload() async throws {
        let payload = Data((0..<60_000).map { UInt8($0 % 251) })
        StubURLProtocol.install { _ in .init(body: payload, chunkSize: 2_048, chunkDelay: 0.01) }
        let coordinator = NetworkActivityCoordinator()
        let transport = makeTransport(gate: coordinator.sessionGate)
        let adapter = PauseAdapter(transport: transport, destination: destination("resumed.bin"))
        coordinator.register(adapter)

        let progressed = Locked(false)
        let download = Task {
            try await transport.download(Self.url, to: destination("partial.bin")) { _ in
                progressed.withLock { $0 = true }
            }
        }
        await expectEventually { progressed.get() }
        coordinator.beginDictationSession()
        let error = await result(of: download)
        requireError(error, { if case .cancelled = $0 { return true }; return false }, "cancelled")
        coordinator.endDictationSession()
        _ = try XCTUnwrap(adapter.resumeData.get())
        await expectEventually { adapter.resumed.get() }
        XCTAssertNil(adapter.resumeError.get().map { "\($0)" })
        XCTAssertEqual(try Data(contentsOf: destination("resumed.bin")), payload)
        transport.invalidate()
    }
}
