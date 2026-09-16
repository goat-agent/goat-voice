import CoreGraphics
import Foundation

public enum PasteOutcome: Sendable, Equatable {
    case posted
    case alreadyAttempted
    case postFailed
}

public protocol PasteEventPosting: Sendable {
    func postPaste(to pid: pid_t) -> Bool
}

public final class TextInserter: @unchecked Sendable {
    private let poster: PasteEventPosting
    private let lock = NSLock()
    private var posted = false

    public init(poster: PasteEventPosting) {
        self.poster = poster
    }

    public var hasPostedPaste: Bool {
        lock.lock()
        defer { lock.unlock() }
        return posted
    }

    public func pasteOnce(to pid: pid_t) -> PasteOutcome {
        lock.lock()
        if posted {
            lock.unlock()
            return .alreadyAttempted
        }
        posted = true
        lock.unlock()
        return poster.postPaste(to: pid) ? .posted : .postFailed
    }
}

public final class CGEventPastePoster: PasteEventPosting {
    public init() {}

    public func postPaste(to pid: pid_t) -> Bool {
        guard let source = CGEventSource(stateID: .combinedSessionState),
              let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false)
        else { return false }
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.postToPid(pid)
        keyUp.postToPid(pid)
        return true
    }
}
