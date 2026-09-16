import AppKit
import Foundation
import GoatVoiceCore
import GoatVoicePlatform

@MainActor
final class LiveServices {
    let services: AppServices
    var onSessionActivityChanged: ((Bool) -> Void)?

    private let network: NetworkActivityCoordinator
    private let client: TranscriptionXPCClient
    private let settingsBackend: LiveSettingsBackend
    private let recovery: RecoveryController
    private let driver: SessionDriver
    private let lifecycle: SystemStateMonitor
    private let permissionMonitor: PermissionMonitor
    private var started = false

    init(model: AppModel, updater: any UpdateChecking) {
        let clock = MonotonicClock()
        let network = NetworkActivityCoordinator()
        let client = TranscriptionXPCClient(backend: NSXPCServiceBackend())
        let permissions = PermissionCenter(probe: SystemPermissionProbe())
        let settingsBackend = LiveSettingsBackend(
            model: model, transcription: client, network: network, permissions: permissions)
        let pasteboard = GeneralPasteboard()
        let clipboard = ClipboardCoordinator(backend: pasteboard)
        let accessibility = ApplicationServicesBackend()
        let targetResolver = TargetResolver(
            backend: accessibility, displayLookup: CoreGraphicsDisplayLookup())
        let intentGuard = UserIntentGuard(backend: accessibility)
        let latch = InterruptibilityLatch()
        let engine = TriggerEngine(spec: settingsBackend.configuredTrigger)
        let monitor = InputTriggerMonitor(
            monitor: CGEventTapMonitor(), engine: engine, interruptibilityLatch: latch)
        let capture = AVAudioCaptureSession()
        let recovery = RecoveryController(clipboard: clipboard, clock: clock)
        let permissionMonitor = PermissionMonitor(permissions: permissions)
        let driver = SessionDriver(deps: SessionDriver.Dependencies(
            settings: settingsBackend,
            sink: model,
            capture: capture,
            devices: CoreAudioDeviceResolver(),
            monitor: monitor,
            latch: latch,
            clipboard: clipboard,
            pasteboard: pasteboard,
            accessibility: accessibility,
            targetResolver: targetResolver,
            intentGuard: intentGuard,
            permissions: permissions,
            client: client,
            network: network,
            updater: updater,
            recovery: recovery,
            clock: clock,
            makeInserter: { TextInserter(poster: CGEventPastePoster()) },
            isAppActive: { NSApplication.shared.isActive }))

        self.network = network
        self.client = client
        self.settingsBackend = settingsBackend
        self.recovery = recovery
        self.driver = driver
        self.permissionMonitor = permissionMonitor
        permissionMonitor.onChange = { [weak driver] _ in
            driver?.permissionsDidChange()
        }
        permissionMonitor.onPoll = { [weak driver] in
            driver?.reconcileInputMonitor()
        }
        self.lifecycle = SystemStateMonitor.system { [weak driver, recovery] event in
            switch event {
            case .willSleep, .screenLocked, .willTerminate:
                recovery.invalidateSynchronously()
            case .didWake, .screenUnlocked:
                break
            }
            driver?.noteSystemInterruption(event)
            MainHop.async { driver?.handleLifecycle(event) }
        }
        services = AppServices(settings: settingsBackend, recovery: recovery, updater: updater)

        driver.onSessionActivityChanged = { [weak self] active in
            self?.onSessionActivityChanged?(active)
        }
        settingsBackend.onTriggerChanged = { [weak driver] in
            driver?.triggerSpecChanged()
        }
        recovery.presentNotice = { [weak driver] notice, displayID in
            driver?.presentExternalNotice(notice, displayID: displayID)
        }
        recovery.noticeResolved = { [weak driver] notice in
            driver?.noticeResolved(notice)
        }
    }

    func start() {
        guard !started else { return }
        started = true
        lifecycle.start()
        driver.start()
        permissionMonitor.start()
        Task { await settingsBackend.start() }
    }

    func stop() {
        guard started else { return }
        started = false
        permissionMonitor.stop()
        lifecycle.stop()
        driver.stop()
        settingsBackend.stop()
        let client = client
        Task { await client.invalidate() }
    }
}
