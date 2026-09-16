import Foundation

@MainActor
protocol SettingsBackend: AnyObject {
    var shortcut: TriggerShortcut { get set }
    var selectedModelID: String? { get set }
    var selectedMicrophoneID: String? { get set }
    var launchAtLogin: Bool { get set }

    var models: [ModelItem] { get }
    var microphones: [MicrophoneItem] { get }
    var microphonePermission: PermissionState { get }
    var accessibilityPermission: PermissionState { get }

    func requestMicrophonePermission() async -> Bool
    func openMicrophoneSettings()
    func openAccessibilitySettings()
    func downloadModel(id: String)
    func loadModel(id: String)

    var onChange: (() -> Void)? { get set }
}

@MainActor
protocol RecoveryActionHandling: AnyObject {
    var onOpenSettings: (() -> Void)? { get set }
    func performRecoveryAction(_ action: Notice.Action)
    func noticeDidExpire(_ notice: Notice)
}

@MainActor
protocol UpdateChecking: AnyObject {
    var canCheckForUpdates: Bool { get }
    var sessionIsActive: Bool { get set }
    func checkForUpdates()
}

struct AppServices {
    var settings: SettingsBackend
    var recovery: RecoveryActionHandling
    var updater: UpdateChecking
}
