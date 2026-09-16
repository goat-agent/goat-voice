import Foundation
import XCTest
@testable import GoatVoiceCore

final class NetworkActivityPolicyTests: XCTestCase {
    func testIdlePermitsAllActivity() {
        var policy = NetworkActivityPolicy()
        XCTAssertTrue(policy.permitsNewActivity)
        for activity in NetworkActivity.allCases {
            XCTAssertEqual(policy.requestStart(activity), .allowed)
            XCTAssertEqual(policy.state(of: activity), .running)
        }
    }

    func testSessionBeginPausesDownloadsAndCancelsCheck() {
        var policy = NetworkActivityPolicy()
        policy.requestStart(.updateCheck)
        policy.requestStart(.modelDownload)
        XCTAssertEqual(
            policy.beginSession(),
            [.cancelUpdateCheck, .pause(.modelDownload)]
        )
        XCTAssertTrue(policy.sessionActive)
        XCTAssertFalse(policy.permitsNewActivity)
    }

    func testSessionBeginPausesAllRunningDownloads() {
        var policy = NetworkActivityPolicy()
        policy.requestStart(.modelDownload)
        policy.requestStart(.appDownload)
        XCTAssertEqual(
            policy.beginSession(),
            [.pause(.modelDownload), .pause(.appDownload)]
        )
    }

    func testSessionBeginWithoutWorkProducesNoEffects() {
        var policy = NetworkActivityPolicy()
        XCTAssertEqual(policy.beginSession(), [])
        XCTAssertTrue(policy.sessionActive)
    }

    func testSessionForbidsStartsAndResumes() {
        var policy = NetworkActivityPolicy()
        policy.requestStart(.modelDownload)
        _ = policy.beginSession()
        XCTAssertEqual(policy.requestStart(.modelDownload), .denied)
        XCTAssertEqual(policy.requestStart(.appDownload), .denied)
        XCTAssertEqual(policy.requestResume(.modelDownload), .denied)
        XCTAssertEqual(policy.requestResume(.appDownload), .denied)
    }

    func testDeniedRequestsDoNotMutateState() {
        var policy = NetworkActivityPolicy()
        policy.requestStart(.modelDownload)
        _ = policy.beginSession()
        policy.activityPaused(.modelDownload)
        policy.requestStart(.appDownload)
        XCTAssertNil(policy.state(of: .appDownload))
        XCTAssertEqual(policy.state(of: .modelDownload), .paused)
    }

    func testUpdateCheckDuringSessionIsDeferred() {
        var policy = NetworkActivityPolicy()
        _ = policy.beginSession()
        XCTAssertEqual(policy.requestStart(.updateCheck), .deferred)
        XCTAssertTrue(policy.deferredUpdateCheck)
        XCTAssertNil(policy.state(of: .updateCheck))
    }

    func testDeferredCheckRunsOnceOnSessionEnd() {
        var policy = NetworkActivityPolicy()
        _ = policy.beginSession()
        policy.requestStart(.updateCheck)
        policy.requestStart(.updateCheck)
        XCTAssertEqual(policy.endSession(), [.runDeferredUpdateCheck])
        XCTAssertFalse(policy.deferredUpdateCheck)
        XCTAssertEqual(policy.requestStart(.updateCheck), .allowed)
    }

    func testPausedDownloadResumesOnSessionEnd() {
        var policy = NetworkActivityPolicy()
        policy.requestStart(.modelDownload)
        _ = policy.beginSession()
        policy.activityPaused(.modelDownload)
        XCTAssertEqual(policy.endSession(), [.resume(.modelDownload)])
        XCTAssertEqual(policy.state(of: .modelDownload), .paused)
        XCTAssertEqual(policy.requestResume(.modelDownload), .allowed)
        XCTAssertEqual(policy.state(of: .modelDownload), .running)
    }

    func testRunningDownloadWithoutPauseCompletionIsNotResumed() {
        var policy = NetworkActivityPolicy()
        policy.requestStart(.modelDownload)
        _ = policy.beginSession()
        XCTAssertEqual(policy.endSession(), [])
    }

    func testFinishedActivityProducesNoEffects() {
        var policy = NetworkActivityPolicy()
        policy.requestStart(.modelDownload)
        _ = policy.beginSession()
        policy.activityFinished(.modelDownload)
        XCTAssertEqual(policy.endSession(), [])
        XCTAssertNil(policy.state(of: .modelDownload))
    }

    func testPausedUpdateCheckDefersAndClears() {
        var policy = NetworkActivityPolicy()
        policy.requestStart(.updateCheck)
        _ = policy.beginSession()
        policy.activityPaused(.updateCheck)
        XCTAssertTrue(policy.deferredUpdateCheck)
        XCTAssertNil(policy.state(of: .updateCheck))
        XCTAssertEqual(policy.endSession(), [.runDeferredUpdateCheck])
    }

    func testSessionTransitionsAreIdempotent() {
        var policy = NetworkActivityPolicy()
        policy.requestStart(.modelDownload)
        _ = policy.beginSession()
        XCTAssertEqual(policy.beginSession(), [])
        policy.activityPaused(.modelDownload)
        _ = policy.endSession()
        XCTAssertEqual(policy.endSession(), [])
        XCTAssertFalse(policy.sessionActive)
    }

    func testEffectsStayBoundedAcrossFullCycle() {
        var policy = NetworkActivityPolicy()
        for activity in NetworkActivity.allCases {
            policy.requestStart(activity)
        }
        XCTAssertEqual(policy.beginSession().count, NetworkActivity.allCases.count)
        policy.activityPaused(.modelDownload)
        policy.activityPaused(.appDownload)
        policy.requestStart(.updateCheck)
        XCTAssertEqual(
            policy.endSession(),
            [.resume(.modelDownload), .resume(.appDownload), .runDeferredUpdateCheck]
        )
    }

    func testSecondSessionRepausesStillPausedWork() {
        var policy = NetworkActivityPolicy()
        policy.requestStart(.modelDownload)
        _ = policy.beginSession()
        policy.activityPaused(.modelDownload)
        _ = policy.endSession()
        _ = policy.beginSession()
        XCTAssertEqual(policy.state(of: .modelDownload), .paused)
        XCTAssertEqual(policy.requestResume(.modelDownload), .denied)
    }

    func testResumeCompletionDuringSessionIsDenied() {
        var policy = NetworkActivityPolicy()
        policy.requestStart(.modelDownload)
        _ = policy.beginSession()
        policy.activityPaused(.modelDownload)
        _ = policy.endSession()
        _ = policy.beginSession()
        policy.activityResumed(.modelDownload)
        XCTAssertEqual(policy.state(of: .modelDownload), .paused)
        _ = policy.endSession()
        policy.activityResumed(.modelDownload)
        XCTAssertEqual(policy.state(of: .modelDownload), .running)
    }
}
