import CoreGraphics
import Foundation
import GoatVoiceCore
import GoatVoicePlatform

@MainActor
protocol SessionPresenting: AnyObject {
    func apply(presentation: SessionPresentation)
    func apply(audioLevel: Double)
    func apply(previewText: String?)
}

extension SessionPresenting {
    func apply(previewText: String?) {}
}

extension AppModel: SessionPresenting {}

@MainActor
protocol SessionSettingsPort: SettingsBackend {
    var configuredTrigger: TriggerSpec { get }
    var microphoneSelection: MicrophoneSelection { get }
    var selectedModelLocation: LiveModelLocation? { get }
    var onTriggerChanged: (() -> Void)? { get set }
    func setSessionActive(_ active: Bool)
    func refreshPermissions()
    func refreshPermissionsAndDevices()
}

extension SessionSettingsPort {
    func refreshPermissions() {
        refreshPermissionsAndDevices()
    }
}

extension LiveSettingsBackend: SessionSettingsPort {}

struct ReleaseContext: Sendable {
    var finishReason: FinishReason
    var boundaryChangeCount: Int
    var target: TargetDescriptor?
}

enum PreparedRecovery: Equatable, Sendable {
    case copiedToClipboard
    case explicitCopy(ExplicitCopyReason)
}
