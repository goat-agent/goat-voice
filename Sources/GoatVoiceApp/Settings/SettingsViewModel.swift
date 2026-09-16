import AppKit
import Foundation

@MainActor
final class SettingsViewModel: ObservableObject {
    @Published private(set) var models: [ModelItem] = []
    @Published private(set) var microphones: [MicrophoneItem] = []
    @Published private(set) var microphonePermission: PermissionState = .notDetermined
    @Published private(set) var accessibilityPermission: PermissionState = .notDetermined
    @Published private(set) var shortcut: TriggerShortcut = .default
    @Published private(set) var launchAtLogin = false
    @Published private(set) var selectedModelID: String?
    @Published private(set) var selectedMicrophoneID: String?
    @Published private(set) var isRecordingShortcut = false
    @Published private(set) var shortcutPreview: String?
    @Published var sessionInProgress = false

    private let backend: SettingsBackend
    private let capture = ShortcutCaptureController()

    init(backend: SettingsBackend) {
        self.backend = backend
        capture.onOutcome = { [weak self] outcome in
            Task { @MainActor in self?.handleCapture(outcome) }
        }
        capture.onPreviewChange = { [weak self] preview in
            Task { @MainActor in self?.shortcutPreview = preview }
        }
        backend.onChange = { [weak self] in
            Task { @MainActor in self?.reload() }
        }
        reload()
    }

    var setupRequired: Bool {
        microphonePermission != .allowed
            || accessibilityPermission != .allowed
            || effectiveModel?.state != .ready
    }

    var effectiveModel: ModelItem? {
        if let selectedModelID, let selected = models.first(where: { $0.id == selectedModelID }) {
            return selected
        }
        return models.first(where: \.isRecommended) ?? models.first
    }

    var shortcutCaption: String {
        "Hold \(shortcut.displayName) to speak"
    }

    func reload() {
        models = backend.models
        microphones = backend.microphones
        microphonePermission = backend.microphonePermission
        accessibilityPermission = backend.accessibilityPermission
        shortcut = backend.shortcut
        launchAtLogin = backend.launchAtLogin
        selectedModelID = backend.selectedModelID
        selectedMicrophoneID = backend.selectedMicrophoneID
    }

    func allowMicrophone() {
        Task {
            _ = await backend.requestMicrophonePermission()
            reload()
        }
    }

    func openMicrophoneSettings() {
        backend.openMicrophoneSettings()
    }

    func openAccessibilitySettings() {
        backend.openAccessibilitySettings()
    }

    func selectModel(_ id: String?) {
        guard !sessionInProgress else { return }
        backend.selectedModelID = id
        reload()
    }

    func selectMicrophone(_ id: String?) {
        backend.selectedMicrophoneID = id
        reload()
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        backend.launchAtLogin = enabled
        reload()
    }

    func downloadSelectedModel() {
        guard let id = effectiveModel?.id else { return }
        backend.downloadModel(id: id)
        reload()
    }

    func loadSelectedModel() {
        guard let id = effectiveModel?.id else { return }
        backend.loadModel(id: id)
        reload()
    }

    func beginShortcutRecording() {
        guard !isRecordingShortcut else { return }
        isRecordingShortcut = true
        shortcutPreview = nil
        capture.start()
    }

    func cancelShortcutRecording() {
        guard isRecordingShortcut else { return }
        capture.cancel()
    }

    private func handleCapture(_ outcome: ShortcutCaptureController.Outcome) {
        isRecordingShortcut = false
        shortcutPreview = nil
        if case .committed(let newShortcut) = outcome {
            backend.shortcut = newShortcut
        }
        reload()
    }
}
