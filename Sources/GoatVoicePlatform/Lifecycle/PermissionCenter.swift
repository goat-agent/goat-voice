import ApplicationServices
import AVFoundation
import Foundation

public enum MicrophonePermission: Sendable, Equatable {
    case notDetermined
    case granted
    case denied
    case restricted
}

public enum AccessibilityPermission: Sendable, Equatable {
    case trusted
    case untrusted
}

public protocol PermissionProbing: Sendable {
    func microphoneStatus() -> MicrophonePermission
    func requestMicrophoneAccess() async -> Bool
    func accessibilityStatus() -> AccessibilityPermission
    func promptForAccessibility() -> Bool
}

public final class PermissionCenter: Sendable {
    private let probe: PermissionProbing

    public init(probe: PermissionProbing) {
        self.probe = probe
    }

    public func microphone() -> MicrophonePermission {
        probe.microphoneStatus()
    }

    public func requestMicrophone() async -> Bool {
        await probe.requestMicrophoneAccess()
    }

    public func accessibility() -> AccessibilityPermission {
        probe.accessibilityStatus()
    }

    public func requestAccessibilityPrompt() -> Bool {
        probe.promptForAccessibility()
    }
}

public struct SystemPermissionProbe: PermissionProbing {
    public init() {}

    public func microphoneStatus() -> MicrophonePermission {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .notDetermined: return .notDetermined
        case .authorized: return .granted
        case .denied: return .denied
        case .restricted: return .restricted
        @unknown default: return .denied
        }
    }

    public func requestMicrophoneAccess() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    public func accessibilityStatus() -> AccessibilityPermission {
        AXIsProcessTrusted() ? .trusted : .untrusted
    }

    public func promptForAccessibility() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }
}
