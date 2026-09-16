import CryptoKit
import Foundation

public actor ModelStore {
    private static let ioChunkSize = 1 << 20
    private static let permitPollInterval = Duration.milliseconds(50)

    private enum PauseSource { case user, coordinator }
    private enum RemoteTransferOutcome { case finished, paused }
    private enum ArtifactIntegrityError: Error {
        case pathEscapesStaging
        case stagedFileNotRegular
        case bundleResourceEscapesRoot
    }

    private struct InstallReceipt: Codable {
        var modelID: String
        var version: String
    }

    private let rootDirectory: URL
    private let bundleResourceRoot: URL
    private let transport: NetworkTransport
    private let gate: NetworkActivityCoordinator
    private let stallLimit: Duration
    private let fileManager: FileManager

    private var transferActive = false
    private var pauseSources = Set<PauseSource>()
    private var cancelRequested = false
    private var resumeData: Data?
    private var verifyingModelID: String?
    private var transferGeneration = 0
    private var inFlightGeneration: Int?
    private var interruptedGeneration: Int?

    public init(rootDirectory: URL,
                transport: NetworkTransport,
                gate: NetworkActivityCoordinator,
                stallLimit: Duration = .seconds(30),
                bundleResourceRoot: URL = Bundle.main.resourceURL ?? Bundle.main.bundleURL,
                fileManager: FileManager = .default) {
        self.rootDirectory = rootDirectory
        self.transport = transport
        self.gate = gate
        self.stallLimit = stallLimit
        self.bundleResourceRoot = bundleResourceRoot
        self.fileManager = fileManager
    }

    public func state(for manifest: ModelManifest) -> ModelInstallState {
        if verifyingModelID == manifest.modelID { return .verifying }
        guard (try? ModelManifestValidator.checkModelID(manifest.modelID)) != nil else {
            return .notInstalled
        }
        let final = finalDirectory(for: manifest.modelID)
        guard isDirectory(final) else { return .notInstalled }
        guard let receipt = readReceipt(modelID: manifest.modelID),
              receipt.modelID == manifest.modelID
        else { return .corrupt }
        return .installed(version: receipt.version)
    }

    public func installedModelDirectory(for modelID: String) -> URL? {
        guard (try? ModelManifestValidator.checkModelID(modelID)) != nil else { return nil }
        let final = finalDirectory(for: modelID)
        guard isDirectory(final), readReceipt(modelID: modelID) != nil else { return nil }
        return final
    }

    public func install(_ manifest: ModelManifest,
                        progress: @escaping @Sendable (ModelDownloadProgress) -> Void) async throws {
        let checked = try ModelManifestValidator.check(manifest)
        guard !transferActive else { throw ModelStoreError.busy }
        transferActive = true
        cancelRequested = false
        pauseSources = []
        resumeData = nil

        let staging = stagingDirectory(for: checked.modelID)
        defer {
            transferActive = false
            pauseSources = []
            resumeData = nil
            verifyingModelID = nil
            inFlightGeneration = nil
            interruptedGeneration = nil
            try? fileManager.removeItem(at: staging)
        }

        guard gate.allowsNewNetworkWork else {
            throw ModelStoreError.blockedByActiveSession
        }

        do {
            try fileManager.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
        } catch {
            throw ModelStoreError.installFailed(underlying: error)
        }
        try? fileManager.removeItem(at: staging)
        do {
            try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        } catch {
            throw ModelStoreError.installFailed(underlying: error)
        }

        var completedBase: Int64 = 0
        for item in checked.artifacts {
            try await transfer(item, into: staging,
                               base: completedBase, total: checked.totalBytes,
                               progress: progress)
            verifyingModelID = checked.modelID
            progress(ModelDownloadProgress(completedBytes: completedBase,
                                           expectedBytes: checked.totalBytes,
                                           phase: .verifying))
            try await verifyStagedArtifact(item, in: staging)
            verifyingModelID = nil
            completedBase += Int64(item.artifact.byteCount)
        }
        if cancelRequested || Task.isCancelled { throw ModelStoreError.cancelled }
        do {
            try writeReceipt(modelID: checked.modelID, version: checked.version, into: staging)
            try swap(staging: staging, modelID: checked.modelID)
        } catch let error as ModelStoreError {
            throw error
        } catch {
            throw ModelStoreError.installFailed(underlying: error)
        }
    }

    public func pauseDownload() async {
        await pauseActivity(.user)
    }

    public func resumeDownload() async {
        pauseSources.remove(.user)
    }

    public func cancelDownload() async {
        guard transferActive else { return }
        cancelRequested = true
        transport.cancel()
    }

    public func verifyInstalled(_ manifest: ModelManifest) async -> Bool {
        guard let checked = try? ModelManifestValidator.check(manifest) else { return false }
        let final = finalDirectory(for: checked.modelID)
        guard isDirectory(final),
              let receipt = readReceipt(modelID: checked.modelID),
              receipt.version == checked.version
        else { return false }
        for item in checked.artifacts {
            guard let url = try? resolveInside(final, item.artifact.relativePath),
                  stagedFileIsSound(url, byteCount: item.artifact.byteCount),
                  let digest = try? await sha256Hex(of: url),
                  digest == item.sha256HexLowercase
            else { return false }
        }
        return true
    }

    public func remove(modelID: String) throws {
        try ModelManifestValidator.checkModelID(modelID)
        guard !transferActive else { throw ModelStoreError.busy }
        try? fileManager.removeItem(at: finalDirectory(for: modelID))
        guard let entries = try? fileManager.contentsOfDirectory(atPath: rootDirectory.path)
        else { return }
        for entry in entries
        where entry.hasPrefix("\(modelID).staging-") || entry.hasPrefix("\(modelID).replaced-") {
            try? fileManager.removeItem(at: rootDirectory.appending(path: entry))
        }
    }

    private func pauseActivity(_ source: PauseSource) async {
        guard transferActive else { return }
        let wasPaused = !pauseSources.isEmpty
        pauseSources.insert(source)
        guard !wasPaused else { return }
        if let generation = inFlightGeneration {
            interruptedGeneration = generation
        }
        if let data = await transport.pause() {
            resumeData = data
        }
    }

    private func consumeResumeData() -> Data? {
        defer { resumeData = nil }
        return resumeData
    }

    private func waitForNetworkPermit() async throws {
        while true {
            if cancelRequested || Task.isCancelled {
                transport.cancel()
                throw ModelStoreError.cancelled
            }
            if gate.allowsNewNetworkWork {
                pauseSources.remove(.coordinator)
                if pauseSources.isEmpty { return }
            }
            do {
                try await ContinuousClock().sleep(for: Self.permitPollInterval)
            } catch {
                transport.cancel()
                throw ModelStoreError.cancelled
            }
        }
    }

    private func transfer(_ item: CheckedArtifact, into staging: URL,
                          base: Int64, total: Int64,
                          progress: @escaping @Sendable (ModelDownloadProgress) -> Void) async throws {
        let destination = try resolveInside(staging, item.artifact.relativePath)
        do {
            try fileManager.createDirectory(at: destination.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
        } catch {
            throw ModelStoreError.installFailed(underlying: error)
        }
        try? fileManager.removeItem(at: destination)
        resumeData = nil

        switch item.source {
        case .bundledResource(let filename):
            try await copyBundledResource(filename, to: destination,
                                          declaredBytes: Int64(item.artifact.byteCount),
                                          base: base, total: total, progress: progress)
        case .remote(let url):
            while true {
                try await waitForNetworkPermit()
                let outcome = try await runRemoteTransfer(
                    url: url, resumeData: consumeResumeData(), to: destination,
                    byteLimit: Int64(item.artifact.byteCount), artifactPath: item.artifact.relativePath,
                    base: base, total: total, progress: progress)
                if outcome == .finished { return }
            }
        }
    }

    private func runRemoteTransfer(url: URL, resumeData pending: Data?, to destination: URL,
                                   byteLimit: Int64, artifactPath: String,
                                   base: Int64, total: Int64,
                                   progress: @escaping @Sendable (ModelDownloadProgress) -> Void)
        async throws -> RemoteTransferOutcome {
        transferGeneration &+= 1
        let generation = transferGeneration
        inFlightGeneration = generation
        defer {
            if inFlightGeneration == generation { inFlightGeneration = nil }
        }
        let mark = ByteProgressMark()
        let report: @Sendable (Int64) -> Void = { [transport] bytes in
            guard bytes >= 0, bytes <= byteLimit else {
                mark.noteOversized()
                transport.cancel()
                return
            }
            mark.record(bytes)
            progress(ModelDownloadProgress(completedBytes: base + bytes,
                                           expectedBytes: total,
                                           phase: .downloading))
        }
        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask { [transport] in
                    if let pending {
                        try await transport.resume(with: pending, to: destination,
                                                   progress: report)
                    } else {
                        try await transport.download(url, to: destination, progress: report)
                    }
                }
                group.addTask { [transport, gate, stallLimit] in
                    let clock = ContinuousClock()
                    while true {
                        try await clock.sleep(for: self.monitorQuantum)
                        if !gate.allowsNewNetworkWork {
                            await self.pauseActivity(.coordinator)
                        }
                        if mark.silenceDuration(at: clock.now) >= stallLimit {
                            mark.noteStalled()
                            transport.cancel()
                            throw ModelStoreError.stalled
                        }
                    }
                }
                _ = try await group.next()
                group.cancelAll()
            }
            if mark.isOversized { throw ModelStoreError.sizeMismatch(artifact: artifactPath) }
            return .finished
        } catch let error as ModelStoreError {
            throw error
        } catch {
            if mark.isOversized { throw ModelStoreError.sizeMismatch(artifact: artifactPath) }
            if mark.isStalled { throw ModelStoreError.stalled }
            if cancelRequested || Task.isCancelled { throw ModelStoreError.cancelled }
            if interruptedGeneration == generation {
                interruptedGeneration = nil
                return .paused
            }
            if let transportError = error as? NetworkTransportError {
                switch transportError {
                case .blockedByActiveSession:
                    return .paused
                case .stalled:
                    throw ModelStoreError.stalled
                default:
                    break
                }
            }
            throw ModelStoreError.downloadFailed(underlying: error)
        }
    }

    private var monitorQuantum: Duration {
        min(max(stallLimit / 8, .milliseconds(10)), .seconds(5))
    }

    private func copyBundledResource(_ filename: String, to destination: URL,
                                     declaredBytes: Int64, base: Int64, total: Int64,
                                     progress: @escaping @Sendable (ModelDownloadProgress) -> Void)
        async throws {
        let modelsRoot = bundleResourceRoot.appending(
            path: ModelManifestValidator.bundleHost, directoryHint: .isDirectory)
        let source = modelsRoot.appending(path: filename, directoryHint: .notDirectory)
        let resolvedRoot = modelsRoot.resolvingSymlinksInPath().standardizedFileURL
        let resolvedSource = source.resolvingSymlinksInPath().standardizedFileURL
        guard resolvedSource.path.hasPrefix(resolvedRoot.path + "/") else {
            throw ModelStoreError.installFailed(
                underlying: ArtifactIntegrityError.bundleResourceEscapesRoot)
        }
        let input: FileHandle
        do {
            input = try FileHandle(forReadingFrom: source)
        } catch {
            throw ModelStoreError.downloadFailed(underlying: error)
        }
        defer { try? input.close() }
        guard fileManager.createFile(atPath: destination.path, contents: nil) else {
            throw ModelStoreError.downloadFailed(underlying: CocoaError(.fileWriteUnknown))
        }
        let output: FileHandle
        do {
            output = try FileHandle(forWritingTo: destination)
        } catch {
            throw ModelStoreError.downloadFailed(underlying: error)
        }
        defer { try? output.close() }
        var written: Int64 = 0
        while written <= declaredBytes {
            if cancelRequested || Task.isCancelled { throw ModelStoreError.cancelled }
            let budget = Int(declaredBytes + 1 - written)
            let chunk: Data
            do {
                chunk = try input.read(upToCount: min(Self.ioChunkSize, budget)) ?? Data()
            } catch {
                throw ModelStoreError.downloadFailed(underlying: error)
            }
            if chunk.isEmpty { break }
            do {
                try output.write(contentsOf: chunk)
            } catch {
                throw ModelStoreError.downloadFailed(underlying: error)
            }
            written += Int64(chunk.count)
            progress(ModelDownloadProgress(completedBytes: base + written,
                                           expectedBytes: total,
                                           phase: .downloading))
            await Task.yield()
        }
    }

    private func verifyStagedArtifact(_ item: CheckedArtifact, in directory: URL) async throws {
        let url = try resolveInside(directory, item.artifact.relativePath)
        guard stagedFileIsSound(url, byteCount: item.artifact.byteCount) else {
            throw ModelStoreError.sizeMismatch(artifact: item.artifact.relativePath)
        }
        let digest = try await sha256Hex(of: url)
        guard digest == item.sha256HexLowercase else {
            throw ModelStoreError.hashMismatch(artifact: item.artifact.relativePath)
        }
    }

    private func stagedFileIsSound(_ url: URL, byteCount: Int) -> Bool {
        guard let values = try? url.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
            values.isRegularFile == true,
            values.isSymbolicLink != true,
            Int64(values.fileSize ?? -1) == Int64(byteCount)
        else { return false }
        return true
    }

    private func sha256Hex(of url: URL) async throws -> String {
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            throw ModelStoreError.downloadFailed(underlying: error)
        }
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            if cancelRequested || Task.isCancelled { throw ModelStoreError.cancelled }
            let chunk: Data
            do {
                chunk = try handle.read(upToCount: Self.ioChunkSize) ?? Data()
            } catch {
                throw ModelStoreError.downloadFailed(underlying: error)
            }
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
            await Task.yield()
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func resolveInside(_ directory: URL, _ relativePath: String) throws -> URL {
        let base = directory.standardizedFileURL
        let resolved = directory.appending(path: relativePath).standardizedFileURL
        guard resolved.path.hasPrefix(base.path + "/") else {
            throw ModelStoreError.installFailed(
                underlying: ArtifactIntegrityError.pathEscapesStaging)
        }
        return resolved
    }

    private func swap(staging: URL, modelID: String) throws {
        let final = finalDirectory(for: modelID)
        let backup = rootDirectory.appending(
            path: "\(modelID).replaced-\(UUID().uuidString)", directoryHint: .isDirectory)
        var movedExisting = false
        do {
            if fileManager.fileExists(atPath: final.path) {
                try fileManager.moveItem(at: final, to: backup)
                movedExisting = true
            }
            try fileManager.moveItem(at: staging, to: final)
        } catch {
            if movedExisting, !fileManager.fileExists(atPath: final.path) {
                try? fileManager.moveItem(at: backup, to: final)
            }
            throw ModelStoreError.installFailed(underlying: error)
        }
        try? fileManager.removeItem(at: backup)
    }

    private func writeReceipt(modelID: String, version: String, into directory: URL) throws {
        let receipt = InstallReceipt(modelID: modelID, version: version)
        let data: Data
        do {
            data = try JSONEncoder().encode(receipt)
        } catch {
            throw ModelStoreError.installFailed(underlying: error)
        }
        let url = directory.appending(path: ModelManifestValidator.reservedReceiptName)
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            throw ModelStoreError.installFailed(underlying: error)
        }
    }

    private func readReceipt(modelID: String) -> InstallReceipt? {
        let url = finalDirectory(for: modelID)
            .appending(path: ModelManifestValidator.reservedReceiptName)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(InstallReceipt.self, from: data)
    }

    private func finalDirectory(for modelID: String) -> URL {
        rootDirectory.appending(path: modelID, directoryHint: .isDirectory)
    }

    private func stagingDirectory(for modelID: String) -> URL {
        rootDirectory.appending(
            path: "\(modelID).staging-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    private func isDirectory(_ url: URL) -> Bool {
        var isDir = ObjCBool(false)
        return fileManager.fileExists(atPath: url.path, isDirectory: &isDir)
            && isDir.boolValue
    }
}

extension ModelStore: NetworkPausable {
    public func pauseNetworkActivity() async {
        await pauseActivity(.coordinator)
    }

    public func resumeNetworkActivity() async {
        pauseSources.remove(.coordinator)
    }
}

private final class ByteProgressMark: @unchecked Sendable {
    private let lock = NSLock()
    private var lastBytes: Int64 = -1
    private var lastAdvance = ContinuousClock.now
    private var stalled = false
    private var oversized = false

    func record(_ bytes: Int64) {
        lock.lock()
        if bytes != lastBytes {
            lastBytes = bytes
            lastAdvance = .now
        }
        lock.unlock()
    }

    func silenceDuration(at now: ContinuousClock.Instant) -> Duration {
        lock.lock()
        defer { lock.unlock() }
        return now - lastAdvance
    }

    func noteStalled() {
        lock.lock()
        stalled = true
        lock.unlock()
    }

    func noteOversized() {
        lock.withLock { oversized = true }
    }

    var isOversized: Bool { lock.withLock { oversized } }

    var isStalled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stalled
    }
}
