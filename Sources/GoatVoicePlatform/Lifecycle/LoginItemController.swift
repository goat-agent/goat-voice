import Foundation
import ServiceManagement

public enum LoginItemStatus: Equatable, Sendable {
    case notRegistered
    case enabled
    case requiresApproval
    case notFound
}

public protocol LoginItemManaging: Sendable {
    func status() -> LoginItemStatus
    func setEnabled(_ enabled: Bool) throws
}

public struct SMAppServiceLoginItemManager: LoginItemManaging {
    public init() {}

    public func status() -> LoginItemStatus {
        switch SMAppService.mainApp.status {
        case .notRegistered: return .notRegistered
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        case .notFound: return .notFound
        @unknown default: return .notFound
        }
    }

    public func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}

public final class LoginItemController: Sendable {
    private let manager: LoginItemManaging

    public init(manager: LoginItemManaging = SMAppServiceLoginItemManager()) {
        self.manager = manager
    }

    public var status: LoginItemStatus {
        manager.status()
    }

    public var isEnabled: Bool {
        manager.status() == .enabled
    }

    public func setEnabled(_ enabled: Bool) throws {
        try manager.setEnabled(enabled)
    }
}
