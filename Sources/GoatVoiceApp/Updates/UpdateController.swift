import Foundation
import Sparkle

@MainActor
protocol SparkleUpdating: AnyObject {
    var canCheckForUpdates: Bool { get }
    func checkForUpdates()
}

extension SPUUpdater: SparkleUpdating {}

@MainActor
final class UpdateController: UpdateChecking {
    var sessionIsActive = false {
        didSet {
            driver.sessionIsActive = sessionIsActive
        }
    }

    private let driver = SessionAwareUserDriver()
    private let bundle: Bundle
    private let configuration: UpdateConfiguration
    private let updaterFactory: (@MainActor () throws -> any SparkleUpdating)?
    private var state: UpdaterState = .notStarted

    private enum UpdaterState {
        case notStarted
        case running(any SparkleUpdating)
        case failed
    }

    init(
        bundle: Bundle = .main,
        configuration: UpdateConfiguration? = nil,
        updaterFactory: (@MainActor () throws -> any SparkleUpdating)? = nil
    ) {
        self.bundle = bundle
        self.updaterFactory = updaterFactory
        let resolved = configuration ?? UpdateConfiguration(bundle: bundle)
        self.configuration = resolved
        switch resolved {
        case .configured:
            break
        case .notConfigured:
            AppLog.updates.info("Update feed is not configured; update checks unavailable")
        case .misconfigured(let issues):
            AppLog.updates.error(
                "Update configuration unusable: \(issues.map(\.rawValue).sorted().joined(separator: ","), privacy: .public)"
            )
        }
    }

    var canCheckForUpdates: Bool {
        guard configuration.isUsable, !sessionIsActive else {
            return false
        }
        switch state {
        case .notStarted:
            return true
        case .running(let updater):
            return updater.canCheckForUpdates
        case .failed:
            return false
        }
    }

    func checkForUpdates() {
        guard canCheckForUpdates else { return }
        switch state {
        case .running(let updater):
            updater.checkForUpdates()
        case .notStarted:
            do {
                let updater = try makeUpdater()
                state = .running(updater)
                updater.checkForUpdates()
            } catch {
                state = .failed
                AppLog.updates.error("Updater start failed code=\((error as NSError).code)")
            }
        case .failed:
            break
        }
    }

    private func makeUpdater() throws -> any SparkleUpdating {
        if let updaterFactory {
            return try updaterFactory()
        }
        let updater = SPUUpdater(
            hostBundle: bundle,
            applicationBundle: bundle,
            userDriver: driver,
            delegate: nil
        )
        updater.automaticallyChecksForUpdates = false
        updater.automaticallyDownloadsUpdates = false
        updater.sendsSystemProfile = false
        try updater.start()
        return updater
    }
}
