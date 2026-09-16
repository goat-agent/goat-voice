import Foundation

enum ServiceBounds {
    static let protocolVersion = 2
    static let maxChunkBytes = 262_144
    static let maxSessionAudioBytes = 38_400_000
    static let maxSessions = 1
    static let loadWatchdogSeconds: TimeInterval = 60
    static let sampleRate = 16_000
    static let previewMinimumBytes = sampleRate * 2 * 3 / 2
    static let previewIncrementBytes = sampleRate * 2 * 3 / 4
    static let previewWindowBytes = sampleRate * 2 * 8
    static let previewMaximumCharacters = 600
    static let previewMaximumTokens = 128

    static func postReleaseBudgetSeconds(audioBytes: Int) -> TimeInterval {
        let duration = Double(audioBytes / 2) / Double(sampleRate)
        return min(300, max(30, duration + 15))
    }
}
