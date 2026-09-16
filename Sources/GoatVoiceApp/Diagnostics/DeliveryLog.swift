import OSLog

enum DeliveryLog {
    private static let logger = Logger(subsystem: "ai.goat.voice", category: "delivery")

    static func delivery(_ diagnostic: DeliveryDiagnostic) {
        switch diagnostic {
        case .decision(let trace):
            let target = trace.verification.map { String(describing: $0) } ?? "uncaptured"
            let intent = String(describing: trace.intent)
            logger.info("Delivery checked snapshot=\(trace.snapshot.rawValue, privacy: .public) target=\(target, privacy: .public) intent=\(intent, privacy: .public) clipboardUnchanged=\(trace.clipboardUnchangedSinceBoundary)")
        case .fellBack(let kind, let reason):
            logger.notice("Delivery fallback kind=\(kind.rawValue, privacy: .public) reason=\(reason.rawValue, privacy: .public)")
        case .residueWaitTimedOut:
            logger.notice("Delivery waited for prior clipboard restoration")
        case .posted:
            logger.info("Paste event posted")
        case .invalidated:
            logger.info("Delivery invalidated before completion")
        }
    }

    static func recovery(_ diagnostic: RecoveryDiagnostic) {
        switch diagnostic {
        case .copyFinished(let outcome):
            logger.info("Recovery copy outcome=\(outcome.rawValue, privacy: .public)")
        case .decision(let snapshot, _):
            logger.info("Recovery checked snapshot=\(snapshot.rawValue, privacy: .public)")
        case .staleResultDropped:
            logger.info("Stale recovery result discarded")
        case .presented:
            break
        }
    }
}
