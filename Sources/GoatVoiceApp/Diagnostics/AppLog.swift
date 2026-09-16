import Foundation
import OSLog

enum AppLog {
    static let session = Logger(subsystem: "ai.goat.voice", category: "session")
    static let settings = Logger(subsystem: "ai.goat.voice", category: "settings")
    static let updates = Logger(subsystem: "ai.goat.voice", category: "updates")
}
