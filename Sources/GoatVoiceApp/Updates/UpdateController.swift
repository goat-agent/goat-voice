import Foundation
import Sparkle

@MainActor
final class UpdateController: UpdateChecking {
    var sessionIsActive = false {
        didSet {
            driver.sessionIsActive = sessionIsActive
        }
    }

    private let driver = SessionAwareUserDriver()
    private var updater: SPUUpdater?

    private var feedConfigured: Bool {
        guard let value = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String
        else {
            return false
        }
        return !value.isEmpty
    }

    var canCheckForUpdates: Bool {
        feedConfigured && !sessionIsActive && (updater?.canCheckForUpdates ?? true)
    }

    func checkForUpdates() {
        guard canCheckForUpdates, let updater = configuredUpdater() else { return }
        updater.checkForUpdates()
    }

    private func configuredUpdater() -> SPUUpdater? {
        guard feedConfigured else { return nil }
        if let updater { return updater }
        let created = SPUUpdater(
            hostBundle: .main,
            applicationBundle: .main,
            userDriver: driver,
            delegate: nil
        )
        created.automaticallyChecksForUpdates = false
        created.automaticallyDownloadsUpdates = false
        do {
            try created.start()
            updater = created
            driver.sessionIsActive = sessionIsActive
            return created
        } catch {
            AppLog.updates.error("Updater start failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}
