import AppKit
import Foundation

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var liveServices: LiveServices?
    private var settingsViewModel: SettingsViewModel?
    private var settingsWindow: SettingsWindowController?
    private var indicator: IndicatorWindowController?
    private var menuBar: MenuBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let model = AppModel()
        let updater = UpdateController()
        let live = LiveServices(model: model, updater: updater)
        liveServices = live

        let viewModel = SettingsViewModel(backend: live.services.settings)
        settingsViewModel = viewModel

        let settings = SettingsWindowController(viewModel: viewModel)
        settingsWindow = settings

        let indicatorController = IndicatorWindowController(model: model)
        indicator = indicatorController

        menuBar = MenuBarController(model: model, updater: updater) { [weak settings] in
            settings?.present()
        }

        live.onSessionActivityChanged = { active in
            viewModel.sessionInProgress = active
            updater.sessionIsActive = active
        }

        let recovery = live.services.recovery
        indicatorController.onNoticeAction = { action in
            recovery.performRecoveryAction(action)
        }
        indicatorController.onNoticeDismissed = { notice in
            recovery.noticeDidExpire(notice)
        }
        recovery.onOpenSettings = { [weak settings] in
            settings?.present()
        }

        live.start()

        if viewModel.setupRequired {
            settings.present()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        liveServices?.stop()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
