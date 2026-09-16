import Foundation
import OSLog

enum ServiceLog {
    static let lifecycle = Logger(subsystem: "ai.goat.voice.stt", category: "lifecycle")
    static let sessions = Logger(subsystem: "ai.goat.voice.stt", category: "sessions")
}
