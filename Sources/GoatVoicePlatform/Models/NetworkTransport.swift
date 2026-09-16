import Foundation

public enum NetworkTransportError: Error {
    case blockedByActiveSession
    case alreadyActive
    case cancelled
    case stalled
    case missingDownloadedFile
    case relocationFailed(underlying: any Error)
    case downloadFailed(underlying: any Error)
}

public protocol NetworkTransport: Sendable {
    func download(_ url: URL, to destination: URL,
                  progress: @escaping @Sendable (Int64) -> Void) async throws
    func pause() async -> Data?
    func resume(with resumeData: Data, to destination: URL,
                progress: @escaping @Sendable (Int64) -> Void) async throws
    func cancel()
}
