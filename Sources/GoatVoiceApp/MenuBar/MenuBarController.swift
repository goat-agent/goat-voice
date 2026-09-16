import AppKit
import Combine

@MainActor
final class MenuBarController: NSObject {
    private let statusItem: NSStatusItem
    private let model: AppModel
    private let updater: UpdateChecking
    private let onOpenSettings: () -> Void
    private var cancellables = Set<AnyCancellable>()

    private let statusMenuItem = NSMenuItem()
    private let instructionMenuItem = NSMenuItem()
    private let modelMenuItem = NSMenuItem()
    private let updatesMenuItem = NSMenuItem()

    init(model: AppModel, updater: UpdateChecking, onOpenSettings: @escaping () -> Void) {
        self.model = model
        self.updater = updater
        self.onOpenSettings = onOpenSettings
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()
        configureIcon()
        buildMenu()
        observe()
    }

    private func configureIcon() {
        guard let button = statusItem.button else { return }
        let image = NSImage(
            systemSymbolName: "waveform",
            accessibilityDescription: "Goat Voice"
        )
        image?.isTemplate = true
        button.image = image
        button.imagePosition = .imageOnly
    }

    private func buildMenu() {
        let menu = NSMenu()
        menu.delegate = self

        for item in [statusMenuItem, instructionMenuItem, modelMenuItem] {
            item.isEnabled = false
            menu.addItem(item)
        }

        menu.addItem(.separator())

        let settingsItem = NSMenuItem(
            title: "Settings…",
            action: #selector(openSettings),
            keyEquivalent: ","
        )
        settingsItem.target = self
        menu.addItem(settingsItem)

        updatesMenuItem.title = "Check for Updates…"
        updatesMenuItem.action = #selector(checkForUpdates)
        updatesMenuItem.target = self
        menu.addItem(updatesMenuItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(
            title: "Quit Goat Voice",
            action: #selector(quit),
            keyEquivalent: "q"
        )
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
        refreshDynamicItems()
    }

    private func observe() {
        model.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refreshDynamicItems() }
            .store(in: &cancellables)
    }

    private func refreshDynamicItems() {
        statusMenuItem.title = model.menuStatus.title
        instructionMenuItem.title = "Hold \(model.shortcutDisplayName) to speak"
        modelMenuItem.title = model.selectedModelTitle
        modelMenuItem.isHidden = model.selectedModelTitle.isEmpty
        updatesMenuItem.isEnabled = updater.canCheckForUpdates && !updater.sessionIsActive
    }

    @objc private func openSettings() {
        onOpenSettings()
    }

    @objc private func checkForUpdates() {
        updater.checkForUpdates()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

extension MenuBarController: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        refreshDynamicItems()
    }
}
