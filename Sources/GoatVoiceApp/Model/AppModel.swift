import AppKit
import Foundation

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var presentation: SessionPresentation = .idle
    @Published private(set) var audioLevel: Double = 0
    @Published private(set) var previewText: String?
    @Published private(set) var menuStatus: MenuStatus = .setupRequired
    @Published private(set) var shortcutDisplayName: String = TriggerShortcut.default.displayName
    @Published private(set) var selectedModelTitle: String = ""
    @Published private(set) var reduceMotion: Bool

    init() {
        reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    func apply(presentation: SessionPresentation) {
        let previous = self.presentation.content
        self.presentation = presentation
        if case .hidden = presentation.content {
            audioLevel = 0
        }
        switch presentation.content {
        case .hidden, .notice, .exiting:
            previewText = nil
        case .strip:
            if case .strip = previous { break }
            previewText = nil
        }
    }

    func apply(previewText: String?) {
        guard case .strip = presentation.content else { return }
        let trimmed = previewText?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = (trimmed?.isEmpty == false) ? trimmed : nil
        guard normalized != self.previewText else { return }
        self.previewText = normalized
    }

    func apply(audioLevel: Double) {
        self.audioLevel = min(max(audioLevel, 0), 1)
    }

    func apply(shortcut: TriggerShortcut) {
        shortcutDisplayName = shortcut.displayName
    }

    func refreshReduceMotion() {
        reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    func applyReadiness(
        microphone: PermissionState,
        accessibility: PermissionState,
        selectedModel: ModelItem?
    ) {
        selectedModelTitle = selectedModel?.title ?? ""
        guard microphone == .allowed, accessibility == .allowed else {
            menuStatus = .setupRequired
            return
        }
        guard let model = selectedModel else {
            menuStatus = .setupRequired
            return
        }
        switch model.state {
        case .ready:
            menuStatus = .ready
        case .downloading(let progress):
            menuStatus = .downloadingModel(fraction: progress.fraction)
        case .verifying:
            menuStatus = .downloadingModel(fraction: nil)
        case .loading:
            menuStatus = .loadingModel
        case .notInstalled:
            menuStatus = .setupRequired
        case .downloadFailed, .checksumFailed, .loadFailed:
            menuStatus = .modelUnavailable
        }
    }
}
