import Foundation
import GoatVoiceCore

struct MonotonicClock: Sendable {
    private let source: @Sendable () -> ContinuousClock.Instant
    private let epoch: ContinuousClock.Instant

    init() {
        epoch = ContinuousClock.now
        source = { ContinuousClock.now }
    }

    init(epoch: ContinuousClock.Instant,
         source: @escaping @Sendable () -> ContinuousClock.Instant) {
        self.epoch = epoch
        self.source = source
    }

    func now() -> MonotonicTime {
        MonotonicTime(seconds: Self.seconds(epoch.duration(to: source())))
    }

    func instant(for time: MonotonicTime) -> ContinuousClock.Instant {
        epoch.advanced(by: .seconds(time.seconds))
    }

    static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }
}
