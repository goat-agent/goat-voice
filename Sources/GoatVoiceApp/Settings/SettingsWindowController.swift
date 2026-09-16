import AppKit
import Foundation
import SwiftUI

@MainActor
final class SettingsWindowController: NSWindowController {
    private let viewModel: SettingsViewModel

    init(viewModel: SettingsViewModel) {
        self.viewModel = viewModel
        let hostingController = NSHostingController(
            rootView: SettingsView(viewModel: viewModel)
        )
        let window = NSWindow(contentViewController: hostingController)
        window.title = "Goat Voice"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.setContentSize(NSSize(width: 520, height: 440))
        window.isReleasedWhenClosed = false
        window.setAccessibilityLabel("Goat Voice Settings")
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func present() {
        guard let window else { return }
        if !window.isVisible {
            window.center()
        }
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}
