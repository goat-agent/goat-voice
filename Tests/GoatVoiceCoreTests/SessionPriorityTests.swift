import XCTest
@testable import GoatVoiceCore

final class SessionPriorityTests: XCTestCase {
    func testInvalidationWinsOverSimultaneousHardCap() {
        for reason in [InvalidationReason.escape, .lock, .sleep, .quit] {
            var machine = SessionMachine()
            machine.handle(.triggerComplete(SessionID()), at: MonotonicTime(seconds: 0))
            let effects = machine.handle(.invalidate(reason), at: MonotonicTime(seconds: 1200))
            XCTAssertEqual(machine.state, .idle)
            XCTAssertFalse(effects.contains { effect in
                if case .runInference = effect { return true }
                return false
            })
        }
    }

    func testDelayedHardCapCallbackDoesNotExtendDeadline() {
        var machine = SessionMachine()
        machine.handle(.triggerComplete(SessionID()), at: MonotonicTime(seconds: 0))
        machine.advance(to: MonotonicTime(seconds: 1250))
        guard case .finishing(let context) = machine.state else {
            return XCTFail("Expected forced finish")
        }
        XCTAssertEqual(context.finishReason, .recordingLimit)
        XCTAssertEqual(context.finishTime.seconds, 1200)
        XCTAssertEqual(context.deadline.seconds, 1500)
    }
}
