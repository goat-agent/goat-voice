import Foundation

public struct CanonicalAudio: Sendable, Equatable {
    public static let bytesPerFrame = 2
    public static let framesPerSecond = 16_000

    public let pcm16: Data

    public var frameCount: Int { pcm16.count / Self.bytesPerFrame }

    public var durationSeconds: Double {
        Double(frameCount) / Double(Self.framesPerSecond)
    }

    public init(pcm16: Data) {
        precondition(pcm16.count % Self.bytesPerFrame == 0)
        self.pcm16 = pcm16
    }
}

public struct CanonicalAudioBuffer: Sendable, Equatable {
    public static let maximumDurationSeconds = 1_200
    public static let maximumBytes =
        maximumDurationSeconds * CanonicalAudio.framesPerSecond * CanonicalAudio.bytesPerFrame

    public enum AppendOutcome: Sendable, Equatable {
        case accepted
        case acceptedReachingLimit
        case rejectedMisaligned
        case rejectedFull
    }

    private var storage: Data
    public private(set) var isFull: Bool

    public init() {
        storage = Data()
        isFull = false
    }

    public var byteCount: Int { storage.count }
    public var frameCount: Int { byteCount / CanonicalAudio.bytesPerFrame }
    public var remainingBytes: Int { Self.maximumBytes - byteCount }
    public var isEmpty: Bool { storage.isEmpty }
    public var pcm16: Data { storage }

    public var durationSeconds: Double {
        Double(frameCount) / Double(CanonicalAudio.framesPerSecond)
    }

    public var canonicalAudio: CanonicalAudio {
        CanonicalAudio(pcm16: storage)
    }

    @discardableResult
    public mutating func append(_ chunk: Data) -> AppendOutcome {
        guard chunk.count % CanonicalAudio.bytesPerFrame == 0 else {
            return .rejectedMisaligned
        }
        guard !chunk.isEmpty else { return .accepted }
        guard !isFull else { return .rejectedFull }
        let admitted = min(chunk.count, remainingBytes)
        storage.append(contentsOf: chunk.prefix(admitted))
        if byteCount == Self.maximumBytes {
            isFull = true
            return .acceptedReachingLimit
        }
        return .accepted
    }

    public mutating func discard() {
        storage.withUnsafeMutableBytes { region in
            if let base = region.baseAddress {
                memset(base, 0, region.count)
            }
        }
        storage = Data()
        isFull = false
    }
}
