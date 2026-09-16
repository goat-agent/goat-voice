import CoreGraphics
import Foundation

public struct TargetDescriptor: Sendable {
    public var elementToken: AXElementToken
    public var windowToken: AXElementToken?
    public var windowID: CGWindowID?
    public var bundleIdentifier: String?
    public var displayID: CGDirectDisplayID?
    public var capturedAt: Date

    public init(elementToken: AXElementToken, windowID: CGWindowID?,
                bundleIdentifier: String?, displayID: CGDirectDisplayID?,
                capturedAt: Date, windowToken: AXElementToken? = nil) {
        self.elementToken = elementToken
        self.windowToken = windowToken
        self.windowID = windowID
        self.bundleIdentifier = bundleIdentifier
        self.displayID = displayID
        self.capturedAt = capturedAt
    }
}

public enum TargetVerification: Sendable, Equatable {
    case same
    case accessibilityUnavailable
    case noFocusedElement
    case focusedNotEditable
    case differentField
    case differentWindow
}

public protocol DisplayLookingUp: Sendable {
    func displayID(containing bounds: CGRect) -> CGDirectDisplayID?
}

public final class CoreGraphicsDisplayLookup: DisplayLookingUp {
    public init() {}

    public func displayID(containing bounds: CGRect) -> CGDirectDisplayID? {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return nil }
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &displays, &count) == .success else { return nil }
        var best: CGDirectDisplayID?
        var bestArea: CGFloat = 0
        for display in displays.prefix(Int(count)) {
            let intersection = CGDisplayBounds(display).intersection(bounds)
            let area = intersection.isNull ? 0 : intersection.width * intersection.height
            if area > bestArea {
                bestArea = area
                best = display
            }
        }
        return best ?? displays.first
    }
}

public final class TargetResolver: Sendable {
    private let backend: AccessibilityBackend
    private let displayLookup: DisplayLookingUp

    public init(backend: AccessibilityBackend, displayLookup: DisplayLookingUp) {
        self.backend = backend
        self.displayLookup = displayLookup
    }

    public func captureTarget() throws -> TargetDescriptor {
        let token = try backend.focusedEditableElement()
        let windowID = backend.windowID(of: token)
        let bounds = backend.windowBounds(of: token)
        if windowID == nil && bounds == nil {
            throw TargetResolutionError.windowIdentityUnavailable
        }
        let displayID = bounds.flatMap { displayLookup.displayID(containing: $0) }
        return TargetDescriptor(
            elementToken: token,
            windowID: windowID,
            bundleIdentifier: backend.bundleIdentifier(of: token),
            displayID: displayID,
            capturedAt: Date(),
            windowToken: backend.windowToken(of: token)
        )
    }

    public func verify(_ target: TargetDescriptor) -> TargetVerification {
        let current: AXElementToken
        do {
            current = try backend.focusedEditableElement()
        } catch let error as TargetResolutionError {
            switch error {
            case .accessibilityUnavailable: return .accessibilityUnavailable
            case .focusedElementNotEditable: return .focusedNotEditable
            case .noFocusedElement, .windowIdentityUnavailable: return .noFocusedElement
            }
        } catch {
            return .noFocusedElement
        }
        guard backend.element(current, isSameAs: target.elementToken) else {
            return .differentField
        }
        if let expectedWindow = target.windowToken {
            guard let currentWindow = backend.windowToken(of: current),
                  backend.element(currentWindow, isSameAs: expectedWindow)
            else { return .differentWindow }
        } else if let capturedWindow = target.windowID {
            guard backend.windowID(of: current) == capturedWindow else {
                return .differentWindow
            }
        }
        return .same
    }

    public func verifySameEditableTarget(_ target: TargetDescriptor) -> Bool {
        verify(target) == .same
    }
}
