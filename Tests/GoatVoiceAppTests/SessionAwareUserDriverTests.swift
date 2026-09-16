import XCTest
import Sparkle
@testable import GoatVoiceApp

@MainActor
final class FakeUserDriver: NSObject, SPUUserDriver {
    enum Event: Equatable {
        case updateCheck
        case downloadInitiated
        case readyToInstall
        case dismissInstallation
        case updateInFocus
    }

    private(set) var events: [Event] = []
    var lastCheckCancellation: (() -> Void)?
    var lastDownloadCancellation: (() -> Void)?
    var readyReply: ((SPUUserUpdateChoice) -> Void)?

    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {}
    func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState, reply: @escaping (SPUUserUpdateChoice) -> Void) {}
    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}
    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) {}
    func showUpdateNotFoundWithError(_ error: Error) async {}
    func showUpdaterError(_ error: Error) async {}
    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {}
    func showDownloadDidReceiveData(ofLength length: UInt64) {}
    func showDownloadDidStartExtractingUpdate() {}
    func showExtractionReceivedProgress(_ progress: Double) {}
    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool, retryTerminatingApplication: @escaping () -> Void) {}
    func showUpdateInstalledAndRelaunched(_ relaunched: Bool) async {}

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        events.append(.updateCheck)
        lastCheckCancellation = cancellation
    }

    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        events.append(.downloadInitiated)
        lastDownloadCancellation = cancellation
    }

    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        events.append(.readyToInstall)
        readyReply = reply
    }

    func dismissUpdateInstallation() {
        events.append(.dismissInstallation)
    }

    func showUpdateInFocus() {
        events.append(.updateInFocus)
    }
}

@MainActor
final class SessionAwareUserDriverTests: XCTestCase {
    private var fake: FakeUserDriver!
    private var driver: SessionAwareUserDriver!

    override func setUp() {
        fake = FakeUserDriver()
        driver = SessionAwareUserDriver(standard: fake)
    }

    private func waitForMainQueue() async {
        try? await Task.sleep(nanoseconds: 50_000_000)
    }

    func testSessionActivationCancelsInFlightCheckAndDownload() async {
        var checkCancelled = false
        var downloadCancelled = false
        driver.showUserInitiatedUpdateCheck { checkCancelled = true }
        driver.showDownloadInitiated { downloadCancelled = true }
        XCTAssertEqual(fake.events, [.updateCheck, .downloadInitiated])

        driver.sessionIsActive = true
        await waitForMainQueue()
        XCTAssertTrue(checkCancelled)
        XCTAssertTrue(downloadCancelled)
    }

    func testCheckInitiatedDuringSessionIsCancelledWithoutForwarding() async {
        driver.sessionIsActive = true
        var checkCancelled = false
        driver.showUserInitiatedUpdateCheck { checkCancelled = true }
        await waitForMainQueue()
        XCTAssertTrue(checkCancelled)
        XCTAssertFalse(fake.events.contains(.updateCheck))
    }

    func testDownloadInitiatedDuringSessionIsCancelledWithoutForwarding() async {
        driver.sessionIsActive = true
        var downloadCancelled = false
        driver.showDownloadInitiated { downloadCancelled = true }
        await waitForMainQueue()
        XCTAssertTrue(downloadCancelled)
        XCTAssertFalse(fake.events.contains(.downloadInitiated))
    }

    func testReadyToInstallRepliesDismissDuringSession() {
        driver.sessionIsActive = true
        var choice: SPUUserUpdateChoice?
        driver.showReady { choice = $0 }
        XCTAssertEqual(choice, .dismiss)
        XCTAssertFalse(fake.events.contains(.readyToInstall))
    }

    func testReadyToInstallForwardsWhenIdle() {
        var choice: SPUUserUpdateChoice?
        driver.showReady { choice = $0 }
        XCTAssertTrue(fake.events.contains(.readyToInstall))
        fake.readyReply?(.install)
        XCTAssertEqual(choice, .install)
    }

    func testSessionStartingAfterPromptBlocksLaterInstallChoice() {
        var choice: SPUUserUpdateChoice?
        driver.showReady { choice = $0 }
        driver.sessionIsActive = true
        fake.readyReply?(.install)
        XCTAssertEqual(choice, .dismiss)
    }

    func testExtractionClearsDownloadCancellation() async {
        var downloadCancelled = false
        driver.showDownloadInitiated { downloadCancelled = true }
        driver.showDownloadDidStartExtractingUpdate()

        driver.sessionIsActive = true
        await waitForMainQueue()
        XCTAssertFalse(downloadCancelled)
    }

    func testNotFoundClearsCheckCancellation() async {
        var checkCancelled = false
        driver.showUserInitiatedUpdateCheck { checkCancelled = true }
        await driver.showUpdateNotFoundWithError(NSError(domain: "test", code: 1))

        driver.sessionIsActive = true
        await waitForMainQueue()
        XCTAssertFalse(checkCancelled)
    }

    func testDismissClearsAllCancellations() async {
        var checkCancelled = false
        var downloadCancelled = false
        driver.showUserInitiatedUpdateCheck { checkCancelled = true }
        driver.showDownloadInitiated { downloadCancelled = true }
        driver.dismissUpdateInstallation()
        XCTAssertTrue(fake.events.contains(.dismissInstallation))

        driver.sessionIsActive = true
        await waitForMainQueue()
        XCTAssertFalse(checkCancelled)
        XCTAssertFalse(downloadCancelled)
    }

    func testStaleCancellationCannotKillLaterCheck() async {
        var firstCancelled = 0
        driver.showUserInitiatedUpdateCheck { firstCancelled += 1 }
        driver.sessionIsActive = true
        await waitForMainQueue()
        XCTAssertEqual(firstCancelled, 1)

        driver.sessionIsActive = false
        var secondCancelled = 0
        driver.showUserInitiatedUpdateCheck { secondCancelled += 1 }
        driver.sessionIsActive = true
        await waitForMainQueue()
        XCTAssertEqual(firstCancelled, 1)
        XCTAssertEqual(secondCancelled, 1)
    }

    func testUpdaterErrorClearsCancellations() async {
        var checkCancelled = false
        var downloadCancelled = false
        driver.showUserInitiatedUpdateCheck { checkCancelled = true }
        driver.showDownloadInitiated { downloadCancelled = true }
        await driver.showUpdaterError(NSError(domain: "test", code: 2))

        driver.sessionIsActive = true
        await waitForMainQueue()
        XCTAssertFalse(checkCancelled)
        XCTAssertFalse(downloadCancelled)
    }
}
