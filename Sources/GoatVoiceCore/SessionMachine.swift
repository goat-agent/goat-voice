import Foundation

public struct MonotonicTime: Comparable, Sendable, Equatable, Codable {
    public var seconds: Double

    public init(seconds: Double) {
        self.seconds = seconds
    }

    public static func < (lhs: MonotonicTime, rhs: MonotonicTime) -> Bool {
        lhs.seconds < rhs.seconds
    }

    public static func + (lhs: MonotonicTime, rhs: Double) -> MonotonicTime {
        MonotonicTime(seconds: lhs.seconds + rhs)
    }

    public static func - (lhs: MonotonicTime, rhs: MonotonicTime) -> Double {
        lhs.seconds - rhs.seconds
    }
}

public struct SessionMachine: Sendable, Equatable {
    public static let recordingWarningOffset: Double = 1140
    public static let recordingHardLimit: Double = 1200
    public static let minimumPostReleaseBudget: Double = 30
    public static let maximumPostReleaseBudget: Double = 300
    public static let postReleaseSlack: Double = 15
    public static let maximumAttempts = 2

    public enum TriggerGate: String, Sendable, Equatable {
        case armed
        case disarmed
    }

    public enum Notice: String, Sendable, Equatable {
        case recordingLimitWarning
        case microphoneDisconnected
        case microphoneUnavailable
        case transcriptionFailed
    }

    public enum TranscriptionFailure: String, Sendable, Equatable {
        case transient
        case deterministic
    }

    public struct Recording: Sendable, Equatable {
        public let sessionID: SessionID
        public let startTime: MonotonicTime
        public let warningIssued: Bool
    }

    public struct Finishing: Sendable, Equatable {
        public let sessionID: SessionID
        public let finishReason: FinishReason
        public let finishTime: MonotonicTime
        public let audioDuration: Double
        public let deadline: MonotonicTime
        public let attempt: Int
    }

    public struct Delivering: Sendable, Equatable {
        public let sessionID: SessionID
        public let token: AttemptToken
        public let transcript: String
        public let deadline: MonotonicTime
    }

    public enum State: Sendable, Equatable {
        case idle
        case recording(Recording)
        case finishing(Finishing)
        case delivering(Delivering)
    }

    public enum Event: Sendable, Equatable {
        case triggerComplete(SessionID)
        case triggerReleased
        case triggerFullyReleased
        case extraKeyPressed
        case microphoneDisconnected
        case invalidate(InvalidationReason)
        case inferenceSucceeded(AttemptToken, transcript: String)
        case inferenceFailed(AttemptToken, TranscriptionFailure)
        case pastePosted(AttemptToken)
        case deliveryAborted(AttemptToken)
    }

    public enum Effect: Sendable, Equatable {
        case startCapture(SessionID)
        case stopCapture(SessionID)
        case discardAudio(SessionID)
        case runInference(AttemptToken)
        case cancelInference(AttemptToken)
        case deliverTranscript(AttemptToken, transcript: String)
        case recoverTranscript(AttemptToken, transcript: String)
        case abortDelivery(SessionID)
        case presentNotice(Notice)
        case blockNetwork
        case unblockNetwork
        case disarmTrigger
    }

    public private(set) var state: State
    public private(set) var triggerGate: TriggerGate

    public init() {
        state = .idle
        triggerGate = .armed
    }

    @discardableResult
    public mutating func handle(_ event: Event, at now: MonotonicTime) -> [Effect] {
        if event.preemptsTimeout {
            var effects = reduce(event, at: now)
            effects += expireTimeouts(at: now)
            return effects
        }
        var effects = expireTimeouts(at: now)
        effects += reduce(event, at: now)
        return effects
    }

    @discardableResult
    public mutating func advance(to now: MonotonicTime) -> [Effect] {
        var effects = expireTimeouts(at: now)
        if case .recording(let context) = state,
           !context.warningIssued,
           now - context.startTime >= Self.recordingWarningOffset {
            state = .recording(Recording(sessionID: context.sessionID,
                                       startTime: context.startTime,
                                       warningIssued: true))
            effects.append(.presentNotice(.recordingLimitWarning))
        }
        return effects
    }

    private mutating func expireTimeouts(at now: MonotonicTime) -> [Effect] {
        switch state {
        case .recording(let context):
            guard now - context.startTime >= Self.recordingHardLimit else { return [] }
            let finishTime = context.startTime + Self.recordingHardLimit
            guard now < Self.postReleaseDeadline(finishTime: finishTime,
                                                 audioDuration: Self.recordingHardLimit) else {
                triggerGate = .disarmed
                return conclude(sessionID: context.sessionID,
                                effects: [.stopCapture(context.sessionID),
                                          .disarmTrigger,
                                          .presentNotice(.transcriptionFailed)])
            }
            return finish(context, reason: .recordingLimit, at: finishTime)
        case .finishing(let context):
            guard now >= context.deadline else { return [] }
            let token = AttemptToken(sessionID: context.sessionID, attempt: context.attempt)
            return conclude(sessionID: context.sessionID,
                            effects: [.cancelInference(token), .presentNotice(.transcriptionFailed)])
        case .delivering(let context):
            guard now >= context.deadline else { return [] }
            return conclude(sessionID: context.sessionID,
                            effects: [.abortDelivery(context.sessionID), .presentNotice(.transcriptionFailed)])
        case .idle:
            return []
        }
    }

    private mutating func reduce(_ event: Event, at now: MonotonicTime) -> [Effect] {
        switch event {
        case .triggerFullyReleased:
            triggerGate = .armed
            return []
        case .triggerComplete(let sessionID):
            return begin(sessionID: sessionID, at: now)
        case .triggerReleased:
            guard case .recording(let context) = state else { return [] }
            return finish(context, reason: .normalRelease, at: now)
        case .extraKeyPressed:
            return cancelRecording()
        case .microphoneDisconnected:
            guard case .recording(let context) = state else { return [] }
            return finish(context, reason: .microphoneDisconnected, at: now)
        case .invalidate(let reason):
            if reason == .extraKey { return cancelRecording() }
            return invalidate(reason)
        case .inferenceSucceeded(let token, let transcript):
            return inferenceSucceeded(token, transcript: transcript)
        case .inferenceFailed(let token, let failure):
            return inferenceFailed(token, failure: failure, at: now)
        case .pastePosted(let token):
            guard case .delivering(let context) = state, context.token == token else { return [] }
            return conclude(sessionID: context.sessionID, effects: [])
        case .deliveryAborted(let token):
            guard case .delivering(let context) = state, context.token == token else { return [] }
            return conclude(sessionID: context.sessionID,
                            effects: [.recoverTranscript(context.token, transcript: context.transcript)])
        }
    }

    private mutating func begin(sessionID: SessionID, at now: MonotonicTime) -> [Effect] {
        if case .idle = state {
            guard triggerGate == .armed else { return [] }
            state = .recording(Recording(sessionID: sessionID, startTime: now, warningIssued: false))
            return [.startCapture(sessionID), .blockNetwork]
        }
        if triggerGate == .armed {
            triggerGate = .disarmed
            return [.disarmTrigger]
        }
        return []
    }

    private mutating func finish(_ context: Recording, reason: FinishReason, at now: MonotonicTime) -> [Effect] {
        let duration = min(Self.recordingHardLimit, max(0, now - context.startTime))
        state = .finishing(Finishing(sessionID: context.sessionID,
                                     finishReason: reason,
                                     finishTime: now,
                                     audioDuration: duration,
                                     deadline: Self.postReleaseDeadline(finishTime: now,
                                                                        audioDuration: duration),
                                     attempt: 0))
        triggerGate = .disarmed
        var effects: [Effect] = [.stopCapture(context.sessionID),
                                 .runInference(AttemptToken(sessionID: context.sessionID))]
        if reason == .microphoneDisconnected {
            effects.append(.presentNotice(.microphoneDisconnected))
        }
        effects.append(.disarmTrigger)
        return effects
    }

    private mutating func cancelRecording() -> [Effect] {
        guard case .recording(let context) = state else { return [] }
        triggerGate = .disarmed
        return conclude(sessionID: context.sessionID,
                        effects: [.stopCapture(context.sessionID), .disarmTrigger])
    }

    private mutating func invalidate(_ reason: InvalidationReason) -> [Effect] {
        switch state {
        case .idle:
            return []
        case .recording(let context):
            triggerGate = .disarmed
            var effects: [Effect] = [.stopCapture(context.sessionID), .disarmTrigger]
            if reason == .captureFailure {
                effects.append(.presentNotice(.microphoneUnavailable))
            }
            return conclude(sessionID: context.sessionID, effects: effects)
        case .finishing(let context):
            var effects: [Effect] = [.cancelInference(AttemptToken(sessionID: context.sessionID,
                                                                 attempt: context.attempt))]
            if reason == .deadline {
                effects.append(.presentNotice(.transcriptionFailed))
            }
            return conclude(sessionID: context.sessionID, effects: effects)
        case .delivering(let context):
            var effects: [Effect] = [.abortDelivery(context.sessionID)]
            if reason == .deadline {
                effects.append(.presentNotice(.transcriptionFailed))
            }
            return conclude(sessionID: context.sessionID, effects: effects)
        }
    }

    private mutating func inferenceSucceeded(_ token: AttemptToken, transcript: String) -> [Effect] {
        guard case .finishing(let context) = state,
              token == AttemptToken(sessionID: context.sessionID, attempt: context.attempt) else {
            return []
        }
        if transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return conclude(sessionID: context.sessionID, effects: [])
        }
        if context.finishReason.permitsAutomaticInsertion {
            state = .delivering(Delivering(sessionID: context.sessionID,
                                           token: token,
                                           transcript: transcript,
                                           deadline: context.deadline))
            return [.deliverTranscript(token, transcript: transcript)]
        }
        return conclude(sessionID: context.sessionID,
                        effects: [.recoverTranscript(token, transcript: transcript)])
    }

    private mutating func inferenceFailed(_ token: AttemptToken,
                                          failure: TranscriptionFailure,
                                          at now: MonotonicTime) -> [Effect] {
        guard case .finishing(let context) = state,
              token == AttemptToken(sessionID: context.sessionID, attempt: context.attempt) else {
            return []
        }
        if failure == .transient, context.attempt + 1 < Self.maximumAttempts, now < context.deadline {
            let retry = AttemptToken(sessionID: context.sessionID, attempt: context.attempt + 1)
            state = .finishing(Finishing(sessionID: context.sessionID,
                                         finishReason: context.finishReason,
                                         finishTime: context.finishTime,
                                         audioDuration: context.audioDuration,
                                         deadline: context.deadline,
                                         attempt: retry.attempt))
            return [.runInference(retry)]
        }
        return conclude(sessionID: context.sessionID, effects: [.presentNotice(.transcriptionFailed)])
    }

    private static func postReleaseDeadline(finishTime: MonotonicTime,
                                            audioDuration: Double) -> MonotonicTime {
        let budget = min(maximumPostReleaseBudget,
                         max(minimumPostReleaseBudget, audioDuration + postReleaseSlack))
        return finishTime + budget
    }

    private mutating func conclude(sessionID: SessionID, effects: [Effect]) -> [Effect] {
        state = .idle
        return effects + [.discardAudio(sessionID), .unblockNetwork]
    }
}

private extension SessionMachine.Event {
    var preemptsTimeout: Bool {
        switch self {
        case .invalidate, .extraKeyPressed:
            return true
        case .triggerComplete, .triggerReleased, .triggerFullyReleased,
             .microphoneDisconnected, .inferenceSucceeded, .inferenceFailed,
             .pastePosted, .deliveryAborted:
            return false
        }
    }
}
