import Foundation

struct AudioAccumulator: Sendable {
    private(set) var data = Data()
    private(set) var droppedBytes = 0
    private(set) var droppedChunks = 0

    var byteCount: Int { data.count }
    var isEmpty: Bool { data.isEmpty }
    var hasDrops: Bool { droppedChunks > 0 }

    mutating func append(_ chunk: Data, atOffset offset: UInt64) throws {
        guard chunk.count <= ServiceBounds.maxChunkBytes else {
            droppedChunks += 1
            droppedBytes += chunk.count
            throw GoatVoiceServiceError.chunkTooLarge
        }
        guard offset == UInt64(data.count) else {
            droppedChunks += 1
            droppedBytes += chunk.count
            throw GoatVoiceServiceError.audioOffsetMismatch
        }
        guard data.count + chunk.count <= ServiceBounds.maxSessionAudioBytes else {
            droppedChunks += 1
            droppedBytes += chunk.count
            throw GoatVoiceServiceError.sessionAudioLimitExceeded
        }
        data.append(chunk)
    }

    mutating func drop() {
        data.removeAll(keepingCapacity: false)
    }

    static func floatSamples(from data: Data) -> [Float] {
        var samples = [Float](repeating: 0, count: data.count / 2)
        data.withUnsafeBytes { raw in
            let int16 = raw.bindMemory(to: Int16.self)
            for i in samples.indices {
                samples[i] = Float(int16[i]) / 32768.0
            }
        }
        return samples
    }
}
