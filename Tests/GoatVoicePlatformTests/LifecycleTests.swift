import AppKit
import XCTest
@testable import GoatVoicePlatform

final class FakeNotificationCenter: NotificationObserving, @unchecked Sendable {
    private let lock = NSLock()
    private var handlers: [UUID: (Notification.Name, @Sendable () -> Void)] = [:]
    private(set) var observedNames: [Notification.Name] = []
    private(set) var cancelledCount = 0

    var activeCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return handlers.count
    }

    func observe(_ name: Notification.Name,
                 handler: @escaping @Sendable () -> Void) -> NotificationToken {
        let id = UUID()
        lock.lock()
        handlers[id] = (name, handler)
        observedNames.append(name)
        lock.unlock()
        return NotificationToken { [weak self] in
            guard let self else { return }
            self.lock.lock()
            if self.handlers.removeValue(forKey: id) != nil {
                self.cancelledCount += 1
            }
            self.lock.unlock()
        }
    }

    func post(_ name: Notification.Name) {
        lock.lock()
        let matching = handlers.values.compactMap { $0.0 == name ? $0.1 : nil }
        lock.unlock()
        for handler in matching {
            handler()
        }
    }

    func handler(for name: Notification.Name) -> (@Sendable () -> Void)? {
        lock.lock()
        defer { lock.unlock() }
        return handlers.values.first { $0.0 == name }?.1
    }
}

final class FakePermissionProbe: PermissionProbing, @unchecked Sendable {
    var microphoneResult: MicrophonePermission = .notDetermined
    var requestResult = true
    var accessibilityResult: AccessibilityPermission = .untrusted
    var promptResult = false
    private(set) var microphoneRequests = 0
    private(set) var promptRequests = 0

    func microphoneStatus() -> MicrophonePermission { microphoneResult }
    func requestMicrophoneAccess() async -> Bool {
        microphoneRequests += 1
        return requestResult
    }
    func accessibilityStatus() -> AccessibilityPermission { accessibilityResult }
    func promptForAccessibility() -> Bool {
        promptRequests += 1
        return promptResult
    }
}

final class FakeLoginItemManager: LoginItemManaging, @unchecked Sendable {
    var currentStatus: LoginItemStatus = .notRegistered
    var error: (any Error)?
    private(set) var setCalls: [Bool] = []

    func status() -> LoginItemStatus { currentStatus }

    func setEnabled(_ enabled: Bool) throws {
        setCalls.append(enabled)
        if let error { throw error }
        currentStatus = enabled ? .enabled : .notRegistered
    }
}

final class EventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [SystemLifecycleEvent] = []

    func record(_ event: SystemLifecycleEvent) {
        lock.lock()
        recorded.append(event)
        lock.unlock()
    }

    func snapshot() -> [SystemLifecycleEvent] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }
}

final class SystemStateMonitorTests: XCTestCase {
    private var workspace: FakeNotificationCenter!
    private var distributed: FakeNotificationCenter!
    private var app: FakeNotificationCenter!

    override func setUp() {
        workspace = FakeNotificationCenter()
        distributed = FakeNotificationCenter()
        app = FakeNotificationCenter()
    }

    private func makeMonitor(
        handler: @escaping @Sendable (SystemLifecycleEvent) -> Void
    ) -> SystemStateMonitor {
        SystemStateMonitor(
            workspaceCenter: workspace,
            distributedCenter: distributed,
            appCenter: app,
            handler: handler)
    }

    func testStartRegistersAllFiveObservers() {
        let monitor = makeMonitor { _ in }
        monitor.start()
        XCTAssertEqual(
            Set(workspace.observedNames),
            [NSWorkspace.willSleepNotification, NSWorkspace.didWakeNotification])
        XCTAssertEqual(
            Set(distributed.observedNames),
            [Notification.Name("com.apple.screenIsLocked"),
             Notification.Name("com.apple.screenIsUnlocked")])
        XCTAssertEqual(app.observedNames, [NSApplication.willTerminateNotification])
    }

    func testStartIsIdempotent() {
        let monitor = makeMonitor { _ in }
        monitor.start()
        monitor.start()
        XCTAssertEqual(workspace.activeCount, 2)
        XCTAssertEqual(distributed.activeCount, 2)
        XCTAssertEqual(app.activeCount, 1)
    }

    func testStopRemovesAllObservers() {
        let monitor = makeMonitor { _ in }
        monitor.start()
        monitor.stop()
        XCTAssertEqual(workspace.activeCount, 0)
        XCTAssertEqual(distributed.activeCount, 0)
        XCTAssertEqual(app.activeCount, 0)
        XCTAssertEqual(workspace.cancelledCount, 2)
        XCTAssertEqual(distributed.cancelledCount, 2)
        XCTAssertEqual(app.cancelledCount, 1)
    }

    func testStopIsIdempotent() {
        let monitor = makeMonitor { _ in }
        monitor.stop()
        monitor.start()
        monitor.stop()
        monitor.stop()
        XCTAssertEqual(workspace.activeCount, 0)
        XCTAssertEqual(workspace.cancelledCount, 2)
    }

    func testDeinitRemovesObservers() {
        var monitor: SystemStateMonitor? = makeMonitor { _ in }
        monitor?.start()
        monitor = nil
        XCTAssertEqual(workspace.activeCount, 0)
        XCTAssertEqual(distributed.activeCount, 0)
        XCTAssertEqual(app.activeCount, 0)
    }

    func testNotificationsMapToLifecycleEventsInOrder() {
        let allDelivered = expectation(description: "events")
        allDelivered.expectedFulfillmentCount = 5
        let recorder = EventRecorder()
        let monitor = makeMonitor { event in
            recorder.record(event)
            allDelivered.fulfill()
        }
        monitor.start()
        workspace.post(NSWorkspace.willSleepNotification)
        workspace.post(NSWorkspace.didWakeNotification)
        distributed.post(Notification.Name("com.apple.screenIsLocked"))
        distributed.post(Notification.Name("com.apple.screenIsUnlocked"))
        app.post(NSApplication.willTerminateNotification)
        wait(for: [allDelivered], timeout: 2)
        XCTAssertEqual(
            recorder.snapshot(),
            [.willSleep, .didWake, .screenLocked, .screenUnlocked, .willTerminate])
    }

    func testEventsAfterStopAreDropped() {
        let forbidden = expectation(description: "event")
        forbidden.isInverted = true
        let monitor = makeMonitor { _ in forbidden.fulfill() }
        monitor.start()
        monitor.stop()
        workspace.post(NSWorkspace.willSleepNotification)
        distributed.post(Notification.Name("com.apple.screenIsLocked"))
        wait(for: [forbidden], timeout: 0.4)
    }

    func testStaleCallbackFromPreviousGenerationIsDropped() {
        let forbidden = expectation(description: "event")
        forbidden.isInverted = true
        let monitor = makeMonitor { _ in forbidden.fulfill() }
        monitor.start()
        let stale = workspace.handler(for: NSWorkspace.willSleepNotification)
        monitor.stop()
        monitor.start()
        stale?()
        wait(for: [forbidden], timeout: 0.4)
    }

    func testRestartReceivesEventsAgain() {
        let delivered = expectation(description: "event")
        let monitor = makeMonitor { event in
            if event == .didWake { delivered.fulfill() }
        }
        monitor.start()
        monitor.stop()
        monitor.start()
        workspace.post(NSWorkspace.didWakeNotification)
        wait(for: [delivered], timeout: 2)
        monitor.stop()
    }
}

final class PermissionCenterTests: XCTestCase {
    func testConstructionMakesNoPermissionRequests() {
        let probe = FakePermissionProbe()
        _ = PermissionCenter(probe: probe)
        XCTAssertEqual(probe.microphoneRequests, 0)
        XCTAssertEqual(probe.promptRequests, 0)
    }

    func testMicrophoneStatusDelegatesToProbe() {
        let probe = FakePermissionProbe()
        let center = PermissionCenter(probe: probe)
        probe.microphoneResult = .granted
        XCTAssertEqual(center.microphone(), .granted)
        probe.microphoneResult = .denied
        XCTAssertEqual(center.microphone(), .denied)
    }

    func testRequestMicrophoneDelegatesToProbe() async {
        let probe = FakePermissionProbe()
        let center = PermissionCenter(probe: probe)
        probe.requestResult = true
        let granted = await center.requestMicrophone()
        XCTAssertTrue(granted)
        probe.requestResult = false
        let denied = await center.requestMicrophone()
        XCTAssertFalse(denied)
        XCTAssertEqual(probe.microphoneRequests, 2)
    }

    func testAccessibilityStatusDelegatesToProbe() {
        let probe = FakePermissionProbe()
        let center = PermissionCenter(probe: probe)
        probe.accessibilityResult = .trusted
        XCTAssertEqual(center.accessibility(), .trusted)
        probe.accessibilityResult = .untrusted
        XCTAssertEqual(center.accessibility(), .untrusted)
    }

    func testAccessibilityPromptDelegatesToProbe() {
        let probe = FakePermissionProbe()
        let center = PermissionCenter(probe: probe)
        probe.promptResult = true
        XCTAssertTrue(center.requestAccessibilityPrompt())
        XCTAssertEqual(probe.promptRequests, 1)
    }
}

final class LoginItemControllerTests: XCTestCase {
    private var manager: FakeLoginItemManager!
    private var controller: LoginItemController!

    override func setUp() {
        manager = FakeLoginItemManager()
        controller = LoginItemController(manager: manager)
    }

    func testConstructionDoesNotTouchManager() {
        XCTAssertEqual(manager.setCalls, [])
    }

    func testStatusDelegatesToManager() {
        manager.currentStatus = .requiresApproval
        XCTAssertEqual(controller.status, .requiresApproval)
        manager.currentStatus = .notFound
        XCTAssertEqual(controller.status, .notFound)
    }

    func testIsEnabledOnlyWhenStatusEnabled() {
        manager.currentStatus = .enabled
        XCTAssertTrue(controller.isEnabled)
        for status in [LoginItemStatus.notRegistered, .requiresApproval, .notFound] {
            manager.currentStatus = status
            XCTAssertFalse(controller.isEnabled)
        }
    }

    func testSetEnabledForwardsToManager() throws {
        try controller.setEnabled(true)
        try controller.setEnabled(false)
        XCTAssertEqual(manager.setCalls, [true, false])
        XCTAssertEqual(controller.status, .notRegistered)
    }

    struct RegistrationError: Error, Equatable {}

    func testManagerErrorPropagates() {
        manager.error = RegistrationError()
        XCTAssertThrowsError(try controller.setEnabled(true)) { error in
            XCTAssertEqual(error as? RegistrationError, RegistrationError())
        }
        XCTAssertEqual(manager.setCalls, [true])
        XCTAssertEqual(controller.status, .notRegistered)
    }
}
