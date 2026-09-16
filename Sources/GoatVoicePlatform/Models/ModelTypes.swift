import Foundation

public struct ModelArtifact: Codable, Equatable, Sendable {
    public var relativePath: String
    public var downloadURL: URL
    public var sha256Hex: String
    public var byteCount: Int

    public init(relativePath: String, downloadURL: URL, sha256Hex: String, byteCount: Int) {
        self.relativePath = relativePath
        self.downloadURL = downloadURL
        self.sha256Hex = sha256Hex
        self.byteCount = byteCount
    }
}

public struct ModelManifest: Codable, Equatable, Sendable {
    public var modelID: String
    public var version: String
    public var artifacts: [ModelArtifact]

    public init(modelID: String, version: String, artifacts: [ModelArtifact]) {
        self.modelID = modelID
        self.version = version
        self.artifacts = artifacts
    }
}

public enum ModelInstallState: Equatable, Sendable {
    case notInstalled
    case installed(version: String)
    case verifying
    case corrupt
}

public enum ModelManifestRejection: Error, Equatable, Sendable {
    case unsafeModelID(String)
    case emptyManifest
    case tooManyArtifacts(found: Int, limit: Int)
    case duplicateRelativePath(String)
    case unsafeRelativePath(String)
    case invalidSHA256(artifact: String)
    case nonPositiveByteCount(artifact: String)
    case unsupportedDownloadScheme(artifact: String)
    case insecureRemoteURL(artifact: String)
    case invalidBundleResource(artifact: String)
    case totalSizeOverflow
}

public enum ModelStoreError: Error {
    case blockedByActiveSession
    case downloadFailed(underlying: Error)
    case stalled
    case hashMismatch(artifact: String)
    case sizeMismatch(artifact: String)
    case installFailed(underlying: Error)
    case cancelled
    case busy
    case invalidManifest(ModelManifestRejection)
}

public struct ModelDownloadProgress: Sendable {
    public enum Phase: String, Sendable, Equatable {
        case downloading
        case verifying
    }

    public var completedBytes: Int64
    public var expectedBytes: Int64?
    public var phase: Phase

    public init(completedBytes: Int64, expectedBytes: Int64?, phase: Phase) {
        self.completedBytes = completedBytes
        self.expectedBytes = expectedBytes
        self.phase = phase
    }
}

enum ModelArtifactSource: Equatable {
    case remote(URL)
    case bundledResource(filename: String)
}

struct CheckedArtifact {
    var artifact: ModelArtifact
    var source: ModelArtifactSource
    var sha256HexLowercase: String
}

struct CheckedManifest {
    var modelID: String
    var version: String
    var artifacts: [CheckedArtifact]
    var totalBytes: Int64
}

enum ModelManifestValidator {
    static let maxArtifacts = 512
    static let maxRelativePathLength = 1_024
    static let maxPathComponentUTF8 = 255
    static let maxModelIDLength = 128
    static let reservedReceiptName = ".voice-install.json"
    static let bundleScheme = "bundle"
    static let bundleHost = "Models"

    static func check(_ manifest: ModelManifest) throws -> CheckedManifest {
        try checkModelID(manifest.modelID)
        guard !manifest.artifacts.isEmpty else {
            throw ModelStoreError.invalidManifest(.emptyManifest)
        }
        guard manifest.artifacts.count <= maxArtifacts else {
            throw ModelStoreError.invalidManifest(
                .tooManyArtifacts(found: manifest.artifacts.count, limit: maxArtifacts))
        }
        var seen = Set<String>()
        var checked: [CheckedArtifact] = []
        var total: Int64 = 0
        for artifact in manifest.artifacts {
            try checkRelativePath(artifact.relativePath)
            guard seen.insert(artifact.relativePath).inserted else {
                throw ModelStoreError.invalidManifest(.duplicateRelativePath(artifact.relativePath))
            }
            guard artifact.byteCount > 0 else {
                throw ModelStoreError.invalidManifest(
                    .nonPositiveByteCount(artifact: artifact.relativePath))
            }
            let (sum, overflow) = total.addingReportingOverflow(Int64(artifact.byteCount))
            guard !overflow else {
                throw ModelStoreError.invalidManifest(.totalSizeOverflow)
            }
            total = sum
            checked.append(CheckedArtifact(
                artifact: artifact,
                source: try checkSource(artifact),
                sha256HexLowercase: try checkSHA256(artifact)))
        }
        return CheckedManifest(
            modelID: manifest.modelID,
            version: manifest.version,
            artifacts: checked,
            totalBytes: total)
    }

    static func checkModelID(_ modelID: String) throws {
        guard !modelID.isEmpty,
              modelID.count <= maxModelIDLength,
              let first = modelID.unicodeScalars.first,
              isASCIIAlphanumeric(first),
              modelID.unicodeScalars.allSatisfy(isModelIDScalar)
        else {
            throw ModelStoreError.invalidManifest(.unsafeModelID(modelID))
        }
    }

    static func isSafeRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty,
              path.count <= maxRelativePathLength,
              !path.hasPrefix("/"),
              path != reservedReceiptName
        else { return false }
        for component in path.split(separator: "/", omittingEmptySubsequences: false) {
            guard !component.isEmpty,
                  component != ".", component != "..",
                  component.utf8.count <= maxPathComponentUTF8,
                  !component.contains("\\"), !component.contains(":"),
                  !component.contains("%"),
                  component.unicodeScalars.allSatisfy(isPrintablePathScalar)
            else { return false }
        }
        return true
    }

    private static func checkRelativePath(_ path: String) throws {
        guard isSafeRelativePath(path) else {
            throw ModelStoreError.invalidManifest(.unsafeRelativePath(path))
        }
    }

    private static func checkSHA256(_ artifact: ModelArtifact) throws -> String {
        let hex = artifact.sha256Hex
        guard hex.count == 64, hex.unicodeScalars.allSatisfy(isHexScalar) else {
            throw ModelStoreError.invalidManifest(.invalidSHA256(artifact: artifact.relativePath))
        }
        return hex.lowercased()
    }

    private static func checkSource(_ artifact: ModelArtifact) throws -> ModelArtifactSource {
        let url = artifact.downloadURL
        guard let scheme = url.scheme?.lowercased() else {
            throw ModelStoreError.invalidManifest(
                .unsupportedDownloadScheme(artifact: artifact.relativePath))
        }
        switch scheme {
        case "https":
            guard let host = url.host(percentEncoded: false), !host.isEmpty,
                  url.user(percentEncoded: false) == nil,
                  url.password(percentEncoded: false) == nil
            else {
                throw ModelStoreError.invalidManifest(
                    .insecureRemoteURL(artifact: artifact.relativePath))
            }
            return .remote(url)
        case bundleScheme:
            let name = try checkBundleResourceName(url, artifact: artifact.relativePath)
            return .bundledResource(filename: name)
        default:
            throw ModelStoreError.invalidManifest(
                .unsupportedDownloadScheme(artifact: artifact.relativePath))
        }
    }

    private static func checkBundleResourceName(_ url: URL, artifact: String) throws -> String {
        guard url.host(percentEncoded: false)?.caseInsensitiveCompare(bundleHost) == .orderedSame,
              url.user(percentEncoded: false) == nil,
              url.password(percentEncoded: false) == nil,
              url.port == nil,
              url.query(percentEncoded: false) == nil,
              url.fragment == nil
        else {
            throw ModelStoreError.invalidManifest(.invalidBundleResource(artifact: artifact))
        }
        let decodedPath = url.path(percentEncoded: false)
        guard decodedPath.hasPrefix("/") else {
            throw ModelStoreError.invalidManifest(.invalidBundleResource(artifact: artifact))
        }
        let name = String(decodedPath.dropFirst())
        guard isSafeBundleFilename(name) else {
            throw ModelStoreError.invalidManifest(.invalidBundleResource(artifact: artifact))
        }
        return name
    }

    static func isSafeBundleFilename(_ name: String) -> Bool {
        !name.isEmpty
            && !name.contains("/") && !name.contains("\\") && !name.contains(":")
            && name != "." && name != ".."
            && name != reservedReceiptName
            && name.utf8.count <= maxPathComponentUTF8
            && name.unicodeScalars.allSatisfy(isPrintablePathScalar)
    }

    private static func isModelIDScalar(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x30...0x39, 0x41...0x5A, 0x61...0x7A, 0x2D, 0x2E, 0x5F:
            return true
        default:
            return false
        }
    }

    private static func isASCIIAlphanumeric(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x30...0x39, 0x41...0x5A, 0x61...0x7A:
            return true
        default:
            return false
        }
    }

    private static func isHexScalar(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x30...0x39, 0x41...0x46, 0x61...0x66:
            return true
        default:
            return false
        }
    }

    private static func isPrintablePathScalar(_ scalar: Unicode.Scalar) -> Bool {
        scalar.value >= 0x20 && scalar.value != 0x7F
    }
}
