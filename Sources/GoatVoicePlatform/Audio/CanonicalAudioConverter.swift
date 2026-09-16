import AVFAudio
import Foundation

public struct CanonicalAudioConverter: Sendable {
    public static let maximumFramesPerChunk = 4_096

    private let outputFormat: AVAudioFormat?

    public init(sampleRate: Double = 16_000, channels: Int = 1) {
        outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: sampleRate,
            channels: AVAudioChannelCount(channels),
            interleaved: true)
    }

    public func convert(_ buffer: AVAudioPCMBuffer) -> [CapturedAudioChunk] {
        guard let outputFormat, buffer.frameLength > 0, buffer.format.sampleRate > 0,
              let converter = AVAudioConverter(from: buffer.format, to: outputFormat)
        else { return [] }
        converter.downmix = outputFormat.channelCount < buffer.format.channelCount
        var consumed = false
        let inputBlock: AVAudioConverterInputBlock = { _, status in
            if consumed {
                status.pointee = .endOfStream
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        let capacity = AVAudioFrameCount(
            (Double(buffer.frameLength) * outputFormat.sampleRate / buffer.format.sampleRate)
                .rounded(.up)) + 64
        var chunks: [CapturedAudioChunk] = []
        var finished = false
        while !finished {
            guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity)
            else { break }
            var error: NSError?
            let status = converter.convert(to: output, error: &error, withInputFrom: inputBlock)
            append(output, to: &chunks)
            switch status {
            case .haveData:
                finished = output.frameLength == 0
            case .inputRanDry:
                finished = !consumed
            case .endOfStream, .error:
                finished = true
            @unknown default:
                finished = true
            }
        }
        return chunks
    }

    private func append(_ output: AVAudioPCMBuffer, to chunks: inout [CapturedAudioChunk]) {
        guard output.frameLength > 0, let channelData = output.int16ChannelData
        else { return }
        let channelStride = Int(output.format.channelCount)
        var frameOffset = 0
        let total = Int(output.frameLength)
        while frameOffset < total {
            let frames = min(CanonicalAudioConverter.maximumFramesPerChunk, total - frameOffset)
            let byteCount = frames * channelStride * MemoryLayout<Int16>.size
            let data = Data(
                bytes: channelData[0].advanced(by: frameOffset * channelStride),
                count: byteCount)
            chunks.append(CapturedAudioChunk(pcm16: data, frameCount: frames))
            frameOffset += frames
        }
    }
}
