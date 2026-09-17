import XCTest
@testable import GoatVoiceApp

final class UpdateConfigurationTests: XCTestCase {
    private let feed = "https://example.com/appcast.xml"
    private let feedURL = URL(string: "https://example.com/appcast.xml")!

    private func makeKey(_ byteCount: Int = 32) -> String {
        Data(repeating: 0xA5, count: byteCount).base64EncodedString()
    }

    func testMissingValuesResolveAsNotConfigured() {
        let configuration = UpdateConfiguration(feedURLValue: nil, publicKeyValue: nil)
        XCTAssertEqual(configuration, .notConfigured)
        XCTAssertFalse(configuration.isUsable)
    }

    func testValidHTTPSFeedAndKeyResolveAsConfigured() {
        let configuration = UpdateConfiguration(feedURLValue: feed, publicKeyValue: makeKey())
        XCTAssertEqual(configuration, .configured(feedURL: feedURL))
        XCTAssertTrue(configuration.isUsable)
    }

    func testQuotedFeedAndWhitespacePaddedKeyResolveAsConfigured() {
        let configuration = UpdateConfiguration(
            feedURLValue: "\"\(feed)\"",
            publicKeyValue: "  \(makeKey())\n"
        )
        XCTAssertEqual(configuration, .configured(feedURL: feedURL))
    }

    func testUppercaseSchemeAndHostResolveAsConfigured() {
        let configuration = UpdateConfiguration(
            feedURLValue: "HTTPS://EXAMPLE.COM/appcast.xml",
            publicKeyValue: makeKey()
        )
        guard case .configured(let resolvedURL) = configuration else {
            XCTFail("Expected configured, got \(configuration)")
            return
        }
        XCTAssertEqual(resolvedURL.scheme?.lowercased(), "https")
        XCTAssertEqual(resolvedURL.host?.lowercased(), "example.com")
    }

    func testHTTPFeedIsRejectedAsInsecure() {
        let configuration = UpdateConfiguration(
            feedURLValue: "http://example.com/appcast.xml",
            publicKeyValue: makeKey()
        )
        XCTAssertEqual(configuration, .misconfigured([.insecureFeedURL]))
    }

    func testNonHTTPSCustomSchemeIsRejectedAsInsecure() {
        let configuration = UpdateConfiguration(
            feedURLValue: "feed://example.com/appcast.xml",
            publicKeyValue: makeKey()
        )
        XCTAssertEqual(configuration, .misconfigured([.insecureFeedURL]))
    }

    func testRelativeFeedStringIsRejectedAsMalformed() {
        let configuration = UpdateConfiguration(
            feedURLValue: "example.com/appcast.xml",
            publicKeyValue: makeKey()
        )
        XCTAssertEqual(configuration, .misconfigured([.malformedFeedURL]))
    }

    func testUnparseableFeedIsRejectedAsMalformed() {
        let configuration = UpdateConfiguration(
            feedURLValue: "https://exa mple.com/appcast.xml",
            publicKeyValue: makeKey()
        )
        XCTAssertEqual(configuration, .misconfigured([.malformedFeedURL]))
    }

    func testFeedWithoutHostIsRejectedAsMalformed() {
        let configuration = UpdateConfiguration(
            feedURLValue: "https:///appcast.xml",
            publicKeyValue: makeKey()
        )
        XCTAssertEqual(configuration, .misconfigured([.malformedFeedURL]))
    }

    func testEmptyFeedIsRejectedAsMissing() {
        let configuration = UpdateConfiguration(feedURLValue: "", publicKeyValue: makeKey())
        XCTAssertEqual(configuration, .misconfigured([.missingFeedURL]))
    }

    func testNonStringFeedIsRejectedAsMalformed() {
        let configuration = UpdateConfiguration(feedURLValue: 42, publicKeyValue: makeKey())
        XCTAssertEqual(configuration, .misconfigured([.malformedFeedURL]))
    }

    func testMissingKeyIsRejected() {
        let configuration = UpdateConfiguration(feedURLValue: feed, publicKeyValue: nil)
        XCTAssertEqual(configuration, .misconfigured([.missingPublicKey]))
    }

    func testEmptyKeyIsRejectedAsMissing() {
        let configuration = UpdateConfiguration(feedURLValue: feed, publicKeyValue: "   ")
        XCTAssertEqual(configuration, .misconfigured([.missingPublicKey]))
    }

    func testNonBase64KeyIsRejectedAsMalformed() {
        let configuration = UpdateConfiguration(
            feedURLValue: feed,
            publicKeyValue: "not-a-valid-key!!"
        )
        XCTAssertEqual(configuration, .misconfigured([.malformedPublicKey]))
    }

    func testShortKeyIsRejectedAsMalformed() {
        let configuration = UpdateConfiguration(feedURLValue: feed, publicKeyValue: makeKey(16))
        XCTAssertEqual(configuration, .misconfigured([.malformedPublicKey]))
    }

    func testLongKeyIsRejectedAsMalformed() {
        let configuration = UpdateConfiguration(feedURLValue: feed, publicKeyValue: makeKey(64))
        XCTAssertEqual(configuration, .misconfigured([.malformedPublicKey]))
    }

    func testNonStringKeyIsRejectedAsMalformed() {
        let configuration = UpdateConfiguration(feedURLValue: feed, publicKeyValue: [1, 2, 3])
        XCTAssertEqual(configuration, .misconfigured([.malformedPublicKey]))
    }

    func testKeyOnlyPresentIsRejectedAsMissingFeed() {
        let configuration = UpdateConfiguration(feedURLValue: nil, publicKeyValue: makeKey())
        XCTAssertEqual(configuration, .misconfigured([.missingFeedURL]))
    }

    func testMultipleIssuesAreCollectedInOrder() {
        let configuration = UpdateConfiguration(
            feedURLValue: "http://example.com/appcast.xml",
            publicKeyValue: "bad!"
        )
        XCTAssertEqual(configuration, .misconfigured([.insecureFeedURL, .malformedPublicKey]))
    }
}

@MainActor
private final class FakeSparkleUpdater: SparkleUpdating {
    var canCheckForUpdates = true
    private(set) var checkCount = 0

    func checkForUpdates() {
        checkCount += 1
    }
}

@MainActor
final class UpdateControllerTests: XCTestCase {
    private let feedURL = URL(string: "https://example.com/appcast.xml")!

    private func makeController(
        configuration: UpdateConfiguration,
        factory: (@MainActor () throws -> any SparkleUpdating)? = nil
    ) -> UpdateController {
        UpdateController(
            bundle: .main,
            configuration: configuration,
            updaterFactory: factory
        )
    }

    func testUsableConfigurationAllowsManualCheck() {
        let updater = FakeSparkleUpdater()
        let controller = makeController(
            configuration: .configured(feedURL: feedURL),
            factory: { updater }
        )
        XCTAssertTrue(controller.canCheckForUpdates)
        controller.checkForUpdates()
        XCTAssertEqual(updater.checkCount, 1)
    }

    func testNotConfiguredDisablesChecksWithoutFactoryUse() {
        var factoryCalls = 0
        let controller = makeController(configuration: .notConfigured) {
            factoryCalls += 1
            return FakeSparkleUpdater()
        }
        XCTAssertFalse(controller.canCheckForUpdates)
        controller.checkForUpdates()
        XCTAssertEqual(factoryCalls, 0)
    }

    func testMisconfiguredDisablesChecksWithoutFactoryUse() {
        var factoryCalls = 0
        let controller = makeController(
            configuration: .misconfigured([.missingPublicKey])
        ) {
            factoryCalls += 1
            return FakeSparkleUpdater()
        }
        XCTAssertFalse(controller.canCheckForUpdates)
        controller.checkForUpdates()
        XCTAssertEqual(factoryCalls, 0)
    }

    func testStartFailurePermanentlyDisablesChecks() {
        var factoryCalls = 0
        let controller = makeController(
            configuration: .configured(feedURL: feedURL)
        ) {
            factoryCalls += 1
            throw NSError(domain: "test", code: 1)
        }
        XCTAssertTrue(controller.canCheckForUpdates)
        controller.checkForUpdates()
        XCTAssertFalse(controller.canCheckForUpdates)
        controller.checkForUpdates()
        XCTAssertEqual(factoryCalls, 1)
    }

    func testActiveSessionBlocksCheck() {
        let updater = FakeSparkleUpdater()
        let controller = makeController(
            configuration: .configured(feedURL: feedURL),
            factory: { updater }
        )
        controller.sessionIsActive = true
        XCTAssertFalse(controller.canCheckForUpdates)
        controller.checkForUpdates()
        XCTAssertEqual(updater.checkCount, 0)
    }

    func testRunningUpdaterInFlightStateBlocksRepeatedChecks() {
        let updater = FakeSparkleUpdater()
        let controller = makeController(
            configuration: .configured(feedURL: feedURL),
            factory: { updater }
        )
        controller.checkForUpdates()
        updater.canCheckForUpdates = false
        XCTAssertFalse(controller.canCheckForUpdates)
        controller.checkForUpdates()
        XCTAssertEqual(updater.checkCount, 1)

        updater.canCheckForUpdates = true
        XCTAssertTrue(controller.canCheckForUpdates)
        controller.checkForUpdates()
        XCTAssertEqual(updater.checkCount, 2)
    }
}
