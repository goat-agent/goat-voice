import Foundation

public enum NetworkActivity: String, Sendable, Hashable, CaseIterable {
    case updateCheck
    case modelDownload
    case appDownload
}

public enum NetworkActivityState: String, Sendable, Equatable {
    case running
    case paused
}

public enum NetworkRequest: Sendable, Equatable {
    case start(NetworkActivity)
    case resume(NetworkActivity)
}

public enum NetworkRequestDecision: Sendable, Equatable {
    case allowed
    case deferred
    case denied
}

public enum NetworkEffect: Sendable, Equatable {
    case pause(NetworkActivity)
    case resume(NetworkActivity)
    case cancelUpdateCheck
    case runDeferredUpdateCheck
}

public struct NetworkActivityPolicy: Sendable, Equatable {
    public private(set) var sessionActive: Bool
    public private(set) var states: [NetworkActivity: NetworkActivityState]
    public private(set) var deferredUpdateCheck: Bool

    public init() {
        sessionActive = false
        states = [:]
        deferredUpdateCheck = false
    }

    public var permitsNewActivity: Bool { !sessionActive }

    public func state(of activity: NetworkActivity) -> NetworkActivityState? {
        states[activity]
    }

    public func decision(for request: NetworkRequest) -> NetworkRequestDecision {
        guard sessionActive else { return .allowed }
        switch request {
        case .start(.updateCheck):
            return .deferred
        case .start, .resume:
            return .denied
        }
    }

    @discardableResult
    public mutating func requestStart(_ activity: NetworkActivity) -> NetworkRequestDecision {
        let decision = decision(for: .start(activity))
        switch decision {
        case .allowed:
            states[activity] = .running
        case .deferred:
            deferredUpdateCheck = true
        case .denied:
            break
        }
        return decision
    }

    @discardableResult
    public mutating func requestResume(_ activity: NetworkActivity) -> NetworkRequestDecision {
        let decision = decision(for: .resume(activity))
        if decision == .allowed {
            states[activity] = .running
        }
        return decision
    }

    public mutating func activityPaused(_ activity: NetworkActivity) {
        switch activity {
        case .updateCheck:
            if sessionActive { deferredUpdateCheck = true }
            states[.updateCheck] = nil
        default:
            if states[activity] == .running {
                states[activity] = .paused
            }
        }
    }

    public mutating func activityResumed(_ activity: NetworkActivity) {
        if !sessionActive {
            states[activity] = .running
        }
    }

    public mutating func activityFinished(_ activity: NetworkActivity) {
        states[activity] = nil
    }

    public mutating func beginSession() -> [NetworkEffect] {
        guard !sessionActive else { return [] }
        sessionActive = true
        return NetworkActivity.allCases.compactMap { activity in
            guard states[activity] == .running else { return nil }
            return activity == .updateCheck ? .cancelUpdateCheck : .pause(activity)
        }
    }

    public mutating func endSession() -> [NetworkEffect] {
        guard sessionActive else { return [] }
        sessionActive = false
        var effects = NetworkActivity.allCases.compactMap { activity -> NetworkEffect? in
            states[activity] == .paused ? .resume(activity) : nil
        }
        if deferredUpdateCheck {
            deferredUpdateCheck = false
            effects.append(.runDeferredUpdateCheck)
        }
        return effects
    }
}
