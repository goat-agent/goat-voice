import Foundation

public protocol LocalBackendProviding: Sendable {
    var supportedModelIDs: [String] { get }
    func makeBackend(modelID: String) throws -> any LocalASRBackend
    func availability() -> [String: Bool]
}

public struct UnavailableBackendProvider: LocalBackendProviding {
    public init() {}

    public var supportedModelIDs: [String] { [] }

    public func makeBackend(modelID: String) throws -> any LocalASRBackend {
        throw GoatVoiceServiceError.backendUnavailable
    }

    public func availability() -> [String: Bool] { [:] }
}

public enum ServiceBackend {
    public static func makeProvider() -> any LocalBackendProviding {
        LocalBackendProvider()
    }
}
