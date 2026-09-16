import CryptoKit
import XCTest
@testable import GoatVoicePlatform

final class FakeNetworkTransport: NetworkTransport, @unchecked Sendable {
    enum FakeError: Error { case unscripted, injected }

    private struct Script {
        var payload: Data
        var chunkSize: Int
        var chunkDelayNanos: UInt64
        var error: Error?
        var stall: Bool
    }

    private let lock = NSLock()
    private var scripts: [URL: Script] = [:]
    private var cancelled = false
    private var lastURL: URL?
    var pauseReturnsResumeData = true

    private(set) var downloadCalls = 0
    private(set) var resumeCalls = 0
    private(set) var pauseCalls = 0
    private(set) var cancelCalls = 0

    func script(url: URL, payload: Data, chunkSize: Int = 64,
                chunkDelayNanos: UInt64 = 2_000_000, stall: Bool = false) {
        lock.lock()
        scripts[url] = Script(payload: payload, chunkSize: chunkSize,
                              chunkDelayNanos: chunkDelayNanos, error: nil, stall: stall)
        lock.unlock()
    }

    func scriptError(url: URL, error: Error = FakeError.injected) {
        lock.lock()
        scripts[url] = Script(payload: Data(), chunkSize: 64, chunkDelayNanos: 0,
                              error: error, stall: false)
        lock.unlock()
    }

    func download(_ url: URL, to destination: URL,
                  progress: @escaping @Sendable (Int64) -> Void) async throws {
        try await run(script: beginDownload(url), to: destination, progress: progress)
    }

    func resume(with resumeData: Data, to destination: URL,
                progress: @escaping @Sendable (Int64) -> Void) async throws {
        try await run(script: beginResume(), to: destination, progress: progress)
    }

    func pause() async -> Data? {
        markPaused()
        return pauseReturnsResumeData ? Data("resume-token".utf8) : nil
    }

    func cancel() {
        lock.lock()
        cancelCalls += 1
        cancelled = true
        lock.unlock()
    }

    private func beginDownload(_ url: URL) -> Script? {
        lock.lock()
        defer { lock.unlock() }
        downloadCalls += 1
        cancelled = false
        lastURL = url
        return scripts[url]
    }

    private func beginResume() -> Script? {
        lock.lock()
        defer { lock.unlock() }
        resumeCalls += 1
        cancelled = false
        return lastURL.flatMap { scripts[$0] }
    }

    private func markPaused() {
        lock.lock()
        pauseCalls += 1
        cancelled = true
        lock.unlock()
    }

    private func run(script: Script?, to destination: URL,
                     progress: @escaping @Sendable (Int64) -> Void) async throws {
        guard let script else { throw FakeError.unscripted }
        if let error = script.error { throw error }
        if script.stall {
            while true {
                try throwIfCancelled()
                try await Task.sleep(nanoseconds: 5_000_000)
            }
        }
        guard FileManager.default.createFile(atPath: destination.path, contents: nil),
              let handle = try? FileHandle(forWritingTo: destination)
        else { throw FakeError.injected }
        defer { try? handle.close() }
        var written = 0
        while written < script.payload.count {
            try throwIfCancelled()
            let count = min(script.chunkSize, script.payload.count - written)
            try handle.write(contentsOf: script.payload[written..<written + count])
            written += count
            progress(Int64(written))
            if script.chunkDelayNanos > 0 {
                try await Task.sleep(nanoseconds: script.chunkDelayNanos)
            }
        }
    }

    private func throwIfCancelled() throws {
        lock.lock()
        let flag = cancelled
        lock.unlock()
        if flag { throw CancellationError() }
    }
}

final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var events: [ModelDownloadProgress] = []

    func record(_ event: ModelDownloadProgress) {
        lock.lock()
        events.append(event)
        lock.unlock()
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return events.count
    }
}

final class ModelStoreTests: XCTestCase {
    private var workDir: URL!
    private var root: URL!
    private var bundleRoot: URL!
    private var transport: FakeNetworkTransport!
    private var gate: NetworkActivityCoordinator!
    private var store: ModelStore!

    override func setUp() async throws {
        workDir = FileManager.default.temporaryDirectory
            .appending(path: "modelstore-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        root = workDir.appending(path: "Models", directoryHint: .isDirectory)
        bundleRoot = workDir.appending(path: "Bundle", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: bundleRoot.appending(path: "Models", directoryHint: .isDirectory),
            withIntermediateDirectories: true)
        transport = FakeNetworkTransport()
        gate = NetworkActivityCoordinator()
        store = ModelStore(rootDirectory: root,
                           transport: transport,
                           gate: gate,
                           stallLimit: .milliseconds(400),
                           bundleResourceRoot: bundleRoot)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: workDir)
    }

    private func sha(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func remoteArtifact(path: String, url: URL, payload: Data,
                                byteCount: Int? = nil, sha256Hex: String? = nil) -> ModelArtifact {
        ModelArtifact(relativePath: path, downloadURL: url,
                      sha256Hex: sha256Hex ?? sha(payload),
                      byteCount: byteCount ?? payload.count)
    }

    private func manifest(id: String = "model-a", version: String = "1.0",
                          artifacts: [ModelArtifact]) -> ModelManifest {
        ModelManifest(modelID: id, version: version, artifacts: artifacts)
    }

    private func https(_ string: String = "https://cdn.example.test/artifact.bin") -> URL {
        URL(string: string)!
    }

    private func stagingEntries() -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: root.path))?
            .filter { $0.contains(".staging-") || $0.contains(".replaced-") } ?? []
    }

    private func eventually(_ predicate: @escaping () async -> Bool,
                            timeout: TimeInterval = 5) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await predicate() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return await predicate()
    }

    private func assertThrows<T: Equatable & Error>(_ expected: T,
                                                    _ expression: () async throws -> some Any,
                                                    file: StaticString = #filePath,
                                                    line: UInt = #line) async {
        do {
            _ = try await expression()
            XCTFail("expected \(expected)", file: file, line: line)
        } catch let error as T {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("expected \(expected), got \(error)", file: file, line: line)
        }
    }

    func testInstallVerifiesAndInstallsAtomically() async throws {
        let url = https()
        let payload = Data(repeating: 0xAB, count: 512)
        transport.script(url: url, payload: payload)
        let m = manifest(artifacts: [
            remoteArtifact(path: "weights/model.bin", url: url, payload: payload)
        ])
        let log = ProgressLog()
        try await store.install(m) { log.record($0) }

        let installed = root.appending(path: "model-a/weights/model.bin")
        XCTAssertEqual(try Data(contentsOf: installed), payload)
        let state = await store.state(for: m)
        XCTAssertEqual(state, .installed(version: "1.0"))
        let installedDir = await store.installedModelDirectory(for: "model-a")
        XCTAssertEqual(installedDir,
                       root.appending(path: "model-a", directoryHint: .isDirectory))
        XCTAssertTrue(stagingEntries().isEmpty)
        XCTAssertEqual(transport.downloadCalls, 1)
        XCTAssertEqual(log.events.last?.phase, .verifying)
        XCTAssertEqual(log.events.last?.expectedBytes, Int64(payload.count))
    }

    func testOversizedTransferIsCancelledBeforeCompletion() async {
        let url = https()
        let payload = Data(repeating: 0x31, count: 4_096)
        transport.script(url: url, payload: payload, chunkSize: 32)
        let item = manifest(artifacts: [
            remoteArtifact(path: "weights.bin", url: url, payload: payload, byteCount: 64)
        ])
        do {
            try await store.install(item) { _ in }
            XCTFail("Expected oversized transfer rejection")
        } catch ModelStoreError.sizeMismatch(let artifact) {
            XCTAssertEqual(artifact, "weights.bin")
            XCTAssertGreaterThan(transport.cancelCalls, 0)
            XCTAssertTrue(stagingEntries().isEmpty)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testHashMismatchFailsInstallAndCleansStaging() async {
        let url = https()
        let payload = Data(repeating: 1, count: 256)
        transport.script(url: url, payload: payload)
        let wrong = String(repeating: "0", count: 64)
        let m = manifest(artifacts: [
            remoteArtifact(path: "model.bin", url: url, payload: payload, sha256Hex: wrong)
        ])
        do {
            try await store.install(m) { _ in }
            XCTFail("expected hashMismatch")
        } catch ModelStoreError.hashMismatch(let artifact) {
            XCTAssertEqual(artifact, "model.bin")
        } catch {
            XCTFail("unexpected \(error)")
        }
        let state = await store.state(for: m)
        XCTAssertEqual(state, .notInstalled)
        XCTAssertTrue(stagingEntries().isEmpty)
    }

    func testSizeMismatchFailsInstall() async {
        let url = https()
        let payload = Data(repeating: 2, count: 128)
        transport.script(url: url, payload: payload)
        let m = manifest(artifacts: [
            remoteArtifact(path: "model.bin", url: url, payload: payload,
                           byteCount: payload.count + 16)
        ])
        do {
            try await store.install(m) { _ in }
            XCTFail("expected sizeMismatch")
        } catch ModelStoreError.sizeMismatch(let artifact) {
            XCTAssertEqual(artifact, "model.bin")
        } catch {
            XCTFail("unexpected \(error)")
        }
        XCTAssertTrue(stagingEntries().isEmpty)
    }

    func testPartialFailureLeavesNoInstall() async {
        let good = https("https://cdn.example.test/good.bin")
        let bad = https("https://cdn.example.test/bad.bin")
        transport.script(url: good, payload: Data(repeating: 3, count: 200))
        transport.scriptError(url: bad)
        let m = manifest(artifacts: [
            remoteArtifact(path: "a.bin", url: good, payload: Data(repeating: 3, count: 200)),
            remoteArtifact(path: "b.bin", url: bad, payload: Data(repeating: 4, count: 100)),
        ])
        do {
            try await store.install(m) { _ in }
            XCTFail("expected downloadFailed")
        } catch ModelStoreError.downloadFailed {
        } catch {
            XCTFail("unexpected \(error)")
        }
        let state = await store.state(for: m)
        XCTAssertEqual(state, .notInstalled)
        XCTAssertTrue(stagingEntries().isEmpty)
        let installedDir = await store.installedModelDirectory(for: "model-a")
        XCTAssertNil(installedDir)
    }

    func testFailedUpgradePreservesExistingInstall() async throws {
        let url = https()
        let v1Payload = Data(repeating: 9, count: 300)
        transport.script(url: url, payload: v1Payload)
        let v1 = manifest(version: "1.0", artifacts: [
            remoteArtifact(path: "model.bin", url: url, payload: v1Payload)
        ])
        try await store.install(v1) { _ in }
        let v1State = await store.state(for: v1)
        XCTAssertEqual(v1State, .installed(version: "1.0"))

        let v2 = manifest(version: "2.0", artifacts: [
            remoteArtifact(path: "model.bin", url: url, payload: v1Payload,
                           sha256Hex: String(repeating: "f", count: 64))
        ])
        do {
            try await store.install(v2) { _ in }
            XCTFail("expected hashMismatch")
        } catch ModelStoreError.hashMismatch {
        } catch {
            XCTFail("unexpected \(error)")
        }
        let keptState = await store.state(for: v1)
        XCTAssertEqual(keptState, .installed(version: "1.0"))
        let stillValid = await store.verifyInstalled(v1)
        XCTAssertTrue(stillValid)
        XCTAssertEqual(
            try Data(contentsOf: root.appending(path: "model-a/model.bin")), v1Payload)
        XCTAssertTrue(stagingEntries().isEmpty)
    }

    func testVerifyInstalledDetectsCorruption() async throws {
        let url = https()
        let payload = Data(repeating: 5, count: 256)
        transport.script(url: url, payload: payload)
        let m = manifest(artifacts: [
            remoteArtifact(path: "model.bin", url: url, payload: payload)
        ])
        try await store.install(m) { _ in }
        let intact = await store.verifyInstalled(m)
        XCTAssertTrue(intact)

        let file = root.appending(path: "model-a/model.bin")
        try Data(repeating: 0xFF, count: 1).write(to: file, options: .atomic)
        let afterCorruption = await store.verifyInstalled(m)
        XCTAssertFalse(afterCorruption)
    }

    func testVerifyInstalledRejectsSymlinkedArtifact() async throws {
        let url = https()
        let payload = Data(repeating: 6, count: 64)
        transport.script(url: url, payload: payload)
        let m = manifest(artifacts: [
            remoteArtifact(path: "model.bin", url: url, payload: payload)
        ])
        try await store.install(m) { _ in }

        let file = root.appending(path: "model-a/model.bin")
        let outside = workDir.appending(path: "outside.bin")
        try payload.write(to: outside)
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: outside)
        let verified = await store.verifyInstalled(m)
        XCTAssertFalse(verified)
    }

    func testBundleResourceInstallsAndVerifies() async throws {
        let payload = Data(repeating: 0xCD, count: 1_000)
        try payload.write(to: bundleRoot.appending(path: "Models/tokenizer.json"))
        let m = manifest(artifacts: [
            ModelArtifact(relativePath: "tokenizer.json",
                          downloadURL: URL(string: "bundle://Models/tokenizer.json")!,
                          sha256Hex: sha(payload), byteCount: payload.count)
        ])
        try await store.install(m) { _ in }
        let state = await store.state(for: m)
        XCTAssertEqual(state, .installed(version: "1.0"))
        XCTAssertEqual(
            try Data(contentsOf: root.appending(path: "model-a/tokenizer.json")), payload)
    }

    func testBundleMissingResourceFails() async {
        let m = manifest(artifacts: [
            ModelArtifact(relativePath: "missing.json",
                          downloadURL: URL(string: "bundle://Models/missing.json")!,
                          sha256Hex: String(repeating: "a", count: 64), byteCount: 10)
        ])
        do {
            try await store.install(m) { _ in }
            XCTFail("expected downloadFailed")
        } catch ModelStoreError.downloadFailed {
        } catch {
            XCTFail("unexpected \(error)")
        }
        XCTAssertTrue(stagingEntries().isEmpty)
    }

    func testBundleHashMismatchFails() async throws {
        try Data(repeating: 7, count: 32)
            .write(to: bundleRoot.appending(path: "Models/bad.json"))
        let m = manifest(artifacts: [
            ModelArtifact(relativePath: "bad.json",
                          downloadURL: URL(string: "bundle://Models/bad.json")!,
                          sha256Hex: String(repeating: "b", count: 64), byteCount: 32)
        ])
        do {
            try await store.install(m) { _ in }
            XCTFail("expected hashMismatch")
        } catch ModelStoreError.hashMismatch(let artifact) {
            XCTAssertEqual(artifact, "bad.json")
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func testMixedRemoteAndBundleInstallAtomic() async throws {
        let url = https()
        let remotePayload = Data(repeating: 8, count: 400)
        let bundlePayload = Data(repeating: 9, count: 120)
        transport.script(url: url, payload: remotePayload)
        try bundlePayload.write(to: bundleRoot.appending(path: "Models/tok.json"))
        let m = manifest(artifacts: [
            remoteArtifact(path: "model.bin", url: url, payload: remotePayload),
            ModelArtifact(relativePath: "tokenizer.json",
                          downloadURL: URL(string: "bundle://Models/tok.json")!,
                          sha256Hex: sha(bundlePayload), byteCount: bundlePayload.count),
        ])
        try await store.install(m) { _ in }
        let verified = await store.verifyInstalled(m)
        XCTAssertTrue(verified)
    }

    func testUnsafeModelIDsRejected() async {
        for id in ["", "../evil", "a/b", ".", "..", ".hidden", "a b", "x\\y"] {
            let m = manifest(id: id, artifacts: [
                remoteArtifact(path: "f.bin", url: https(), payload: Data([1]))
            ])
            do {
                try await store.install(m) { _ in }
                XCTFail("expected invalidManifest for id \(id)")
            } catch ModelStoreError.invalidManifest(.unsafeModelID(let bad)) {
                XCTAssertEqual(bad, id)
            } catch {
                XCTFail("unexpected \(error) for id \(id)")
            }
        }
    }

    func testTraversalAndUnsafeRelativePathsRejected() async {
        for path in ["../x", "a/../b", "/abs", "a//b", ".", "..", "a/.", "a/./b",
                     "a/b/../c", "x/%2e%2e/y", "sub/../../escape",
                     ".voice-install.json", "a\\b", "a:b"] {
            let m = manifest(artifacts: [
                remoteArtifact(path: path, url: https(), payload: Data([1]))
            ])
            do {
                try await store.install(m) { _ in }
                XCTFail("expected invalidManifest for path \(path)")
            } catch ModelStoreError.invalidManifest(.unsafeRelativePath(let bad)) {
                XCTAssertEqual(bad, path)
            } catch {
                XCTFail("unexpected \(error) for path \(path)")
            }
        }
    }

    func testDottedSuffixComponentsAreValidPaths() async throws {
        let url = https()
        let payload = Data(repeating: 0x12, count: 128)
        transport.script(url: url, payload: payload)
        let m = manifest(artifacts: [
            remoteArtifact(path: "a/b..", url: url, payload: payload)
        ])
        try await store.install(m) { _ in }
        XCTAssertEqual(
            try Data(contentsOf: root.appending(path: "model-a/a/b..")), payload)
        let state = await store.state(for: m)
        XCTAssertEqual(state, .installed(version: "1.0"))
    }

    func testDuplicateRelativePathsRejected() async {
        let m = manifest(artifacts: [
            remoteArtifact(path: "dup.bin", url: https(), payload: Data([1])),
            remoteArtifact(path: "dup.bin",
                           url: https("https://cdn.example.test/other.bin"),
                           payload: Data([2])),
        ])
        do {
            try await store.install(m) { _ in }
            XCTFail("expected duplicateRelativePath")
        } catch ModelStoreError.invalidManifest(.duplicateRelativePath(let path)) {
            XCTAssertEqual(path, "dup.bin")
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func testNonPositiveByteCountAndBadHashRejected() async {
        let zero = manifest(artifacts: [
            remoteArtifact(path: "f.bin", url: https(), payload: Data([1]), byteCount: 0)
        ])
        do {
            try await store.install(zero) { _ in }
            XCTFail("expected nonPositiveByteCount")
        } catch ModelStoreError.invalidManifest(.nonPositiveByteCount) {
        } catch {
            XCTFail("unexpected \(error)")
        }
        let badHash = manifest(artifacts: [
            remoteArtifact(path: "f.bin", url: https(), payload: Data([1]),
                           sha256Hex: "nothex")
        ])
        do {
            try await store.install(badHash) { _ in }
            XCTFail("expected invalidSHA256")
        } catch ModelStoreError.invalidManifest(.invalidSHA256) {
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func testTotalSizeOverflowRejected() async {
        let m = manifest(artifacts: [
            remoteArtifact(path: "a.bin", url: https(), payload: Data([1]),
                           byteCount: Int.max),
            remoteArtifact(path: "b.bin", url: https(), payload: Data([1]),
                           byteCount: Int.max),
        ])
        do {
            try await store.install(m) { _ in }
            XCTFail("expected totalSizeOverflow")
        } catch ModelStoreError.invalidManifest(.totalSizeOverflow) {
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func testUnsupportedSchemesAndBadBundleURLsRejected() async {
        let cases: [(String, ModelManifestRejection)] = [
            ("file:///etc/passwd", .unsupportedDownloadScheme(artifact: "f.bin")),
            ("http://cdn.example.test/x", .unsupportedDownloadScheme(artifact: "f.bin")),
            ("bundle://Other/x.json", .invalidBundleResource(artifact: "f.bin")),
            ("bundle://Models/sub/x.json", .invalidBundleResource(artifact: "f.bin")),
            ("bundle://Models/../x.json", .invalidBundleResource(artifact: "f.bin")),
            ("bundle://Models/%2e%2e", .invalidBundleResource(artifact: "f.bin")),
            ("bundle://Models/", .invalidBundleResource(artifact: "f.bin")),
            ("bundle://Models/x.json?y=1", .invalidBundleResource(artifact: "f.bin")),
            ("https://user:pw@cdn.example.test/x", .insecureRemoteURL(artifact: "f.bin")),
        ]
        for (raw, expected) in cases {
            let m = manifest(artifacts: [
                ModelArtifact(relativePath: "f.bin", downloadURL: URL(string: raw)!,
                              sha256Hex: String(repeating: "a", count: 64), byteCount: 4)
            ])
            do {
                try await store.install(m) { _ in }
                XCTFail("expected \(expected) for \(raw)")
            } catch ModelStoreError.invalidManifest(let rejection) {
                XCTAssertEqual(rejection, expected, "for \(raw)")
            } catch {
                XCTFail("unexpected \(error) for \(raw)")
            }
        }
    }

    func testInstallBlockedWhileDictationActive() async {
        gate.beginDictationSession()
        let m = manifest(artifacts: [
            remoteArtifact(path: "f.bin", url: https(), payload: Data([1]))
        ])
        do {
            try await store.install(m) { _ in }
            XCTFail("expected blockedByActiveSession")
        } catch ModelStoreError.blockedByActiveSession {
        } catch {
            XCTFail("unexpected \(error)")
        }
        XCTAssertEqual(transport.downloadCalls, 0)
        gate.endDictationSession()
    }

    func testDictationPausesInFlightDownloadAndResumeAfterEnd() async throws {
        let url = https()
        let payload = Data(repeating: 0x11, count: 8_192)
        transport.script(url: url, payload: payload, chunkSize: 64,
                         chunkDelayNanos: 3_000_000)
        gate.register(store)
        let m = manifest(artifacts: [
            remoteArtifact(path: "model.bin", url: url, payload: payload)
        ])
        let log = ProgressLog()
        let install = Task { try await store.install(m) { log.record($0) } }

        let started = await eventually { self.transport.downloadCalls > 0 }
        XCTAssertTrue(started)
        gate.beginDictationSession()
        let paused = await eventually { self.transport.pauseCalls > 0 }
        XCTAssertTrue(paused)
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(transport.resumeCalls, 0)

        gate.endDictationSession()
        try await install.value
        XCTAssertEqual(transport.resumeCalls, 1)
        let verified = await store.verifyInstalled(m)
        XCTAssertTrue(verified)
    }

    func testUnregisteredStoreStillPausesWhenDictationStarts() async throws {
        let url = https()
        let payload = Data(repeating: 0x22, count: 8_192)
        transport.script(url: url, payload: payload, chunkSize: 64,
                         chunkDelayNanos: 3_000_000)
        let m = manifest(artifacts: [
            remoteArtifact(path: "model.bin", url: url, payload: payload)
        ])
        let install = Task { try await store.install(m) { _ in } }

        let started = await eventually { self.transport.downloadCalls > 0 }
        XCTAssertTrue(started)
        gate.beginDictationSession()
        let paused = await eventually { self.transport.pauseCalls > 0 }
        XCTAssertTrue(paused)
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(transport.resumeCalls, 0)

        gate.endDictationSession()
        try await install.value
        let verified = await store.verifyInstalled(m)
        XCTAssertTrue(verified)
    }

    func testCancelDownloadAbortsInstall() async throws {
        let url = https()
        transport.script(url: url, payload: Data(repeating: 0x33, count: 8_192),
                         chunkSize: 64, chunkDelayNanos: 3_000_000)
        let m = manifest(artifacts: [
            remoteArtifact(path: "model.bin", url: url,
                           payload: Data(repeating: 0x33, count: 8_192))
        ])
        let install = Task { try await store.install(m) { _ in } }
        let started = await eventually { self.transport.downloadCalls > 0 }
        XCTAssertTrue(started)
        await store.cancelDownload()
        do {
            try await install.value
            XCTFail("expected cancelled")
        } catch ModelStoreError.cancelled {
        } catch {
            XCTFail("unexpected \(error)")
        }
        XCTAssertGreaterThanOrEqual(transport.cancelCalls, 1)
        XCTAssertTrue(stagingEntries().isEmpty)
        let state = await store.state(for: m)
        XCTAssertEqual(state, .notInstalled)
    }

    func testPauseWithoutResumeDataRestartsArtifact() async throws {
        let url = https()
        let payload = Data(repeating: 0x44, count: 8_192)
        transport.script(url: url, payload: payload, chunkSize: 64,
                         chunkDelayNanos: 3_000_000)
        transport.pauseReturnsResumeData = false
        let m = manifest(artifacts: [
            remoteArtifact(path: "model.bin", url: url, payload: payload)
        ])
        let install = Task { try await store.install(m) { _ in } }
        let started = await eventually { self.transport.downloadCalls > 0 }
        XCTAssertTrue(started)
        await store.pauseDownload()
        let paused = await eventually { self.transport.pauseCalls > 0 }
        XCTAssertTrue(paused)
        await store.resumeDownload()
        try await install.value
        XCTAssertEqual(transport.downloadCalls, 2)
        XCTAssertEqual(transport.resumeCalls, 0)
        let verified = await store.verifyInstalled(m)
        XCTAssertTrue(verified)
    }

    func testStallWatchdogFailsDownload() async {
        let url = https()
        transport.script(url: url, payload: Data(repeating: 0x99, count: 1_000), stall: true)
        let m = manifest(artifacts: [
            remoteArtifact(path: "model.bin", url: url, payload: Data(repeating: 0x99, count: 1_000))
        ])
        do {
            try await store.install(m) { _ in }
            XCTFail("expected stalled")
        } catch ModelStoreError.stalled {
        } catch {
            XCTFail("unexpected \(error)")
        }
        XCTAssertGreaterThanOrEqual(transport.cancelCalls, 1)
    }

    func testConcurrentInstallThrowsBusy() async throws {
        let url = https()
        let payload = Data(repeating: 0x55, count: 8_192)
        transport.script(url: url, payload: payload, chunkSize: 64,
                         chunkDelayNanos: 3_000_000)
        let m = manifest(artifacts: [
            remoteArtifact(path: "model.bin", url: url, payload: payload)
        ])
        let first = Task { try await store.install(m) { _ in } }
        let started = await eventually { self.transport.downloadCalls > 0 }
        XCTAssertTrue(started)
        do {
            try await store.install(m) { _ in }
            XCTFail("expected busy")
        } catch ModelStoreError.busy {
        } catch {
            XCTFail("unexpected \(error)")
        }
        try await first.value
    }

    func testRemoveDeletesInstallAndStrays() async throws {
        let url = https()
        let payload = Data(repeating: 0x66, count: 128)
        transport.script(url: url, payload: payload)
        let m = manifest(artifacts: [
            remoteArtifact(path: "model.bin", url: url, payload: payload)
        ])
        try await store.install(m) { _ in }
        let stray = root.appending(path: "model-a.staging-dead", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: stray, withIntermediateDirectories: true)
        try await store.remove(modelID: "model-a")
        let state = await store.state(for: m)
        XCTAssertEqual(state, .notInstalled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stray.path))
        let installedDir = await store.installedModelDirectory(for: "model-a")
        XCTAssertNil(installedDir)
    }

    func testStateCorruptWhenReceiptMissing() async throws {
        let url = https()
        let payload = Data(repeating: 0x77, count: 128)
        transport.script(url: url, payload: payload)
        let m = manifest(artifacts: [
            remoteArtifact(path: "model.bin", url: url, payload: payload)
        ])
        try await store.install(m) { _ in }
        let receipt = root.appending(path: "model-a/.voice-install.json")
        try FileManager.default.removeItem(at: receipt)
        let state = await store.state(for: m)
        XCTAssertEqual(state, .corrupt)
        let verified = await store.verifyInstalled(m)
        XCTAssertFalse(verified)
        let installedDir = await store.installedModelDirectory(for: "model-a")
        XCTAssertNil(installedDir)
    }

    func testProgressReportsDownloadingThenVerifying() async throws {
        let url = https()
        let payload = Data(repeating: 0x88, count: 300)
        transport.script(url: url, payload: payload, chunkSize: 60,
                         chunkDelayNanos: 0)
        let m = manifest(artifacts: [
            remoteArtifact(path: "model.bin", url: url, payload: payload)
        ])
        let log = ProgressLog()
        try await store.install(m) { log.record($0) }
        let events = log.events
        XCTAssertFalse(events.isEmpty)
        XCTAssertTrue(events.allSatisfy { $0.expectedBytes == Int64(payload.count) })
        let downloads = events.filter { $0.phase == .downloading }
        XCTAssertEqual(downloads.last?.completedBytes, Int64(payload.count))
        XCTAssertEqual(events.last?.phase, .verifying)
    }
}
