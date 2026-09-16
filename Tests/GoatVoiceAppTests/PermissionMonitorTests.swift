import AppKit
import Foundation
import GoatVoicePlatform
import XCTest
@testable import GoatVoiceApp

@MainActor
final class PermissionMonitorTests: XCTestCase {
    func testGrantIsDetectedWithoutApplicationActivation() async {
        let probe = FakePermissionProbe()
        probe.accessibility = .untrusted
        let monitor = PermissionMonitor(permissions: PermissionCenter(probe: probe),
                                        notifications: NotificationCenter())
        let granted = expectation(description: "Accessibility grant observed in background")
        monitor.onChange = { state in
            if state.accessibility == .trusted { granted.fulfill() }
        }
        monitor.start()
        defer { monitor.stop() }
        probe.accessibility = .trusted
        await fulfillment(of: [granted], timeout: 1)
    }

    func testUnchangedPermissionsDoNotRepeatedlyRefreshUI() async throws {
        let probe = FakePermissionProbe()
        let monitor = makeMonitor(probe)
        var changes = 0
        monitor.onChange = { _ in changes += 1 }
        monitor.start()
        monitor.start()
        defer { monitor.stop() }
        try await Task.sleep(for: .milliseconds(40))
        monitor.refresh()
        XCTAssertEqual(changes, 1)
    }

    func testActivationRefreshesBeforeSlowReadyPoll() async {
        let probe = FakePermissionProbe()
        let notifications = NotificationCenter()
        let monitor = PermissionMonitor(permissions: PermissionCenter(probe: probe),
                                        notifications: notifications,
                                        readyInterval: .seconds(60))
        let revoked = expectation(description: "Activation rechecks trust immediately")
        monitor.onChange = { state in
            if state.accessibility == .untrusted { revoked.fulfill() }
        }
        monitor.start()
        defer { monitor.stop() }
        probe.accessibility = .untrusted
        notifications.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        await fulfillment(of: [revoked], timeout: 1)
    }

    func testStoppingSuppressesPendingPollAndActivation() async throws {
        let probe = FakePermissionProbe()
        let notifications = NotificationCenter()
        let monitor = makeMonitor(probe, notifications: notifications)
        var changes = 0
        monitor.onChange = { _ in changes += 1 }
        monitor.start()
        probe.accessibility = .untrusted
        notifications.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        monitor.stop()
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertEqual(changes, 1)
    }

    func testRestartUsesFreshStateWithoutDuplicateObservers() async throws {
        let probe = FakePermissionProbe()
        let monitor = makeMonitor(probe)
        var states: [AccessibilityPermission] = []
        monitor.onChange = { states.append($0.accessibility) }
        monitor.start()
        monitor.stop()
        probe.accessibility = .untrusted
        monitor.start()
        defer { monitor.stop() }
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertEqual(states, [.trusted, .untrusted])
    }

    func testPollingDoesNotRetainMonitor() async throws {
        let probe = FakePermissionProbe()
        var monitor: PermissionMonitor? = makeMonitor(probe)
        weak var weakMonitor = monitor
        monitor?.start()
        await Task.yield()
        monitor = nil
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertNil(weakMonitor)
    }

    func testGrantStartsInputMonitorWhileApplicationRemainsInactive() async {
        let harness = DriverLifecycleTests.Harness()
        harness.permissionProbe.accessibility = .untrusted
        harness.driver.start()
        XCTAssertEqual(harness.input.startCalls, 0)
        let monitor = makeMonitor(harness.permissionProbe)
        let started = expectation(description: "Granted trust starts global trigger")
        monitor.onChange = { state in
            harness.driver.permissionsDidChange()
            if state.accessibility == .trusted { started.fulfill() }
        }
        monitor.start()
        defer {
            monitor.stop()
            harness.driver.stop()
        }
        harness.permissionProbe.accessibility = .trusted
        await fulfillment(of: [started], timeout: 1)
        XCTAssertTrue(harness.input.started)
        XCTAssertEqual(harness.input.startCalls, 1)
    }

    func testTrustPropagationFailureRetriesWithoutAnotherPermissionChange() async throws {
        let harness = DriverLifecycleTests.Harness()
        harness.permissionProbe.accessibility = .untrusted
        harness.driver.start()
        let monitor = makeMonitor(harness.permissionProbe)
        monitor.onChange = { _ in harness.driver.permissionsDidChange() }
        monitor.onPoll = { harness.driver.reconcileInputMonitor() }
        monitor.start()
        defer {
            monitor.stop()
            harness.driver.stop()
        }
        harness.input.startError = EventTapError.creationFailed
        harness.permissionProbe.accessibility = .trusted
        for _ in 0..<100 {
            if harness.input.startCalls == 1 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(harness.input.startCalls, 1)
        harness.input.startError = nil
        let limit = ContinuousClock.now + .seconds(2)
        while !harness.input.started, ContinuousClock.now < limit {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(harness.input.started)
        XCTAssertEqual(harness.input.startCalls, 2)
    }

    func testRevocationStopsInputMonitorAndGrantRestartsIt() {
        let harness = DriverLifecycleTests.Harness()
        harness.driver.start()
        defer { harness.driver.stop() }
        XCTAssertTrue(harness.input.started)
        harness.permissionProbe.accessibility = .untrusted
        harness.driver.permissionsDidChange()
        XCTAssertFalse(harness.input.started)
        harness.permissionProbe.accessibility = .trusted
        harness.driver.permissionsDidChange()
        XCTAssertTrue(harness.input.started)
        XCTAssertEqual(harness.input.startCalls, 2)
    }

    private func makeMonitor(_ probe: FakePermissionProbe,
                             notifications: NotificationCenter = NotificationCenter()) -> PermissionMonitor {
        PermissionMonitor(permissions: PermissionCenter(probe: probe),
                          notifications: notifications,
                          setupInterval: .milliseconds(10),
                          readyInterval: .milliseconds(10))
    }
}
