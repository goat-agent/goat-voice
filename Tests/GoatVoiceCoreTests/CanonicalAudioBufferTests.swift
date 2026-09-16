import Foundation
import XCTest
@testable import GoatVoiceCore

final class CanonicalAudioBufferTests: XCTestCase {
    func testEmptyBuffer() {
        let buffer = CanonicalAudioBuffer()
        XCTAssertEqual(buffer.byteCount, 0)
        XCTAssertEqual(buffer.frameCount, 0)
        XCTAssertEqual(buffer.durationSeconds, 0)
        XCTAssertFalse(buffer.isFull)
        XCTAssertTrue(buffer.isEmpty)
        XCTAssertEqual(buffer.remainingBytes, CanonicalAudioBuffer.maximumBytes)
    }

    func testMaximumBytesIsExactlyTwentyMinutes() {
        XCTAssertEqual(CanonicalAudioBuffer.maximumDurationSeconds, 1_200)
        XCTAssertEqual(CanonicalAudioBuffer.maximumBytes, 38_400_000)
    }

    func testAppendTracksFramesAndDuration() {
        var buffer = CanonicalAudioBuffer()
        XCTAssertEqual(buffer.append(Data(count: 32_000)), .accepted)
        XCTAssertEqual(buffer.byteCount, 32_000)
        XCTAssertEqual(buffer.frameCount, 16_000)
        XCTAssertEqual(buffer.durationSeconds, 1.0)
        XCTAssertEqual(buffer.remainingBytes, CanonicalAudioBuffer.maximumBytes - 32_000)
    }

    func testAppendEmptyChunkIsAccepted() {
        var buffer = CanonicalAudioBuffer()
        XCTAssertEqual(buffer.append(Data()), .accepted)
        XCTAssertTrue(buffer.isEmpty)
    }

    func testAppendRejectsMisalignedChunk() {
        var buffer = CanonicalAudioBuffer()
        XCTAssertEqual(buffer.append(Data(count: 3)), .rejectedMisaligned)
        XCTAssertEqual(buffer.append(Data(count: 32_001)), .rejectedMisaligned)
        XCTAssertTrue(buffer.isEmpty)
    }

    func testAppendFillsToExactCapacity() {
        var buffer = CanonicalAudioBuffer()
        XCTAssertEqual(
            buffer.append(Data(count: CanonicalAudioBuffer.maximumBytes)),
            .acceptedReachingLimit
        )
        XCTAssertTrue(buffer.isFull)
        XCTAssertEqual(buffer.byteCount, CanonicalAudioBuffer.maximumBytes)
        XCTAssertEqual(buffer.remainingBytes, 0)
        XCTAssertEqual(buffer.durationSeconds, 1_200)
    }

    func testAppendTruncatesChunkAtLimit() {
        var buffer = CanonicalAudioBuffer()
        buffer.append(Data(count: CanonicalAudioBuffer.maximumBytes - 4))
        XCTAssertEqual(buffer.append(Data(count: 16)), .acceptedReachingLimit)
        XCTAssertEqual(buffer.byteCount, CanonicalAudioBuffer.maximumBytes)
        XCTAssertTrue(buffer.isFull)
    }

    func testAppendAfterFullIsRejected() {
        var buffer = CanonicalAudioBuffer()
        buffer.append(Data(count: CanonicalAudioBuffer.maximumBytes))
        XCTAssertEqual(buffer.append(Data(count: 2)), .rejectedFull)
        XCTAssertEqual(buffer.byteCount, CanonicalAudioBuffer.maximumBytes)
    }

    func testMisalignedChunkRejectedEvenWhenFull() {
        var buffer = CanonicalAudioBuffer()
        buffer.append(Data(count: CanonicalAudioBuffer.maximumBytes))
        XCTAssertEqual(buffer.append(Data(count: 1)), .rejectedMisaligned)
    }

    func testDiscardClearsAudioAndAllowsReuse() {
        var buffer = CanonicalAudioBuffer()
        buffer.append(Data(count: CanonicalAudioBuffer.maximumBytes))
        buffer.discard()
        XCTAssertEqual(buffer.byteCount, 0)
        XCTAssertFalse(buffer.isFull)
        XCTAssertEqual(buffer.append(Data(count: 2)), .accepted)
    }

    func testCanonicalAudioSnapshot() {
        var pcm = Data(count: 64)
        pcm[0] = 0xAB
        var buffer = CanonicalAudioBuffer()
        buffer.append(pcm)
        let audio = buffer.canonicalAudio
        XCTAssertEqual(audio.pcm16, pcm)
        XCTAssertEqual(audio.frameCount, 32)
        XCTAssertEqual(audio.durationSeconds, 32.0 / 16_000)
        XCTAssertEqual(buffer.pcm16, pcm)
    }
}
