import Foundation

public protocol LocalASRBackend: Sendable {
    func load(directory: URL) async throws
    func transcribe(samples: [Float]) async throws -> String
    func unload() async
}

public protocol LocalASRCacheTrimming: Sendable {
    func trimCache() async
}

protocol LocalASRPreviewing: LocalASRBackend {
    func preview(samples: [Float]) async throws -> String
}
